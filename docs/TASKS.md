# Tasks & progress

Single tracker for the whole lab. Session notes go in `progress.md`, decisions in `decisions.md`.

**Status:** `[ ]` todo · `[~]` in progress · `[x]` done and verified
**Owner:** **M** = Marko writes it, Claude reviews · **C** = Claude drafts after an OK on the approach · **M+C** = shared

**Layer loop (network, fw-ips, db, app, proxy, siem):** build by hand → test → compare with code → destroy and rebuild from code → re-test. A layer is finished only after the rebuild passes. Remove paid hand-built resources at the end of each session.

A task is done only when its verify step passes. A phase is done only when `make up` deploys it,
it is verified, and the relevant doc section is updated.

## Current position

- **Phase:** 1, Tier 1 on AWS (0.6 and 0.7 still open)
- **Next task:** 1.11 (Suricata install and NFQUEUE wiring). 1.6, 1.7b, 1.8, 1.9a, 1.9b and 1.10 are hand-verified; their code is still to do.

## Open items

- [~] **Delegate the subdomain:** zone and NS records built by hand and verified with `dig`, parent MX unchanged. Import the zone in 1.2.
- [ ] **Each session during the fw-ips hand build:** start by allocating an Elastic IP, associating it with the ENI, starting fw-ips and updating the `vpn` record; end by stopping fw-ips and releasing the Elastic IP (decision 24).
- [ ] **Own package mirror or proxy:** Marko wants to discuss this later. Parked until Tier 1 is finished; no design change yet.
- [ ] **SSH over the VPN:** proposed as a daily-use path from the admin pool, with SSM kept for emergencies. Discuss after 1.9b; no design change yet.
- [ ] **Mailbridge repo location:** where the source lives, so the image can be built and pushed to ECR. Needed for 1.14.

---

## Phase 0: Repo foundation

- [x] **0.1** Folder structure, git repo, `.gitignore`, doc stubs · C
  - Verify: `git check-ignore x.tfstate x.ovpn x.key .env` prints all four names
- [x] **0.2** Decide Mailbridge image, DNS, Elastic IP, build order, NAT timing, repo visibility · M
  - Verify: all six are in `decisions.md` and `rationale.md`
- [x] **0.3** Confirm the moved permissions are active · M
  - Verify: restart Claude Code, run `/permissions`; `terraform apply` appears under deny
- [x] **0.4** Pre-commit: `gitleaks`, `terraform fmt` · C
  - Verify: `pre-commit run --all-files` passes; a fake AWS key in a test commit is blocked
- [x] **0.5** CI workflow: `terraform fmt -check`, `terraform validate`, `tflint`, `checkov`, `ansible-lint`, `gitleaks`, then branch protection on `main` · C
  - Verify: the first PR shows all six checks green; a PR with a failing job cannot be merged
- [ ] **0.6** Makefile skeleton (`up`, `down`, `verify`) · C
  - Verify: `make -n up` prints the steps without executing them
- [ ] **0.7** First draft of `threat-model.md` · M
  - Verify: covers assets, trust boundaries and the four attacker positions from §11

## Phase 1: Tier 1 on AWS

Order follows ARCHITECTURE.md §13: network → fw-ips (OpenVPN, then NAT) → db → app → proxy → siem.

**Every `terraform apply`, `destroy` or AWS resource creation needs Marko's explicit go-ahead.**

**Foundation**
- [x] **1.1** Account safety: root MFA, admin IAM user with MFA, no root access keys · M
  - Verify: IAM Dashboard shows root MFA enabled; console sign-in as the admin user works
- [x] **1.1b** AWS Budget alert at $20, by hand now, imported into `terraform/persistent` with 1.2 (day one, §12) · M
  - Verify: in CloudShell, `aws budgets describe-budget --account-id <id> --budget-name mailbridge-lab-monthly` shows a 20 USD limit and `FilterExpression` excludes `Credit` and `Refund`
- [ ] **1.2** `terraform/persistent`: state bucket, backup bucket, flow log bucket, Route 53 zone, ECR repository, VPN CA + secrets · C
  - Note: `/vpn/ca/*` was created by hand. Don't import `/vpn/ca/key` without a plan for its value, because Terraform stores parameter values in state.
  - Verify: Marko reviews `terraform plan` before any apply; no secret values in the repo or in plan output

