# Progress log

Update at the end of every session: what was done, what's verified, next step.

## 2026-10-31
- Done: repo initialised, folder structure created, docs stubbed, docs/TASKS.md written and aligned with the updated ARCHITECTURE.md build order.
- Verified: secret patterns ignored by git (`git check-ignore`); gitleaks finds no leaks in the initial commit; pre-commit blocked a fake AWS key and reformatted a badly formatted .tf file.
- Done: pre-commit configured with gitleaks and terraform fmt (branch chore/pre-commit).
- Done: six design decisions documented (decisions.md, rationale.md), ARCHITECTURE.md and TASKS.md updated, CLAUDE.md convention added, public GitHub repo created (nothing pushed yet).
- Verified: permissions active (`terraform apply` under deny, confirmed by Marko).
- Done: modules/network and modules/security (Tier 1 security groups) written on stacked feat/ branches; more decisions documented.
- Verified locally only: `terraform fmt`, `terraform validate`, `tflint`, `checkov` run; nothing planned or applied. Open checkov failures are listed in TASKS.md 1.3 and 1.4.
- Decided: hand build, compare, rebuild per layer (decision 11).
- Done: Budget created by hand and verified (1.1b); flow logs added to modules/network (decision 12).
- Done: account safety (1.1); VPC and five subnets built by hand and checked in CloudShell.
- Done: internet gateway, public and private route tables, fw-ips ENI (source/dest check off); checked in CloudShell.
- Done: flow log bucket (public access blocked, 30-day lifecycle) and VPC flow log `ACTIVE`; checked in CloudShell.
- Done: five Tier 1 security groups built by hand, rules checked against §4; default group emptied; sg-fw attached to the fw-ips ENI.
- Done: NACL rules designed and documented (decision 13).
- Done: five NACLs built by hand and associated with their subnets; 1.5a finished; NACLs added to modules/security, 50 rules matched against the live output.
- Decided: `aws login` for laptop credentials, S3 for Terraform state (decisions 14, 15).
- Done: state bucket built by hand and checked; `aws login` working as marko-admin; terraform/lab root stack written (local validate only, nothing planned or applied).
- Done: 114 hand-built resources imported into Terraform; the only drift was two missing `Name` tags; final `terraform plan` reports no changes (1.5b). Fixed NACL `for_each` to use static keys.
- Verified: `terraform plan -destroy` shows 114 to destroy and nothing else; the destroy itself has not been run.
- Decided: keep the hand-built network; rebuild test deferred to 1.20 (decision 16).
- Done: six CI checks added with actions pinned by commit; documented checkov skips (decision 17); all work merged to main through PR 1 on green CI; branch protection on main requires all six checks.
- Next: fw-ips (task 1.6). Use `-no-color` when grepping Terraform output. NACLs (rest of 1.4) and CI (0.5) still open; the stacked branches wait for CI.
- Verified: all enabled regions have no instances, disks, snapshots, public IPs, NAT Gateways or load balancers; October spend so far is about $1.09 before credits, mostly earlier EC2 use.
- Discussed: the fw-ips plan and SSM versus SSH over the VPN. Open decisions are listed in TASKS.md; nothing was changed.
- Next: `Read START.md`, settle the open items for 1.6, then build fw-ips, starting with the IAM role.

## 2026-11-01
- Verified: 1.3 and 1.4 closed. No NAT Gateway, ALB or endpoint resource exists in the code; checkov is green on main; every Tier 1 security group and NACL rule matches §4 line by line. `terraform plan` was not re-run (session expired); the last clean plan predates only comment-level changes to the Terraform code.
- Done by hand: fw-ips (Ubuntu 24.04, role, encrypted gp3, Elastic IP); patched, apt over HTTPS; Route 53 zone delegated and `vpn` record added; offline CA on the laptop with backups in SSM; server and device certs, one test revocation; `/vpn/fw-ips/*` parameters fetched to the VM; OpenVPN running.
- Found and fixed: `AmazonSSMManagedInstanceCore` could read every parameter; the fw-ips role now uses `mailbridge-lab-ssm-min` and a grant for `/vpn/fw-ips/*` (decision 22).
- Verified: IMDSv2 returns 401 without a token; simulator and a real call deny `/vpn/ca/key` from fw-ips; server cert and CRL verify on the VM with the revoked serial listed; no CA key on the VM; user cert got 10.8.0.x and admin cert got 10.8.1.10; `dig` confirms delegation with parent MX unchanged.
- Not done: Ansible and Terraform for fw-ips. Role resources, parameters and the zone were made by hand and aren't in code yet. The cause of the snap `aws` writing 0 bytes to a file is unknown (a pipe works).
- Next: `Read START.md`. Allocate and associate a new Elastic IP, start fw-ips, update the `vpn` record, and confirm a VPN connection. Then Marko writes the 1.9a ruleset for review.
- Done by hand (evening): nftables forwarding, NAT and the full §4 policy (1.9a, 1.9b), Unbound and the VPN DNS route (1.10), Suricata inline with NFQUEUE (1.11), and five custom rules with synthetic captures (1.12). The rulesets and rules were written by Claude at Marko's explicit request. Merged through PRs 6 to 9.
- Verified: a temporary private VM reached SSM and the internet as the Elastic IP, then was terminated; both VPN pools behave as §4 says, with drops logged; DNS works from both pools and `mail.<domain>` doesn't resolve publicly; Suricata fails closed; each capture raises only its intended rule; a live flood of 80 connections gave 60 accepted and 20 blocked; all services and rules survived a reboot, before the custom rules were added. The custom rules loaded through a restart.
- Decided: decisions 25 to 35. Private hosts keep AmazonProvidedDNS (known gap for 2.2), Unbound doesn't validate DNSSEC, and Suricata sees TLS metadata and allowed traffic only, so §11 was corrected.
- Found: the temporary VM launched with the fw-ips role by mistake, for about 3.5 minutes; CloudTrail shows it read no parameters, so no key rotation.
- Not done: Terraform and Ansible for fw-ips; the OpenVPN `server.conf` isn't in the repo; `suricata-update` isn't scheduled; rules 1000001, 2, 3 and 5 haven't seen real TLS; why `reload-rules` was refused once is unknown.
- Next: `Read START.md`. Decide how Ansible connects over SSM, then write the `fw_ips` role, then 1.6, then the rebuild test, all before starting `db`.
