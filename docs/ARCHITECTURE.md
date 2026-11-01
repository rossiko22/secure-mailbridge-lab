# Secure Mailbridge Lab — AWS Architecture

Private-access deployment of Mailbridge (unified Gmail/Outlook inbox) inside a segmented AWS VPC.
Only entry point: OpenVPN. Purpose: run the app securely, attack it, detect attacks, document findings.

Region: `eu-central-1` (Frankfurt) · Single AZ (lab; multi-AZ deliberately skipped for cost)
Deploy: Terraform (infra) + Ansible (config) · Teardown: `terraform destroy` when not in use

---

## 1. Diagram

```
                         Internet
                            │  UDP 1194 only (OpenVPN)
                            │  TCP 443 closed — opened only for outside-attack test windows
                            │
  VPC 10.0.0.0/16  ┌────────▼──────────────────────────────────────┐
                   │ PUBLIC 10.0.1.0/24          route: 0/0 → IGW  │
                   │ fw-ips  10.0.1.10  (t3.small, Elastic IP)     │
                   │  • OpenVPN server (tun0)                      │
                   │      users 10.8.0.0/24 · admins 10.8.1.0/24   │
                   │  • nftables firewall + NAT for private nets   │
                   │  • Suricata inline IPS on decrypted tun0      │
                   │  • Unbound DNS (pushed to VPN clients)        │
                   └────────┬──────────────────────────────────────┘
                            │ all private subnets: 0/0 → fw-ips ENI
                   ┌────────▼───────────────┐
                   │ DMZ 10.0.2.0/24        │
                   │ proxy 10.0.2.10        │ Nginx (TLS, rate limit) + ModSecurity v3 / OWASP CRS
                   └────────┬───────────────┘
                   ┌────────▼───────────────┐
                   │ APP 10.0.3.0/24        │
                   │ app   10.0.3.10        │ Mailbridge (Docker) → egress 443 to Gmail/Graph APIs
                   └────────┬───────────────┘
                   ┌────────▼───────────────┐
                   │ DATA 10.0.4.0/24       │
                   │ db    10.0.4.10        │ PostgreSQL · nightly pg_dump → S3 (gateway endpoint)
                   └────────────────────────┘
                   ┌────────────────────────┐
                   │ MGMT 10.0.5.0/24       │ reachable only from admin VPN pool 10.8.1.0/24
                   │ siem  10.0.5.10        │ Wazuh (manager + indexer + dashboard)
                   │ mon   10.0.5.20        │ Prometheus + Grafana + Alertmanager
                   └────────────────────────┘

  Outside AWS: GitHub Actions → Jest/Playwright, k6, Trivy, SonarCloud, ZAP baseline
```

---

## 2. Subnets & routing

| Subnet | CIDR | Internet route | Notes |
|---|---|---|---|
| public | 10.0.1.0/24 | → Internet Gateway | only fw-ips lives here |
| dmz | 10.0.2.0/24 | → fw-ips ENI | no direct internet |
| app | 10.0.3.0/24 | → fw-ips ENI | egress for Gmail/Graph APIs via fw |
| data | 10.0.4.0/24 | → fw-ips ENI | + S3 **gateway endpoint** (free) for backups, added in Tier 2 (T2.3) |
| mgmt | 10.0.5.0/24 | → fw-ips ENI | admin-only |

- **VPN pools are routed, not NATed:** VPC route `10.8.0.0/16 → fw-ips ENI`. Nginx, Wazuh and Suricata see the real VPN client IP, so every event is attributable to a device certificate.
- fw-ips: **source/destination check disabled**. Its ENI is a standalone resource, so routes can target it before the instance exists.
- Tier 1 uses one private route table for dmz, app, data and mgmt. `data` gets its own table when the S3 endpoint is added.
- No NAT Gateway, no ALB, no interface endpoints (all bill hourly).

---

## 3. Instances

| Name | Type | Disk (gp3, encrypted) | Role | Tier |
|---|---|---|---|---|
| fw-ips | t3.small | 20 GB | OpenVPN, nftables, NAT, Suricata, Unbound | 1 |
| proxy | t3.micro | 10 GB | Nginx + ModSecurity v3 (OWASP CRS), Certbot | 1 |
| app | t3.small | 20 GB | Mailbridge in Docker | 1 |
| db | t3.micro | 20 GB | PostgreSQL | 1 |
| siem | t3.medium (t3.large if the indexer struggles) | 50 GB | Wazuh | 1 |
| mon | t3.small | 20 GB | Prometheus, Grafana, Alertmanager | 2 |