**Network (free resources)**
- [x] **1.3** `modules/network`: VPC, 5 subnets, routes, IGW, standalone fw-ips ENI, flow logs · C
  - Note: private routes show as `blackhole` until fw-ips attaches; the S3 endpoint moved to T2.3
  - Verify: plan shows no NAT Gateway, ALB or interface endpoint
- [x] **1.4** `modules/security`: security groups and NACLs from §4 · C
  - Verify: `checkov` passes; line-by-line review against the §4 table
- [x] **1.5a** Hand-build the network, security groups and flow logs in the console, without reading the modules · M
  - Verify: `aws ec2 describe-subnets` shows the 5 CIDRs from §2; `aws ec2 describe-flow-logs` shows `ACTIVE`
- [x] **1.5b** State bucket by hand, `aws login`, `terraform/lab` root stack (network only, written by Marko), import the hand build, compare · M+C
  - Verify: `terraform plan` reports no changes
- [ ] **1.5c** Deferred to 1.20: destroy the hand build and rebuild from code · M
  - Verify: the 1.5a checks pass again; `terraform plan` reports no changes

**fw-ips**
- [ ] **1.6** Remove the `CKV2_AWS_5` skips as groups get attached. `modules/compute` and IAM: fw-ips instance, IMDSv2, encrypted gp3, `credit_specification = "standard"`, source/dest check off, Elastic IP and `vpn.<domain>` record · C
  - Note: roles use `mailbridge-lab-ssm-min`, never `AmazonSSMManagedInstanceCore` (decision 22)
  - Verify: `tflint` and `checkov` pass; plan shows `http_tokens = "required"`; the IAM simulator denies the fw-ips role `ssm:GetParameter` on `/vpn/ca/*` and `/mailbridge/*`; `aws ssm start-session` connects; `dig vpn.<domain> +short` matches the Elastic IP
- [x] **1.7a** Offline CA on the laptop with easy-rsa, outside the repo: CA, CRL, encrypted key backed up to SSM under `/vpn/` · M+C
  - Verify: `pki/private/ca.key` starts with `ENCRYPTED PRIVATE KEY`; `openssl crl -in pki/crl.pem -noout -nextupdate` shows a future date; the SSM parameter exists as `SecureString`
- [~] **1.7b** Hand build verified; the `fw_ips` role part is still to do. Fetch parameters through a pipe, because the snap `aws` wrote 0 bytes when stdout was a file. Sign the server cert and one cert per device on the laptop, revoke a test cert, and have the `fw_ips` role install only the public files, server key and CRL · M+C
  - Verify: `openssl crl -in crl.pem -noout -text` lists a test-revoked serial; no CA private key exists on fw-ips
- [~] **1.8** Hand build verified; the `fw_ips` role part is still to do. `fw_ips` role: OpenVPN server, §5 hardening, `client-config-dir` pools, profiles using `vpn.<domain>` · C
  - Verify: user cert gets 10.8.0.x, admin cert gets 10.8.1.x
- [x] **1.9a** nftables: forwarding and NAT for private subnets · **C** (Marko explicitly asked Claude to write this one)
  - Note: verified by hand with a temporary VM. The files are in `ansible/roles/fw_ips/files/`; the role tasks that install them are still to do.
  - Note: private hosts reach SSM through fw-ips, so this comes before any of them is configured
  - Verify: `aws ssm describe-instance-information` lists a private test host as `Online`
- [x] **1.9b** Core nftables ruleset: full §4 policy on top of 1.9a · **C** (Marko explicitly asked Claude to write this one)
  - Note: verified by hand, including a reboot. No proxy exists yet, so 443 was shown as not dropped; a working connection is proved in 1.15. The role tasks that install the files are still to do.
  - Verify: `nft list ruleset`; user pool reaches only 10.0.2.10:443, other traffic is dropped and logged; SSM still `Online`
