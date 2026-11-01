# Secure Mailbridge Lab

Segmented AWS lab running Mailbridge behind OpenVPN, with Suricata inline IPS and Wazuh SIEM.
Design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · Tasks: [docs/TASKS.md](docs/TASKS.md)

## End-state architecture

This is the planned finished lab, Tiers 1 to 3. It is not what runs today: see [docs/TASKS.md](docs/TASKS.md) for current progress.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) stays the source of truth.

```mermaid
flowchart TB
    subgraph outside["Outside AWS"]
        direction LR
        user["VPN user<br/>one certificate per device<br/>pool 10.8.0.0/24"]
        admin["VPN admin<br/>fixed address<br/>pool 10.8.1.0/24"]
        tester["Attack tests<br/>own deployment only"]
        gha["GitHub Actions<br/>tests, scans, image build"]
        apis["Gmail and<br/>Microsoft Graph APIs"]
        notify["Email / Discord"]
    end

    subgraph vpc["VPC 10.0.0.0/16, eu-central-1, single AZ"]
        subgraph public["PUBLIC 10.0.1.0/24, the only route to the Internet Gateway"]
            ovpn["OpenVPN<br/>fw-ips 10.0.1.10, tun0"]
            nft["nftables<br/>firewall and NAT"]
            suricata["Suricata<br/>inline IPS"]
            unbound["Unbound DNS"]
        end
        subgraph dmz["DMZ 10.0.2.0/24"]
            proxy["proxy 10.0.2.10<br/>Nginx, ModSecurity + OWASP CRS, Certbot"]
        end
        subgraph apptier["APP 10.0.3.0/24"]
            app["app 10.0.3.10<br/>Mailbridge in Docker<br/>k3s in Tier 3"]
        end
        subgraph data["DATA 10.0.4.0/24"]
            db["db 10.0.4.10<br/>PostgreSQL"]
        end
        subgraph mgmt["MGMT 10.0.5.0/24, admin pool only"]
            siem["siem 10.0.5.10<br/>Wazuh"]
            mon["mon 10.0.5.20<br/>Prometheus, Grafana,<br/>Alertmanager"]
        end
    end

    subgraph aws["AWS managed services"]
        direction LR
        ssm["SSM<br/>secrets, admin sessions"]
        ecr["ECR<br/>Mailbridge image"]
        r53["Route 53<br/>public DNS, DNS-01"]
        s3[("S3<br/>backups, flow logs, audit logs")]
        audit["CloudTrail, GuardDuty,<br/>VPC flow logs"]
    end

    scanner["Vulnerability scanning<br/>Nuclei / Greenbone<br/>placement to be decided"]

    user ==>|"UDP 1194"| ovpn
    admin ==>|"UDP 1194"| ovpn
    tester -.->|"TCP 443, test windows only"| nft
    ovpn ==>|"decrypted traffic"| nft
    ovpn -->|"DNS"| unbound
    nft <-->|"NFQUEUE, can drop"| suricata
    nft ==>|"TCP 443"| proxy
    nft -->|"admin pool: 443, 3000"| mgmt
    proxy ==>|"TCP 3000"| app
    app ==>|"TCP 5432"| db

    dmz -->|"egress: TCP 443, NTP, DNS"| nft
    apptier -->|"egress"| nft
    data -->|"egress"| nft
    nft -->|"NAT, logged"| apis
    nft -->|"NAT, logged"| aws

    gha -->|"push image"| ecr
    db -.->|"nightly pg_dump, gateway endpoint"| s3
    audit -.-> s3

    public -.->|"Wazuh agents 1514, 1515"| siem
    dmz -.->|"agents"| siem
    apptier -.->|"agents"| siem
    data -.->|"agents"| siem
    mon -.->|"scrape 9100, 9187"| dmz
    mon -.->|"scrape"| apptier
    mon -.->|"scrape"| data
    mon -.->|"alerts"| notify

    classDef tier1 fill:#dbeafe,stroke:#1d4ed8,color:#111827
    classDef tier2 fill:#dcfce7,stroke:#15803d,color:#111827
    classDef tier3 fill:#fef3c7,stroke:#b45309,color:#111827
    classDef ext fill:#f3f4f6,stroke:#6b7280,color:#111827
    class ovpn,nft,suricata,unbound,proxy,app,db,siem,ssm,ecr,r53,audit,s3 tier1
    class mon,gha tier2
    class scanner tier3
    class user,admin,tester,apis,notify ext
```

**Colours:** blue is Tier 1, green is Tier 2, amber is Tier 3, grey is outside the lab.
**Lines:** thick is the user request path, thin is admin and outbound traffic, dotted is telemetry, backups and test-only paths.

- **One way in:** clients reach the app only through OpenVPN. TCP 443 on fw-ips opens only for outside-attack test windows.
- **One hop at a time:** proxy talks to app, and app talks to db. No subnet can skip a layer.
- **Inspected and attributable:** Suricata sees decrypted VPN traffic inline. VPN pools are routed, not NATed, so every log shows the real client address.
- **Private by default:** `mail.<domain>` resolves only inside the VPN, and all private subnets leave through fw-ips.

TODO: one-command deploy + teardown (`make up` / `make down`) once the Makefile exists.
