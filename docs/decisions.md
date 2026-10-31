# Decisions

Format: date · decision · why

- 2026-10-31 · Moved ARCHITECTURE.md to docs/ · CLAUDE.md and the repo layout both reference that path
- 2026-10-31 · Moved settings.json to .claude/ · Claude Code does not load permissions from the repo root
- 2026-10-31 · terraform/ has persistent/ + lab/ root stacks sharing modules/ · persistent resources survive the per-session destroy of lab
- 2026-10-31 · Pre-commit uses local hooks (installed gitleaks and terraform binaries) · no third-party hook repos to download or pin; local gitleaks is an older build, so it uses `protect --staged`
- 2026-10-31 · Mailbridge image lives in Amazon ECR, pinned by digest · app pulls with its IAM role, so no registry password exists, and the deployed image is immutable
- 2026-10-31 · Route 53 hosts DNS, domain registered anywhere and delegated · Certbot DNS-01 uses the proxy IAM role instead of a stored API token, and all infra stays under one Terraform provider
- 2026-10-31 · Elastic IP belongs to lab, clients connect to `vpn.<domain>` with a low TTL; Budget belongs to persistent · no ~$3.60/month idle IPv4 charge, and .ovpn profiles survive rebuilds
- 2026-10-31 · Build order is db → app → proxy · each host is tested against its real dependency
- 2026-10-31 · Task 1.9 split into NAT first, full nftables policy second · private hosts need NAT to reach SSM, and a smaller first step is easier to debug
- 2026-10-31 · GitHub repo is public · free branch protection can enforce merge on green CI
- 2026-10-31 · Security groups live in modules/security, separate from modules/network · routing and access control stay independently reviewable
- 2026-10-31 · S3 gateway endpoint is deferred to T2.3, with one private route table until then · nothing in Tier 1 uses it
- 2026-10-31 · Security groups use explicit egress per group · a compromised host is limited at its own interface as well as by nftables
- 2026-10-31 · fw-ips ENI is a standalone resource in modules/network · routes can target it before the instance exists and survive instance replacement
- 2026-10-31 · Each layer is built by hand first, then compared with code, then rebuilt from code · hands-on understanding plus a proven, repeatable deployment
- 2026-10-31 · VPC flow logs go to an S3 bucket in persistent · evidence covers traffic that never crosses fw-ips and survives lab teardown, at lower cost than CloudWatch
- 2026-10-31 · NACLs allow ephemeral return ports and deny app and db service ports just before that rule · stateless return rules would otherwise reopen ports 3000, 5432 and 1514-1515 to every subnet