- [~] **1.10** Hand build verified for admin and user pools; the `fw_ips` role part is still to do, and a reboot test of Unbound is pending. `fw_ips` role: Unbound with the private `mail.<domain>` record; push a route to 10.0.1.10/32 to VPN clients (decision 27) · C
  - Verify: `dig @10.0.1.10 mail.<domain> +short` from the VPN returns 10.0.2.10
- [ ] **1.11** `fw_ips` role: Suricata install, NFQUEUE wiring, `eve.json` · C
  - Verify: `suricata -T` passes; `sudo tail -f eve.json` shows flows while using the VPN
- [ ] **1.12** Custom Suricata rules and test pcaps · **M**
  - Verify: `suricata -r <pcap> -S <rules>` raises the expected alert; live traffic is dropped inline

**db, app, proxy**
- [ ] **1.13** `db` role: PostgreSQL, app user, access from the app host only · C
  - Verify: connect succeeds from app, is refused from proxy
- [ ] **1.14** `app` role: Mailbridge from ECR pinned by digest, listening on 3000, secrets from SSM · C
  - Verify: `docker inspect` shows the pinned digest; port 3000 reachable from proxy, unreachable from the VPN directly
- [ ] **1.15** `proxy` role: Nginx, TLS, rate limit, ModSecurity v3 + CRS, `certbot-dns-route53` (staging) · C
  - Verify: `curl -k https://mail.<domain>` over VPN returns 200; `?id=1' OR '1'='1` gets 403 and is in the audit log

**siem**
- [ ] **1.16** `siem` role: Wazuh manager, indexer, dashboard · C
  - Verify: dashboard reachable from the admin pool only
- [ ] **1.17** Wazuh agents and log collection on all hosts (§8 list) · C
  - Verify: agents show active; a Suricata alert, an nftables drop, a ModSecurity block and a VPN connect all appear in Wazuh

**Close-out**
- [ ] **1.18** CloudTrail to S3, GuardDuty trial · C
  - Verify: events visible; trial end date noted in `progress.md`
- [ ] **1.19** End-to-end check: VPN, `https://mail.<domain>`, OAuth login with test accounts · M+C
  - Verify: `nmap -sU -p 1194` and a TCP scan from outside show only UDP 1194 open
- [ ] **1.20** Includes the deferred network rebuild (1.5c): `make up` rebuilds the lab from clean; second Ansible run is idempotent · M+C
  - Verify: second run reports `changed=0`
- [ ] **1.21** Update docs for any deviation; confirm teardown works · M+C
  - Verify: after `terraform destroy` of `lab` (approved), no billable lab resources remain

## Phase 2: Attack scenarios (§11)

Targets: own deployment only, never Google/Microsoft APIs. Each one follows attack → detection or miss → rule/fix → re-test.

- [ ] **2.1** Outside: scan, then SQLi/XSS/brute force during a 443 window · M
- [ ] **2.2** Inside: stolen VPN cert: reachability, visibility, time to revoke via CRL; include private hosts querying 10.0.0.2 directly (decision 30) · M
- [ ] **2.3** Malicious email: HTML/JS payload, sanitising, CSP · M
- [ ] **2.4** Access control: user A reading user B's mailbox by changing IDs · M
- [ ] **2.5** Complete `findings-report.md`; TCP 443 confirmed closed again · M
  - Verify: each scenario has all four steps recorded
- [ ] **2.6** Switch to production Let's Encrypt certs, only when Marko says so · M+C
  - Verify: `curl https://mail.<domain>` succeeds without `-k`

**Tier 1 is done here.** Tier 2 starts only after this write-up.

## Tier 2 (gated)

- [ ] **T2.1** `mon` host: Prometheus, Grafana, Alertmanager, exporters
- [ ] **T2.2** App CI (§10): Jest, Playwright, k6, Trivy, SonarCloud, ZAP baseline
- [ ] **T2.3** S3 gateway endpoint with a separate `data` route table; nightly `pg_dump` to S3, plus a tested and documented restore

## Tier 3 (gated)

- [ ] **T3.1** k3s for the app tier
- [ ] **T3.2** Vulnerability scanning (Nuclei/Greenbone)
- [ ] **T3.3** ISO 27001/NIS2 controls map
