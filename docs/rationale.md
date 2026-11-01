# Design rationale

The reasoning behind each design decision. `decisions.md` is the one-line index; this file is the interview preparation.

Each section covers the problem, the options, the choice, the trade-off and how to verify it.

---

## 1. Mailbridge image in ECR, pinned by digest (2026-10-31)

**Problem.** The `app` host must get the Mailbridge image from somewhere. That choice decides whether the host holds a registry credential and whether we can prove what is running.

**Options.** A: Amazon ECR. B: GitHub Container Registry with a pull token in SSM. C: build on the `app` host.

**Chosen: A.** The `app` instance gets an IAM role allowing `ecr:GetAuthorizationToken` plus pull actions on one repository. An instance role delivers temporary credentials through the instance metadata service, and they rotate automatically. With IMDSv2 required, reading them needs a session token obtained by a `PUT` request, which blocks the classic SSRF attack where a vulnerable app is tricked into a simple `GET` against the metadata address. Stored keys, by contrast, never expire and can leak through backups, logs or a compromised disk. Least privilege applies too: this role can pull one repository and cannot push.

Tags such as `:latest` are mutable pointers, so the same tag can mean different code tomorrow. A digest (`image@sha256:...`) is a hash of the image content, so a pinned deployment runs exactly the reviewed image, or fails. Trivy results also stay meaningful because they describe that exact digest.

**Trade-off accepted.** About $0.10/GB per month, more IAM surface in §7, and each release needs its digest updated in configuration.

**Verify once built.** On `app`, `docker inspect --format '{{index .RepoDigests 0}}' <container>` shows the pinned digest. `aws ecr batch-delete-image` from `app` returns `AccessDenied`. `grep -rn "aws_secret_access_key" ansible/ terraform/` finds nothing.

---

## 2. Route 53 for DNS and the DNS-01 challenge (2026-10-31)

**Problem.** `mail.<domain>` resolves only inside the VPN and TCP 443 is closed to the internet, yet it needs a Let's Encrypt certificate. Let's Encrypt must be able to validate domain ownership without reaching the server.

**Options.** A: Route 53. B: Cloudflare DNS with a zone-scoped API token. C: a delegated subdomain of a domain already owned.

**Chosen: A.** HTTP-01 validation requires Let's Encrypt to connect to the server, which this design forbids. DNS-01 instead asks Certbot to publish a TXT record at `_acme-challenge.mail.<domain>`, which Let's Encrypt looks up in public DNS. No inbound port is needed, so this works for a private server.

Delegation is how the domain reaches Route 53: the registrar's NS records are set to the four name servers of the Route 53 hosted zone, so the registrar can be any company. Public DNS holds only the challenge record and `vpn.<domain>`. The `mail` A record stays in Unbound.

`certbot-dns-route53` authenticates with the `proxy` instance role, using the same temporary credentials as decision 1. Cloudflare would need a long-lived token in SSM. The policy allows `route53:ListHostedZones`, `route53:GetChange` and `route53:ChangeResourceRecordSets` on this zone only, with `ChangeResourceRecordSets` conditioned to the `_acme-challenge` name, so a compromised proxy cannot repoint `vpn.<domain>`.

**Trade-off accepted.** About $0.50/month per zone, unlike free Cloudflare DNS. Production certificates also appear in public Certificate Transparency logs, so the hostname `mail.<domain>` is public knowledge even though it does not resolve publicly.

**Verify once built.** `dig NS <domain> +short` returns the Route 53 name servers. `dig mail.<domain> @1.1.1.1 +short` returns nothing. `certbot renew --dry-run` succeeds on `proxy`.

---

## 3. Elastic IP in lab, clients use vpn.<domain> (2026-10-31)

**Problem.** The `lab` stack is destroyed after each session, but `.ovpn` profiles on client devices need a stable target. AWS charges for public IPv4 addresses even when they are not attached to anything.

**Options.** A: Elastic IP in `lab`, with profiles using `vpn.<domain>`. B: Elastic IP in `persistent`, with profiles using the raw IP.

**Chosen: A.** Public IPv4 costs about $0.005/hour, which is about $3.60/month for an address held while the lab is down. Under A the address exists only during a session, and `terraform apply` of `lab` writes its current value to `vpn.<domain>` in the persistent hosted zone. A profile contains `remote vpn.<domain> 1194 udp`, so a new IP needs no profile change. A low TTL (60 seconds) limits how long resolvers cache the previous address after a rebuild.

The Budget sits in `persistent` because a spending alert must outlive every teardown.