All instances: IMDSv2 required · SSM agent (admin access, no SSH from internet) · unattended security updates · apt over HTTPS (regional Ubuntu mirror, port 80 stays closed) · Wazuh agent · node_exporter.

- fw-ips: runs Ubuntu 24.04 LTS (official Canonical AMI, x86_64).
- fw-ips: its Elastic IP belongs to the `lab` stack and exists only during a session. Clients connect to `vpn.<domain>` (TTL 60), which `lab` updates on each apply.
- app: pulls the Mailbridge image from ECR with its instance role, pinned by digest (`image@sha256:...`).
- proxy: Certbot authenticates to Route 53 with its instance role; no stored DNS credentials.

---

## 4. Security groups (stateful, least privilege)

| SG | Inbound | From |
|---|---|---|
| sg-fw | UDP 1194 | 0.0.0.0/0 (or home IP if static) |
| | all (to be routed/NATed) | 10.0.0.0/16 |
| | TCP 443 | 0.0.0.0/0 — **test windows only** |
| sg-proxy | TCP 443 | 10.8.0.0/22 (VPN pools) |
| sg-app | TCP 3000 | sg-proxy |
| sg-db | TCP 5432 | sg-app |
| sg-siem | TCP 1514, 1515 (agents) | 10.0.0.0/16 |
| | TCP 443 (dashboard) | 10.8.1.0/24 (admin pool) |
| sg-mon | TCP 3000 (Grafana) | 10.8.1.0/24 |
| all | TCP 9100 (node_exporter), 9187 (postgres_exporter on db) | sg-mon |

**Egress (explicit, stateful replies need no rule):**

| SG | Outbound | To |
|---|---|---|
| sg-fw | all | 0.0.0.0/0 (forwarded traffic; nftables applies the policy) |
| sg-proxy, sg-app, sg-db, sg-siem | TCP 443, UDP 123 | 0.0.0.0/0 (through fw-ips) |
| | TCP/UDP 53 | 10.0.1.10/32 (Unbound) |
| sg-proxy, sg-app, sg-db | TCP 1514, 1515 | sg-siem |
| sg-proxy | TCP 3000 | sg-app |
| sg-app | TCP 5432 | sg-db |

The VPC default security group has no rules.

Second layer: Network ACLs per subnet mirroring the same flows. Third layer: nftables on fw-ips.

**Network ACLs (stateless, one per subnet, first match wins, default deny).** `eph` is TCP/UDP 1024–65535.

| Subnet | Inbound | Outbound |
|---|---|---|
| public | 100 UDP 1194 from 0.0.0.0/0 · 110 all from 10.0.0.0/16 · 120 TCP eph from 0.0.0.0/0 · 130 UDP eph from 0.0.0.0/0 | 100 all to 10.0.0.0/16 · 110 TCP 443 to 0.0.0.0/0 · 120 UDP 123 to 0.0.0.0/0 · 130 UDP eph to 0.0.0.0/0 |
| dmz | 100 TCP 443 from 10.8.0.0/22 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | 100 TCP 3000 to 10.0.3.0/24 · baseline · 150 agents · 160 TCP eph to 10.8.0.0/22 |
| app | 100 TCP 3000 from 10.0.2.0/24 · 105 deny TCP 3000 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | 100 TCP 5432 to 10.0.4.0/24 · baseline · 150 agents · 160 TCP eph to 10.0.2.0/24 |
| data | 100 TCP 5432 from 10.0.3.0/24 · 105 deny TCP 5432 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | baseline · 150 agents · 160 TCP eph to 10.0.3.0/24 |
| mgmt | 100 TCP 1514–1515 from 10.0.0.0/16 · 105 deny TCP 1514–1515 from 0.0.0.0/0 · 110 TCP 443 from 10.8.1.0/24 · 120 TCP eph from 0.0.0.0/0 · 130 UDP eph from 0.0.0.0/0 | baseline · 160 TCP eph to 10.0.0.0/16 · 170 TCP eph to 10.8.1.0/24 |

