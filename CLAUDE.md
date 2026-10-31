# CLAUDE.md — Secure Mailbridge Lab

## What this repo is
A segmented AWS lab that runs Mailbridge (unified Gmail/Outlook inbox) behind OpenVPN,
with Suricata inline IPS, Wazuh SIEM and Prometheus/Grafana. I attack my own deployment,
measure detection, fix, and document findings.
Full design: `docs/ARCHITECTURE.md` — it is the source of truth. If something conflicts with it, stop and ask.

## Current scope
- Current tier: **Tier 1** (fw-ips, proxy, app, db, siem). Do not add Tier 2/3 components unless I ask.
- Phase: **AWS only.** There is no VPS phase. My VPS hosts a different app: never connect to it, deploy to it, or reference it in this repo.

## Stack
Terraform (`terraform/modules` shared, `terraform/persistent`, `terraform/lab`) · Ansible (`ansible/site.yml`, one role per host)
OpenVPN (easy-rsa PKI) · nftables · Suricata (NFQUEUE on tun0) · Unbound · Nginx + ModSecurity v3 (OWASP CRS) + Certbot
PostgreSQL · Wazuh · Docker · eu-central-1

## Hard rules
- **Never run `terraform apply`, `terraform destroy` or anything that creates AWS resources without asking me first.**
- Cost guardrails: no NAT Gateway, no ALB, no interface endpoints; t3 instances use `credit_specification = "standard"`.
- No secrets in the repo. Secrets come from SSM Parameter Store. `.ovpn`, keys and `*.tfstate` are gitignored.
- Security groups and nftables follow `docs/ARCHITECTURE.md` exactly (least privilege, one hop each).
- Ansible roles must be idempotent.
- Let's Encrypt: use the **staging** endpoint while building; I'll say when to switch to production.
- Attack tooling targets only my own deployment, never Google/Microsoft APIs or anything I don't own.

## How to work with me (this is a learning project)
- I need to understand and defend every line in interviews and at faculty.
- Before writing a non-trivial file, explain the approach in a few lines and wait for my OK.
- **I write the Suricata rules and the core nftables ruleset myself.** You review them and point out mistakes; don't write them for me unless I explicitly ask.
- After each change, tell me how to verify it (command + expected output).
- Keep changes small: one role, module or rule set per step.

## Repo conventions
- Branch per change, Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), merge only on green CI.
- `docs/progress.md`: update at the end of every session — what was done, what's verified, next step.
- Every design decision gets documented, same format every time:
  - `docs/decisions.md`: one line (date · decision · why).
  - `docs/rationale.md`: a short section (about half a page) with the problem, the options considered, what we chose and why, the trade-off we accepted, and how to verify it once built.
  - When a decision changes the design, update `docs/ARCHITECTURE.md` and `docs/TASKS.md` in the same commit.
  - Present options to me as A/B/C with your recommendation first, and explain the underlying concept so I can defend the choice in an interview.
- CI must pass: `terraform fmt -check`, `terraform validate`, `tflint`, `checkov` (IaC security scan), `ansible-lint`, `gitleaks` (secret scan).
- Pre-commit runs `gitleaks` and `terraform fmt` locally.

## Done means
Deploys with `make up`, verified with the commands in the docs, and the relevant section of
`docs/findings-report.md` or `docs/ARCHITECTURE.md` is updated.