**Trade-off accepted.** The VPN now depends on public DNS working, the IP cannot be allowlisted anywhere, and a client may wait up to one TTL after a rebuild.

**Verify once built.** After `apply`, `dig vpn.<domain> +short` matches `terraform output` for the IP, and the record's TTL shows 60. After destroying `lab`, `aws ec2 describe-addresses` returns no addresses. The same `.ovpn` file connects across two rebuilds.

---

## 4. Bottom-up build order: db → app → proxy (2026-10-31)

**Problem.** The original order built `proxy` and `app` before their dependencies existed, so neither could be fully tested when finished.

**Options.** A: db → app → proxy. B: keep the original order and accept failures until `db` exists. C: keep the order and put a stub container behind `proxy`.

**Chosen: A.** Building bottom-up means each layer is tested against the real layer beneath it. When a step fails, the fault is in the newest layer, because everything below is already verified. B makes expected errors look like real ones. C works, but writes a stub that gets thrown away.

**Trade-off accepted.** The WAF is tested later than it would be with a stub, and `app` has no browser-facing path until `proxy` exists, so it is checked from inside the network first.

**Verify once built.** `psql` from `app` connects before the `app` role runs. `curl http://10.0.3.10:3000` from `proxy` succeeds before the `proxy` role runs. `https://mail.<domain>` then returns 200 on the first try.

---

## 5. NAT on fw-ips before the full nftables policy (2026-10-31)

**Problem.** Private hosts are managed through SSM, and the SSM agent makes outbound HTTPS calls to AWS service endpoints. Private subnets have no internet route except through fw-ips, and there is no NAT Gateway or interface endpoint because both bill hourly.

**Options.** A: split the work into NAT first, full policy second. B: write the whole ruleset as one task.

**Chosen: A.** A private host has only a private address. Without source NAT on fw-ips, its packets could leave but replies could never return, so the agent never registers and Ansible over SSM cannot reach the host. fw-ips also needs source/destination check disabled, since it forwards traffic that is not addressed to it. Masquerading therefore comes first, and it needs only forwarding plus NAT to prove the path. The least-privilege policy is added on top, so a later SSM failure points to one new rule rather than an entire ruleset. Both steps stay hand-written by Marko.

**Trade-off accepted.** A short window where forwarding is less restricted than the final policy. It is limited because private hosts have no inbound path from the internet, and it closes before the private hosts are configured. fw-ips is also a single point of failure for all private egress, an accepted lab cost.

**Verify once built.** `aws ssm describe-instance-information` lists private hosts as `Online`. From `db`, `curl -sI https://ssm.eu-central-1.amazonaws.com` gets a response, and the source address seen outside is the fw-ips Elastic IP.

---

## 6. Public repo with branch protection (2026-10-31)

**Problem.** The convention "merge only on green CI" is only a promise unless GitHub enforces it.

**Options.** A: public repo. B: private now, public after Tier 1.

**Chosen: A.** On a free personal account, branch protection is available for public repos but not private ones. With required status checks on `main`, GitHub refuses a merge until the six CI jobs pass, so the rule is enforced by a system rather than by discipline. The repo also works as a public portfolio piece.

Public visibility raises the stakes on secrets. `gitleaks` runs in pre-commit and in CI, and `.gitignore` excludes state, keys and profiles. Terraform state, which can contain sensitive values, lives only in the state bucket. Anything committed must be treated as permanently public, even if removed later, so a leaked secret must be rotated rather than just deleted.