Baseline outbound: 110 TCP 443 to 0.0.0.0/0 · 120 UDP 123 to 0.0.0.0/0 · 130 UDP 53 and 140 TCP 53 to 10.0.1.10/32. Agents: TCP 1514–1515 to 10.0.5.0/24. A 443 test window also needs inbound TCP 443 and outbound TCP eph to 0.0.0.0/0 on public.

**nftables on fw-ips (core rules):** fw-ips has one interface, so rules separate internet from VPC traffic by address. NAT applies only to private subnets going to non-VPC addresses, never to VPN pools.
- `tun0` user pool (10.8.0.0/24) → only `10.0.2.10:443`
- `tun0` admin pool (10.8.1.0/24) → proxy:443 + mgmt subnet
- private subnets → internet: TCP 443 (+ DNS via Unbound, NTP) only, logged
- to fw-ips itself: UDP 1194, DHCP replies, DNS to 10.0.1.10 from private subnets and VPN pools, ping from the admin pool only; `output` stays open
- everything else: drop + log → Wazuh
- forwarded `tun0` traffic → NFQUEUE → Suricata (inline, can drop), in a separate chain after the firewall rules

---

## 5. VPN (OpenVPN)

- Own PKI with easy-rsa · **one certificate per device** · revocation via CRL
- **Offline CA:** the CA and all signing stay on Marko's laptop, outside the repo, with the key passphrase-protected. fw-ips holds only `ca.crt`, its server cert and key, the CRL and the `tls-crypt` key. The encrypted CA key is backed up to SSM under `/vpn/`, which no instance role can read.
- Per-client config (`client-config-dir`): user certs → dynamic pool in 10.8.0.0/24, admin cert → fixed address in 10.8.1.0/24. `ccd-exclusive` is off, so attribution of user IPs comes from OpenVPN connection logs in Wazuh
- Hardening: `tls-crypt`, `data-ciphers AES-256-GCM`, `tls-version-min 1.3`, `crl-verify`, `user nobody`
- Pushed: routes to 10.0.2.0/24 and 10.0.1.10/32 (users) or + 10.0.5.0/24 (admins), DNS 10.0.1.10
- Client profiles use `remote vpn.<domain> 1194 udp`, so they survive rebuilds
- Client: `sudo openvpn --config marko-laptop.ovpn` → `https://mail.<domain>`

---

## 6. DNS & TLS

