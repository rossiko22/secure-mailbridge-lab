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