**Trade-off accepted.** The network design, the domain and eventually the findings are visible to anyone. Security must not depend on the design being secret, which is the right assumption anyway (Kerckhoffs's principle), but real IPs, tokens and unfixed-vulnerability details stay out of the repo.

**Verify once built.** `gh api repos/rossiko22/secure-mailbridge-lab/branches/main/protection` shows the required checks. A PR with a failing job cannot be merged.

---

## 7. Security groups in their own module (2026-10-31)

**Problem.** Security groups could live with the network resources they sit on, or in their own module.

**Options.** A: separate `modules/security`. B: everything in `modules/network`.

**Chosen: A.** The network module answers where packets can go, and the security module answers who is allowed. Keeping them apart means the rules can be reviewed line by line against §4 without routing mixed in. The module takes `vpc_id` as input and attaches `sg-fw` to the fw-ips ENI using `aws_network_interface_sg_attachment`, so dependencies flow one way. Rules are separate resources rather than inline blocks, because `sg-app` and `sg-proxy` reference each other and inline rules would form a cycle.

**Trade-off accepted.** More wiring in the root stack, and the fw-ips ENI briefly holds only the empty default group during creation.

**Verify once built.** `aws ec2 describe-network-interfaces` shows `sg-fw` on the ENI. Each rule in `aws ec2 describe-security-group-rules` maps to a §4 row or the egress table.

---

## 8. S3 gateway endpoint deferred (2026-10-31)

**Problem.** The endpoint lets `db` reach S3 without passing through fw-ips, but only Tier 2 backups use it.

**Options.** A: include it now. B: add it in T2.3 with backups.

**Chosen: B.** Unused infrastructure is something to explain and secure with no benefit, and the project gate says Tier 2 components wait. A gateway endpoint works by adding a route to chosen route tables, so a later `data`-only endpoint needs `data` on its own route table. Until then one private table serves all four private subnets.

**Trade-off accepted.** T2.3 has to add a route table and move one subnet association. The deployed network differs from the final design until then, which §2 records.

**Verify once built.** `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=<vpc-id>` returns an empty list in Tier 1.

---

## 9. Explicit egress per security group (2026-10-31)

**Problem.** §4 listed only inbound rules. AWS security groups allow all egress by default, but Terraform removes that default, so egress must be stated. The question is how much to allow.

**Options.** A: explicit egress per group. B: allow all, and rely on nftables.

**Chosen: A.** This is defence in depth: egress filtering limits what a compromised host can do, such as scanning sideways or reaching a server that is not its next hop. Security groups are enforced by AWS outside the instance, so root on the host cannot alter them. Under B, traffic to neighbours in the same subnet would never reach fw-ips at all, so nftables could not see it. Stateful tracking means replies need no rules of their own. Traffic to the Amazon DNS resolver and metadata service is not filtered by security groups at all, which is why neither appears here.

`sg-fw` is the exception, with all egress allowed, because it forwards traffic for the whole VPC and nftables applies the policy there.

**Trade-off accepted.** More rules, and each new flow needs an egress rule as well as an ingress rule. A missing rule fails silently as a timeout. `apt` over port 80 is blocked here as well as in nftables, so HTTPS mirrors remain the expected fix.

**Verify once built.** From `proxy`, `nc -zv 10.0.4.10 5432` times out while `nc -zv 10.0.3.10 3000` connects. From `db`, `curl -sI https://ssm.eu-central-1.amazonaws.com` responds.

---

## 10. Standalone fw-ips network interface (2026-10-31)

**Problem.** Private route tables must point at fw-ips, but the instance is created later and is replaced more often than the routes should change.

**Options.** A: a standalone ENI in `modules/network`. B: an instance-owned interface, with routes created after it.

**Chosen: A.** A route to an ENI is valid before anything is attached to it, and the network layer stops depending on compute. Because the ENI outlives the instance, the fixed address `10.0.1.10`, source/destination check setting and security group all survive instance replacement. Source/destination check must be off, as fw-ips forwards packets that are not addressed to it.

**Trade-off accepted.** Until an instance attaches, private routes show as `blackhole`, which is expected in the network-only stage.

**Verify once built.** `aws ec2 describe-route-tables` shows the routes `active` after fw-ips is attached. `aws ec2 describe-network-interfaces` shows `SourceDestCheck: false`.

---

## 11. Hand build, compare, rebuild from code (2026-10-31)

**Problem.** Marko must understand and defend every part of the lab, but the final deployment must still be repeatable with `make up`. Generating code alone teaches little, and a hand-built lab cannot be reproduced.

**Options.** A: per layer, build by hand, test, compare with code, rebuild from code. B: build all of Tier 1 by hand, then write all the code. C: code first with a walkthrough.

**Chosen: A.** The layers are network, fw-ips, db, app, proxy and siem. Each goes through four steps: build by hand, test, compare, rebuild. For infrastructure, `terraform import` brings the hand-built resources into state, and `terraform plan` then shows any difference between code and reality, known as drift. For configuration, `ansible-playbook --check --diff` does the same job. Comparison alone proves the code describes the build, not that it can create it, so the hand-built version is destroyed and redeployed from code, then the same tests run again. Ordering problems only appear on that clean deploy.

**Trade-off accepted.** Slower progress, and every layer is built twice. Hand-built resources also keep billing until deleted, so paid resources are removed at the end of each session.

**Verify once built.** After import, `terraform plan` reports no changes. After the rebuild, every test in the layer's tasks passes. For Ansible, a second run on a fresh host reports `changed=0`.

---

## 12. VPC flow logs to S3 (2026-10-31)

**Problem.** nftables and Suricata only see traffic crossing fw-ips. Traffic between two hosts in the same subnet never reaches it, so an attacker moving sideways there would be invisible. checkov also flags the VPC for having no flow logs.

**Options.** A: flow logs to S3. B: skip them for Tier 1. C: flow logs to CloudWatch Logs.

**Chosen: A.** Flow logs record metadata for each network interface: addresses, ports, protocol, bytes and whether traffic was accepted or rejected. They hold no packet contents. A `REJECT` entry also shows a security group stopping something, which is direct evidence for the "inside attacker" scenario. The bucket sits in `persistent`, because a bucket in `lab` would lose the evidence at each teardown, and a lifecycle rule expires objects after 30 days. S3 costs less than CloudWatch ingestion and needs no separate delivery role. A 60-second aggregation interval gives tighter attack timelines.

**Trade-off accepted.** Logs still arrive minutes late, so this is for investigation rather than live alerting, and Wazuh does not read them in Tier 1. Queries mean downloading files or using Athena.

**Verify once built.** `aws ec2 describe-flow-logs` shows `ACTIVE`. After a blocked connection attempt, objects appear in the bucket and contain a `REJECT` record for that address and port.

---

## 13. NACL return traffic and service port denies (2026-10-31)

**Problem.** NACLs are stateless, so replies need their own rules, and those replies land on ephemeral ports (1024–65535). Replies from the internet can come from any address, so private subnets need that range open from `0.0.0.0/0`. The range also contains ports 3000, 5432, 1514 and 1515, so a simple return rule would quietly undo the "one hop" design at this layer.

**Options.** A: an explicit deny for each service port, numbered just before the return rule. B: return rules only, relying on security groups. C: narrow return rules to known sources, which cannot work for internet replies.

**Chosen: A.** NACL rules are checked in number order and the first match wins. Allowing the legitimate source at 100, denying the same port from everywhere at 105 and allowing ephemeral ports at 110 means the port stays limited to its one permitted source. The second layer then stands alone, as §4 intends.

**Trade-off accepted.** Three extra rules to maintain, and any new service in that port range needs its own deny. NACLs stay coarse: they work on subnets, so they cannot express per-host rules the way security groups can. Traffic to the Amazon DNS resolver and metadata service is not filtered by NACLs.

**Verify once built.** With the `db` security group temporarily opened to the DMZ, `nc -zv 10.0.4.10 5432` from `proxy` still times out and flow logs show `REJECT`. Restore the group afterwards.

---

## 14. Laptop credentials with aws login (2026-10-31)

**Problem.** Terraform on the laptop needs AWS credentials, and no access keys exist by design.

**Options.** A: `aws login`. B: run Terraform in CloudShell. C: create access keys.

**Chosen: A.** `aws login` signs in through the browser with the existing console identity and MFA, then gives the CLI short-lived credentials. This is the same principle as decision 1: a credential that expires limits the damage if it leaks, and an access key does not. If a tool cannot read these credentials directly, `aws configure export-credentials --format env` passes them through as environment variables.

**Trade-off accepted.** Sessions expire, so long work needs signing in again, and it depends on a recent AWS CLI. It also still uses `AdministratorAccess`, so a session on the laptop is powerful while it lasts.

**Verify once built.** After `aws login`, `aws sts get-caller-identity` shows `marko-admin` or its login session. `~/.aws/credentials` contains no access key.

---

## 15. Terraform state in S3 (2026-10-31)

**Problem.** State maps code to real resources and can contain sensitive values. Losing it means Terraform no longer knows what it manages, and each rebuild in this project depends on it.

**Options.** A: an S3 bucket built by hand now. B: local state, migrated later.

**Chosen: A.** S3 keeps state off the laptop. Versioning allows recovery from a bad write, encryption protects it at rest, and blocking public access keeps it private. S3 native locking (`use_lockfile`) stops two runs writing at once, without a DynamoDB table. The bucket is hand-built and later imported into `terraform/persistent`, since a stack cannot create the bucket holding its own state. The backend block stays partial, with the bucket name in a gitignored `backend.hcl`, because the name contains the account ID and the repo is public.

**Trade-off accepted.** A small storage cost, a bootstrap step that cannot be fully automated, and a manual `-backend-config=backend.hcl` on init.

**Verify once built.** `aws s3api get-bucket-versioning` shows `Enabled`. After `terraform apply`, `aws s3 ls` shows the state object. `git check-ignore backend.hcl` prints the name.

---

## 16. Keep the hand-built network, defer the rebuild test (2026-10-31)

**Problem.** The layer loop ends with destroying the hand build and rebuilding from code. Marko prefers to keep the network built by hand.

**Options.** A: rebuild now. B: defer the rebuild and build fw-ips on the existing network.

**Chosen: B.** Terraform already manages all 114 resources and `plan` reports no changes, so the network is fully under code control. VPCs, subnets, route tables, security groups, NACLs and an unattached ENI have no hourly charge, so nothing needs to be torn down to save money. Paid resources, starting with instances and the Elastic IP, are still removed after each session.

**Trade-off accepted.** The code has proven that it describes the network, not that it can create it. Ordering problems stay hidden until the first full rebuild, which then involves more resources. `make up` cannot count as verified for this layer until that test has run.

**Verify once built.** Run `terraform destroy` and `terraform apply` once before Tier 1 closes (task 1.20), then re-run the 1.5a checks. `terraform plan` reports no changes.

---

## 17. Pinned CI with documented checkov skips (2026-10-31)

**Problem.** CI must enforce "merge only on green", but a workflow that follows moving tags can change without any commit here, and checkov flags two things that are not real problems.

**Options.** A: pin actions by commit, and skip each false positive with a written reason. B: use version tags and turn the two checks off globally.

**Chosen: A.** A Git tag such as `v7` can be moved, so a compromised action could reach every repo that follows it. This is a supply chain attack. A commit SHA identifies exact content, the same idea as digest pinning in decision 1. The token is read-only. Skips sit next to the resource they apply to and state why, so the check stays active for everything else. `CKV2_AWS_5` is skipped for security groups the compute module will attach, and those skips come out in task 1.6. `CKV2_AWS_1` is skipped because checkov cannot trace `subnet_ids` across modules.

**Trade-off accepted.** Pinned versions need updating by hand, and a skip can go stale if nobody removes it.

**Verify once built.** The pull request shows six green checks. `grep -rn 'checkov:skip' terraform` lists each skip with its reason.

---

## 18. fw-ips operating system (2026-11-01)

**Problem.** `ARCHITECTURE.md` did not set an operating system, and fw-ips runs the most security-critical software in the lab: OpenVPN, nftables, Suricata and Unbound.

**Options.** A: Ubuntu 24.04 LTS. B: Amazon Linux 2023. C: Debian 12.

**Chosen: A.** An LTS release gets security updates for years, so unattended updates stay meaningful for the life of the lab. The official Canonical AMI ships with the SSM agent, which Session Manager needs from first boot. The packages the host depends on are mainstream on Ubuntu, and most documentation and interview examples assume Debian-family tooling. Amazon Linux fits AWS closely but has a smaller package set for this stack. Debian would also work, but its AWS images need more checking around the SSM agent.

**Trade-off accepted.** Ubuntu installs the SSM agent as a snap, which is less plain than an apt package, and its default mirrors commonly use port 80, which the public NACL blocks. That second point is tracked as an open item and tested right after launch.

**Verify once built.** On fw-ips, `lsb_release -d` prints `Ubuntu 24.04` and `snap list amazon-ssm-agent` lists the agent.

---

## 19. Delegated subdomain for `<domain>` (2026-11-01)

**Problem.** The lab needs a public DNS zone in Route 53 for `vpn.<domain>` and Certbot's DNS-01 challenge. Marko already owns domains, so none needs buying, but they already have DNS records, including email forwarding.

**Options.** A: delegate one subdomain of an existing domain to Route 53. B: move a whole existing domain to Route 53. C: use a different owned domain that may be serving a live site.

**Chosen: A.** NS records say which servers answer for a name. Adding NS records for one subdomain hands over only that subdomain, while the parent's provider keeps answering for everything else. Moving the whole domain would break email forwarding until those records were recreated. This also limits blast radius, because a mistake in the lab zone cannot touch the parent. Certbot and the proxy role work unchanged, since the `_acme-challenge` record sits inside the delegated zone. The real name stays out of this public repo, in line with keeping the state bucket name private.

**Trade-off accepted.** Names are one label longer, and DNS now spans two providers. The zone costs about $0.50 a month and stays between sessions.

**Verify once built.** `dig +short NS <domain>` returns the four Route 53 name servers, and the parent domain's MX records are unchanged.

---

## 20. Package updates over HTTPS (2026-11-01)

**Problem.** Ubuntu's default apt sources use `http://`, but the public NACL allows outbound TCP 443 and not 80. A test on fw-ips confirmed it: the HTTP mirror timed out, and the HTTPS regional mirror returned 200.

**Options.** A: point apt at the HTTPS regional mirror. B: open outbound TCP 80. C: run an own package mirror or proxy.

**Chosen: A.** apt already verifies packages with Ubuntu's GPG signatures, so the choice is not about package integrity. It is about firewall policy. HTTPS needs no change to §4, while opening port 80 would widen the NACL and nftables policy for all traffic, not only updates. HTTPS also hides which packages a host installs from anyone watching the network. C gives the most control but adds a service to run and pay for. Marko wants to discuss it after Tier 1, so it is parked as an open item.

**Trade-off accepted.** A new instance starts with `http://` sources, so every Ansible role must set HTTPS before installing anything.

**Verify once built.** `grep -rh '^URIs:' /etc/apt/sources.list.d/` shows only `https://`, and `sudo apt-get update` finishes with no `Err:` or `Failed to fetch`.

---

## 21. Offline VPN CA (2026-11-01)

**Problem.** OpenVPN trusts any certificate the CA signed, and the name in a certificate selects the user or admin pool. Whoever holds the CA private key can issue an admin identity. The docs did not say where that key lives.

**Options.** A: CA on the laptop, with an encrypted backup in SSM. B: CA on fw-ips, with a backup in SSM. C: CA in SSM, fetched to fw-ips only for signing.

**Chosen: A.** fw-ips is the only internet-facing host, and it does not need the CA key: it verifies clients with the public `ca.crt` and needs only its own server key and the CRL. With an offline CA, full compromise of fw-ips does not give the attacker the power to mint certificates. B loses the whole PKI on that compromise. C has the same exposure as B, because the fw-ips role must be allowed to read the key. The backup uses `/vpn/`, not `/mailbridge/`, because the app role can read `/mailbridge/*`. The key is passphrase-encrypted before it reaches SSM, and decision 22 removes parameter read from the instance roles. Without decision 22 the passphrase would be the only protection, because `AmazonSSMManagedInstanceCore` can read and decrypt the backup.

**Trade-off accepted.** Issuing and revoking happen on the laptop, and each revocation needs a new CRL copied to fw-ips, which slows the response measured in scenario 2.2. Losing the laptop or the passphrase means restoring from the backup or rebuilding the PKI. The CRL also has an expiry, and OpenVPN rejects clients once it lapses, so it must be re-signed in time. The backup holds the encrypted key and `ca.crt`, not easy-rsa's certificate database, so a restore brings back signing but not the record of issued certs; those would be reissued.

**Verify once built.** `sudo find / -name 'ca.key' -not -path '/proc/*' -not -path '/usr/share/doc/*'` on fw-ips prints nothing (OpenVPN ships a sample `ca.key` under `/usr/share/doc`). `pki/private/ca.key` on the laptop starts with `ENCRYPTED PRIVATE KEY`. `aws ssm describe-parameters` shows the `/vpn/` parameter as `SecureString`.

---

## 22. Minimal SSM policy for instance roles (2026-11-01)

**Problem.** §7 gave every host `AmazonSSMManagedInstanceCore`, assumed to be the SSM minimum. Reading the policy showed `ssm:GetParameter` and `ssm:GetParameters` on `Resource: *`, and the IAM simulator returned `allowed` for the fw-ips role. The `aws/ssm` KMS key policy decrypts through SSM for any principal in the account, so `SecureString` adds no restriction here. Any host could read the CA backup and every `/mailbridge/*` secret, which defeats one role per instance.

**Options.** A: a customer-managed copy of the policy without the two parameter actions, plus a narrow grant per host. B: keep the AWS policy and add an explicit `Deny` per host and path. C: encrypt secrets with a customer-managed KMS key.

**Chosen: A.** It removes the cause on every host, costs nothing and fails safe: a new host reads nothing until it is granted access. B fails open, because one forgotten `Deny` exposes the secrets again. C also fails safe but costs about $1 a month per key and leaves the broad permission in place.

**Trade-off accepted.** The policy is maintained here, so AWS's updates to the managed policy do not arrive automatically. If a future agent feature needs another action, it has to be added by hand.

**Verify once built.** `aws iam simulate-principal-policy` for the fw-ips role returns `implicitDeny` on `/vpn/ca/key` and `/mailbridge/*` and `allowed` on `/vpn/fw-ips/*`. Session Manager still connects and the instance stays `Online`.

---

## 23. Dynamic VPN user addresses (2026-11-01)

**Problem.** §5 places certificates in pools with `client-config-dir`, but did not say how user devices get addresses or what happens to a valid certificate with no `ccd` file.

**Options.** A: `ccd-exclusive` with a fixed address per device. B: a dynamic user pool, with a `ccd` file only for admin devices.

**Chosen: B.** Users draw from a pool in 10.8.0.0/24 and the admin device keeps a fixed address in 10.8.1.0/24. A would map each address directly to one device and refuse any certificate with no file. B fits Marko's goal for the attack scenarios: after a stolen certificate is used, the investigation has to prove who held an address at a given time from OpenVPN's connection logs in Wazuh, as it would in a larger VPN.

**Trade-off accepted.** OpenVPN logs become required evidence, so losing them loses attribution. Alerts and connection events must be matched by time, which depends on NTP. nftables and Suricata cannot target one user device by address. Any valid certificate can connect, so revocation is the only way to cut one off. An admin certificate with a missing `ccd` file lands in the user pool.

**Verify once built.** A user certificate gets an address in 10.8.0.0/24, `marko-laptop` gets 10.8.1.10, and `journalctl -u openvpn-server@server` shows each certificate's name with its address. Attribution must use the `primary virtual IP` line, because `MULTI_sva: pool returned` is logged before the `ccd` file is applied and can show an address the client never used.

---

## 24. Stop fw-ips between sessions during the hand build (2026-11-01)

**Problem.** The method says paid hand-built resources are removed after each session, but terminating fw-ips would delete its hand-made OpenVPN config, which is not yet in Ansible.

**Options.** A: stop the instance and release the Elastic IP. B: stop the instance and keep the Elastic IP. C: terminate and rebuild by hand each session.

**Chosen: A, as a documented exception.** Stopping ends compute charges and keeps the config on the disk. Releasing the Elastic IP removes its hourly charge. Client profiles use `vpn.<domain>`, so only the DNS record changes. C would repeat the build each session. The exception ends when the Ansible role can rebuild fw-ips, and then `terraform destroy` applies as §12 says.

**Trade-off accepted.** The disk bills about $2 a month while stopped. Each session starts by allocating a new address and updating the record, and until then the `vpn` record points at an address AWS may give to someone else. Clients would still refuse it, because `verify-x509-name` and `tls-crypt` fail.

**Verify once built.** After stopping, `aws ec2 describe-addresses` returns nothing and the instance state is `stopped`.

## 25. Forwarding and NAT on a single interface (2026-11-01)

**Problem.** fw-ips has one ENI, so internet and VPC traffic both enter and leave on `ens5`. Interface matches can't tell them apart. VPN pools must also stay un-NATed, because §2 needs the real client address on every event.

**Options.** A: match on addresses and `snat` private subnets to 10.0.1.10. B: `masquerade` everything in `10.0.0.0/16`. C: add a second ENI to separate the traffic.

**Chosen: A.** The rules match private sources and non-VPC destinations, on TCP 443 and UDP 123 as §4 allows. `snat` suits a fixed address, and the internet gateway maps it to the session's Elastic IP, so the rule survives address changes. `send_redirects` is off, because Linux would otherwise tell senders to bypass the firewall. C costs nothing extra but adds a subnet design change for no Tier 1 benefit.

**Trade-off accepted.** 10.0.1.10 and `ens5` are hardcoded in `define` lines. Until 1.9b, there is no `input` chain, so `sg-fw` alone protects fw-ips itself. Drop logs are rate limited, so a flood can lose entries.

**Verify once built.** `sudo nft list ruleset` shows both chains; a private test host shows `Online` in SSM; `FW-EGRESS` entries appear in the journal.

## 26. NFQUEUE in a separate chain (2026-11-01)

**Problem.** Suricata (1.11) must see every packet in a flow. A queue rule after the `established` accept would see only the first packets, and a packet Suricata accepts skips the rest of its chain, so a queue rule before the policy rules could bypass them.

**Options.** A: a separate base chain at a later priority. B: queue at the top of the policy chain. C: queue after the `established` accept.

**Chosen: A.** Packets pass the firewall first, and only allowed traffic reaches Suricata. The 1.9a ruleset needs no rewrite.

**Trade-off accepted.** There are two forward chains to reason about, and the order depends on their priorities. What happens if Suricata stops is still to be decided in 1.11.

**Verify once built.** `suricata -T` passes, and `eve.json` shows a full `tun0` flow, not just its first packets, while dropped traffic never reaches it.

## 27. VPN clients reach Unbound (2026-11-01)

**Problem.** Clients are pushed DNS 10.0.1.10, but the pushed routes cover only `10.0.2.0/24` and `10.0.5.0/24`, and §4 had no rule allowing the VPN pools to reach Unbound. `mail.<domain>` could not resolve over the VPN.

**Options.** A: allow port 53 from the pools to 10.0.1.10 and push a /32 route. B: move DNS to the tunnel address 10.8.0.1. C: leave it blocked.

**Chosen: A.** §5 and §6 keep one DNS address, and 1.10's check stays the same. A /32 route exposes no other host in the public subnet. B depends on `tun0` existing when Unbound starts. C breaks the app.

**Trade-off accepted.** A stolen user cert can now query Unbound, which adds a DNS path alongside the proxy. Forwarded traffic is still limited to the proxy on 443.

**Verify once built.** From the VPN, `dig @10.0.1.10 mail.<domain> +short` returns 10.0.2.10.

## 28. Input policy on fw-ips (2026-11-01)

**Problem.** §4 covers forwarded traffic but says little about fw-ips itself, the highest-risk host. The input rules must protect it without breaking the VPN, SSM or its own network settings.

**Options.** A: `input` drops by default, `output` stays open, ping for admins only, load-tested from a separate file. B: also restrict `output` now. C: leave `input` open and rely on `sg-fw`.

**Chosen: A.** `sg-fw` doesn't filter VPN clients, because their traffic arrives on `tun0` after decryption, so C would leave services exposed to them. DHCP replies are allowed so the lease renews. B risks breaking SSM, apt and DNS, which all start from fw-ips.

**Trade-off accepted.** A compromised fw-ips can send traffic anywhere. Restricting `output` is left as possible later hardening.

**Verify once built.** After loading, the VPN, SSM and `ping 10.8.0.1` still work, and a test to a closed port on fw-ips logs `FW-INPUT-DROP`.

## 29. Unbound configuration (2026-11-01)

**Problem.** `mail.<domain>` must resolve only inside the VPN, while every other name keeps working, and the real domain must stay out of the public repo.

**Options.** A: a `static` local zone for the exact name, with the domain in an untracked vars file. B: a `transparent` local zone. C: a local zone for all of `<domain>`, or the domain stored in SSM.

**Chosen: A.** `static` answers that name and nothing else, so the `vpn` record and `_acme-challenge` still resolve publicly. C's wider zone would break the DNS-01 check. SSM adds a read and an IAM grant for a value that isn't a secret. `ip-freebind` lets Unbound start before its address exists. Query logging stays off, because §8 doesn't list it.

**Trade-off accepted.** `make up` needs the vars file on the laptop. Scenario 2.2 can't show which names a stolen cert looked up, and Suricata can't see VPN DNS, because those queries end at fw-ips and only forwarded traffic is queued.

**Verify once built.** From the VPN, `dig @10.0.1.10 mail.<domain> +short` returns 10.0.2.10 and a public name resolves.

## 30. Private hosts keep AmazonProvidedDNS (2026-11-01)

**Problem.** Private hosts use 10.0.0.2 by default, and security groups and NACLs don't filter that traffic. A compromised host can leak data through DNS without crossing fw-ips.

**Options.** A: leave it and record a known gap. B: point DHCP at Unbound. C: turn off `enableDnsSupport`, or add Route 53 Resolver DNS Firewall.

**Chosen: A.** B only changes the default, so a host can still query 10.0.0.2 directly, and fw-ips would need its own DNS pinned to avoid depending on itself. C changes more of the design while TCP 443 to any address remains an easier way out.

**Trade-off accepted.** Private host DNS stays invisible until a fix is added. Scenario 2.2 tests the bypass and records it as a finding. Resolver query logging is the likely first fix.

**Verify once built.** From a private host, `dig @10.0.0.2 example.com +short` answers, and no matching entry appears on fw-ips.

## 31. No DNSSEC validation in Unbound (2026-11-01)

**Problem.** Ubuntu's Unbound validates DNSSEC by default. AmazonProvidedDNS returned no `RRSIG` records for the root or `example.com`, even with `+dnssec`, so Unbound couldn't confirm the root keys and answered `SERVFAIL` for every forwarded name.

**Options.** A: turn off validation with `module-config: "iterator"`. B: A, plus Route 53 Resolver DNSSEC validation on the VPC. C: resolve directly or use a public resolver, opening DNS out.

**Chosen: A.** It's one line and keeps §6. The path to 10.0.0.2 stays inside AWS's network, and TLS means a forged address still fails the certificate check. C changes §4, the NACLs and §6. B needs testing and can be added later without undoing A.

**Trade-off accepted.** Nothing in the lab validates DNSSEC, so Unbound trusts what 10.0.0.2 returns. Until production certs arrive in 2.6, `curl -k` skips the check that TLS would otherwise provide.

**Verify once built.** From the VPN, `dig @10.0.1.10 example.com +short` returns addresses, and `sudo journalctl -u unbound` shows no new trust anchor failures.