- Unbound on fw-ips (10.0.1.10): private record `mail.<domain> → 10.0.2.10`, forwards everything else to AmazonProvidedDNS (10.0.0.2). The name resolves only inside the VPN.
- Certbot (`certbot-dns-route53`) obtains a Let's Encrypt cert via **DNS-01 challenge** using the proxy instance role — no public exposure and no stored API token. Nginx serves it; renewal via systemd timer.
- **Staging certificates while building and rebuilding; switch to production certs once the setup is stable** (avoids Let's Encrypt rate limits).
- DNS provider: **Route 53** public hosted zone in the `persistent` stack. `<domain>` is a subdomain of a domain Marko already owns, delegated by adding NS records for that subdomain at the parent's DNS provider. The parent domain stays where it is, and the real name stays out of this public repo.
- Public records: `_acme-challenge.mail.<domain>` (TXT, Certbot) and `vpn.<domain>` (A, TTL 60, written by `lab`). `mail.<domain>` is never public.
- OAuth redirect `https://mail.<domain>/oauth/callback` works because the redirect happens in the browser, which is inside the tunnel.
- Google/Microsoft OAuth apps stay in **testing mode, test accounts only**.

---

## 7. Secrets & IAM

- SSM Parameter Store (SecureString): OAuth client secrets, DB password, token encryption key (`/mailbridge/*`)
- Mailbox OAuth tokens encrypted in the DB by the app (key from Parameter Store)
- One IAM role per instance: all → `mailbridge-lab-ssm-min` (`AmazonSSMManagedInstanceCore` without `ssm:GetParameter` and `ssm:GetParameters`, so no host reads a parameter unless granted); fw-ips → read `/vpn/fw-ips/*` only; app → read `/mailbridge/*` + pull from the Mailbridge ECR repository only; proxy → `route53:ListHostedZones`, `route53:GetChange`, and `route53:ChangeResourceRecordSets` on this zone limited to the `_acme-challenge` name; db → `s3:PutObject` on backup prefix only
- No stored AWS keys on any instance: roles provide temporary credentials through IMDSv2
- CloudTrail (management events) → S3 · GuardDuty free trial during testing
- Terraform runs from the laptop with temporary `aws login` credentials; no access keys exist
- Terraform state: versioned, encrypted S3 bucket with native locking (`use_lockfile`), hand-built then imported into `persistent`

---

## 8. Detection & monitoring

**Security (Wazuh — "is something malicious happening?")**
- Suricata `eve.json`, nftables drops, Nginx access/error logs + ModSecurity audit log, auth logs, OpenVPN connect/disconnect, file integrity monitoring

**Network evidence (VPC flow logs)**
- All traffic metadata → S3 bucket in `persistent`, 30-day lifecycle. Used for investigation, including traffic that never crosses fw-ips. Not fed to Wazuh in Tier 1.

**Health (Prometheus/Grafana — "is everything healthy?")** — Tier 2
- node_exporter on all VMs, postgres_exporter on db, blackbox_exporter probing `https://mail.<domain>`
- Alertmanager → email/Discord: host down, disk > 80%, cert expiry < 14 days, probe failing

---

## 9. Backups

- Nightly `pg_dump` → S3 bucket (SSE, versioning, 30-day lifecycle) via gateway endpoint
- **Restore tested and documented** (a backup that was never restored doesn't count)

---

## 10. CI/CD (GitHub Actions) — Tier 2

Jest + Supertest (API) · Playwright (UI) · k6 (load) · Trivy (image scan) · SonarCloud (code quality) · OWASP ZAP baseline · build & push image

---

## 11. Attack scenarios (findings report)

| Position | Tests |
|---|---|
| Outside (internet) | Scan: only UDP 1194 should respond. During 443 window: SQLi/XSS/brute force vs WAF + Suricata |
| Inside (stolen VPN cert) | What's reachable? What does Suricata/Wazuh see? Time to revoke via CRL? |
| Malicious email | HTML/JS payload in an incoming email → is it sanitized? CSP? |
| Access control | Can user A read user B's mailbox by changing IDs? |

For each: attack → detection (or miss) → custom rule/fix → re-test.

---

## 12. Cost control

- AWS Budget alert at **$20** on day one
- `terraform destroy` when not in use (stopped VMs still pay for disks + public IP). Exception: during the fw-ips hand build, stop the instance and release the Elastic IP, until Ansible can rebuild it
- Approx. compute ~$0.15/hour for the full set — a few hours per week stays within credits (verify in AWS Pricing Calculator)

---

## 13. Build order

Everything runs on AWS. There is no VPS phase, and no VPS is used anywhere in this project.

1. Tier 1 on AWS: network (VPC, subnets, IGW, routes, SGs — free) → fw-ips (OpenVPN, then NAT, because private hosts reach SSM through it) → db → app → proxy → siem. Built bottom-up, so each host is tested against its real dependency.
2. Tier 1 attack scenarios → findings report
3. Tier 2: monitoring, CI, backups + restore test
4. Tier 3: k3s for app tier, vuln scanning (Nuclei/Greenbone), ISO 27001/NIS2 controls map

**Method for each layer:** build by hand → test → compare with code (`terraform import` + `plan`, or `ansible-playbook --check --diff`) → destroy and rebuild from code → re-test. The final state is always Terraform + Ansible. Exception: the network layer stays up between sessions and its rebuild test is deferred to task 1.20; paid resources are still removed after each session.

**Do not start a tier until the previous tier's write-up is done.**

---

## Repo layout

```
secure-mailbridge-lab/
  terraform/
    modules/      network/ security/ compute/   (shared)
    persistent/   created once, never destroyed: encrypted VPN CA backup + secrets, backup bucket, flow log bucket, state bucket, Route 53 zone, ECR repository, Budget
    lab/          VPC, subnets, SGs (free, kept between sessions) · VMs, Elastic IP, vpn.<domain> record (removed after every session) (uses modules/)
  ansible/        roles: fw_ips/ proxy/ app/ db/ siem/ mon/   (Ansible role names cannot contain hyphens; the host stays fw-ips)
  suricata-rules/ custom rules + test pcaps
  docs/           ARCHITECTURE.md · TASKS.md · decisions.md · rationale.md · progress.md · threat-model.md · findings-report.md · iso27001-map.md
  .github/workflows/
  README.md       one-command deploy + teardown
```
