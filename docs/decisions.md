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
