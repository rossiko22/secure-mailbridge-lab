# Lessons

One section per session date, written as a lecture to study from.

## 2026-10-31

### Today's topic: building a private network, then proving it with code

You started with three documents and an empty AWS account. You finished with a segmented network that you built by hand and that Terraform now manages. No servers exist yet, so nothing is running, but every road, gate and guard is in place.

### The big picture

The goal of the lab is to run an app so that its only entry point is a VPN, then attack it and measure what gets detected. Before any app can run safely, it needs somewhere to live. That is what today built.

The core idea is **defence in depth**: several independent layers, so one mistake doesn't expose everything. Your layers now are:

1. **Routing:** decides where a packet can travel at all.
2. **Network ACLs:** a stateless filter at each subnet's edge.
3. **Security groups:** a stateful filter on each network interface.
4. **nftables and Suricata, later on fw-ips:** inspect and filter traffic that crosses the firewall.

An attacker now has to defeat several unrelated controls, not just one.

The second idea is **segmentation**: splitting hosts into zones so that compromising one doesn't give access to the others. The public zone holds only fw-ips. The DMZ holds the web proxy, then come app, data and mgmt. Traffic may only move one hop at a time: proxy to app, app to database.

### How we chose to work

We compared three approaches and chose to build each layer by hand, compare it with code, and then rebuild from code.

- **Why by hand first:** clicking through each option shows you what exists and why. You must be able to defend every choice in an interview.
- **Why code as well:** a hand build can't be reproduced reliably. Code can be reviewed, versioned and redeployed.
- **What the compare step gives you:** it detects **drift**, a difference between what the code says and what really exists.

You later chose to keep your hand-built network and defer the rebuild test to task 1.20. That is a reasonable call, because the network is free while idle. The trade-off to remember: `No changes` proves the code *describes* the network, not that it can *create* it. Only a rebuild proves that.

### Part 1: Securing the AWS account

The **root user** has unlimited power and IAM policies can't restrict it, so it is protected with MFA and then avoided. Daily work uses an **IAM user**, `marko-admin`, which can be limited, audited and removed.

**The Budget:** AWS does not stop spending at a limit. A Budget only warns you. You excluded credits from it, because otherwise your spending can look like about $0 while your credits drain, and the alert never fires.

### Part 2: The VPC

A **VPC** is your private network inside AWS. `10.0.0.0/16` means the first 16 bits are fixed, leaving 65,536 addresses. The `10.0.0.0/8` block is private and isn't routed on the internet.

The choices that matter:

- **VPC only, not "VPC and more":** the wizard hides how the pieces connect and can add a paid NAT Gateway.
- **No IPv6:** AWS IPv6 addresses are publicly routable, and your rules cover IPv4 only. An IPv6 path could bypass the firewall completely. Sometimes the secure choice is simply not enabling something.
- **Default tenancy:** dedicated hardware costs far more, for a compliance need a lab doesn't have.
- **DNS hostnames on:** off by default in a VPC you create yourself.

### Part 3: Subnets and routing

A **subnet** is a slice of the VPC in one Availability Zone. A subnet isn't public by nature: **its route table is what makes it public**. That is one of the most useful ideas from today.

AWS reserves 5 addresses in every subnet. That's why the VPC's DNS resolver sits at `10.0.0.2`.

An **internet gateway** is the VPC's door to the internet. Route tables send traffic to it, and the most specific matching route wins, so `10.0.x.x` stays local while everything else matches `0.0.0.0/0`.

Your two route tables tell the whole design:

- **Public:** `0.0.0.0/0` goes to the internet gateway.
- **Private:** `0.0.0.0/0` and `10.8.0.0/16` both go to the fw-ips network interface.

So every private host's internet traffic is forced through your firewall. You avoided a NAT Gateway because it bills hourly. The `10.8.0.0/16` route exists because VPN addresses sit outside the VPC. Keeping them un-NATed means the proxy sees the real client IP, so every event can be traced to one device certificate.

The **main route table** only has the `local` route, and you deliberately left it alone. A subnet you forget to associate falls back to it and gets no internet, which fails safely.

### Part 4: The network interface and source/destination check

An **ENI** is a virtual network card. You created it separately so routes could point at it before the instance exists, and so replacing the instance won't disturb the routes.

The **source/destination check** makes an ENI drop any packet not addressed to it. A router's whole job is handling other hosts' packets, so it must be off. If you left it on, everything would fail and it would look like a firewall problem. This is a classic AWS mistake, and you hit it: the check showed `True` until it was changed.

Your private routes show `blackhole`. That's expected: nothing is attached to the ENI yet.

### Part 5: VPC flow logs

Flow logs record metadata about traffic: addresses, ports, bytes, and whether it was accepted or rejected. They contain no packet contents.

They matter because Suricata and nftables only see traffic crossing fw-ips. Two hosts in the same subnet talk directly, so an attacker moving sideways there would be invisible without flow logs. The bucket sits outside the lab stack so the evidence survives a teardown.

### Part 6: Security groups

A security group is a **stateful** firewall on a network interface. Stateful means replies are allowed automatically, so you write rules only for the side that starts a connection. That's why `db` needs no rule for `app`.

Rules can reference another group, like "anything wearing `sg-proxy`". That's stronger than an IP range, because it follows a host's role rather than its address.

Terraform removes the default allow-all outbound rule, so you stated egress explicitly. Security groups are enforced outside the instance, so even root on a compromised host can't change them. `sg-fw` is the exception, with all egress allowed, because it forwards traffic for the whole VPC and nftables applies the policy.

You also emptied the VPC's default group, so attaching it by accident grants nothing.

### Part 7: Network ACLs

| | Security group | NACL |
|---|---|---|
| Applies to | A network interface | A whole subnet |
| State | Stateful | **Stateless** |
| Rules | Allow only | Allow and deny, first match wins |

Stateless means replies need their own rules. A reply lands on a random high port, the **ephemeral range** (1024-65535).

The subtle problem: private subnets must accept replies from the internet, and that range also includes ports 3000, 5432, 1514 and 1515. A simple return rule would reopen them to everyone. The fix uses rule order: 100 allows the legitimate source, 105 denies that port from everywhere, and 110 allows ephemeral ports. Because the first match wins, the service port stays protected.

Remember too that a NACL does nothing until it is **associated** with a subnet. The default NACL allows everything, so an unattached NACL is a false sense of security.

### Part 8: Terraform, state and import

A **module** is reusable code. A **root stack** is the folder you run Terraform from, and it connects modules by passing one module's outputs into another. That reference also tells Terraform the order to build things.

**State** is Terraform's record of which real resources it manages. It can hold sensitive values, so it lives in an encrypted, versioned, private S3 bucket and never in Git. A stack can't create the bucket that holds its own state, which is why you built that bucket by hand.

**`aws login`** gives short-lived credentials, so no permanent access key sits on your laptop. A leaked credential that expires does limited damage.

**`terraform plan`** compares code, state and reality. It's read-only. **`terraform import`** links a real resource to your code and changes nothing in AWS. **Import blocks** preview every import in `plan`, and only `apply` saves them.

Your first plan showed `114 to add`, which looked alarming but was correct, because the state was empty. Applying then would have built a duplicate network. After importing, the only drift was two missing `Name` tags. All 83 rules you typed matched, descriptions included. The final result was `No changes`.

**A rule for `for_each`:** keys must be known before anything is created. Use fixed values like names as keys, and let IDs be values. Our code broke this rule, and the import exposed it.

### Part 9: Continuous integration

**CI** runs your checks automatically on GitHub, so a rule like "merge only on green" is enforced by a system, not by memory. Six checks run on each pull request: `terraform fmt`, `terraform validate`, `tflint`, `checkov`, `ansible-lint` and `gitleaks`.

Actions are pinned by **commit SHA** rather than a tag. A tag can be moved to different code, while a SHA identifies exact content, which protects against a **supply chain attack**. CI never gets AWS credentials: `validate` runs with `-backend=false`, so it checks code without touching your account.

A **false positive** is a warning about something that isn't really wrong. The right response is a narrow skip with a written reason, next to the resource. Turning a check off everywhere would hide real problems later.

### Part 10: What costs money in AWS

Most networking building blocks are free: VPCs, subnets, route tables, internet gateways, security groups, NACLs and unattached ENIs. Costs come from things that run or hold capacity: instances, disks, public IPv4 addresses, NAT Gateways and load balancers.

Stopping an instance ends the compute charge, but its disk still bills. A terminated instance can leave disks, snapshots or IPs behind. That's why we scanned every region for those, not just for instances. The scan found none, so your earlier EC2 spending has stopped.

### Part 11: Logging in without SSH

**Session Manager** gives you a terminal with no inbound port. The SSM agent on the VM connects outbound to AWS, and your session travels through that connection. Two identities are involved: the **instance role** lets the VM register with SSM, and **your AWS login with MFA** decides whether you may connect. Don't mix them up: the role is for the machine, not for you.

You asked whether SSH over the VPN would be better. It's a sound idea and doesn't expose port 22 to the internet, but it adds to SSM rather than replacing it. The key concept is **out-of-band access**: a way in that doesn't depend on the thing you might break. fw-ips runs the VPN, so a mistake there would also take down SSH over the VPN, while SSM takes a separate path. Also, SSH over VPN only works from a device holding your profile and key, so it isn't truly "from anywhere".

### Part 12: The plan for fw-ips

fw-ips will use your existing ENI, so its address, security group and routes are already in place. Attaching an instance turns the `blackhole` routes `active`. The configuration order is PKI, OpenVPN, IP forwarding and NAT, the full nftables policy, Unbound, then Suricata. Each step depends on the last and gets tested before moving on.

### Mistakes and what they taught

| What happened | The lesson |
|---|---|
| Source/destination check stayed on | Verify settings with a command, don't trust the click |
| Rule 100 was TCP instead of UDP | OpenVPN here uses UDP; always check the protocol |
| NACLs weren't associated | Rules that aren't attached protect nothing |
| Region set to `eu-central-1b` | That's an Availability Zone, not a region |
| Bucket created in `us-east-1` | Buckets can't move, and a deleted name takes time to free up |
| Files saved in the module folder | Check the path; root stacks and modules are different things |
| Generated passwords pasted into chat | Treat anything pasted as exposed, and replace it |
| `grep '^Plan:'` found nothing | Terraform's color codes break matching; use `-no-color` |

### Decisions from today

The full reasoning is in `rationale.md`.

| Topic | Choice | Why |
|---|---|---|
| App image | ECR, pinned by digest | No registry password, and the exact image is guaranteed |
| DNS | Route 53 | The IAM role replaces a stored API token |
| VPN address | Elastic IP in `lab`, DNS name in profiles | No idle IP cost, and profiles survive rebuilds |
| Build order | db, app, proxy | Each layer is tested against the real one below it |
| NAT | Split from the full ruleset | Private hosts reach SSM through fw-ips |
| Repo | Public | Free branch protection can enforce green CI |
| Flow logs | S3 | Cheapest way to keep evidence past a teardown |
| Network | Kept up, rebuild deferred | Free while idle, and you chose to keep the hand build |

### Interview questions to practise

1. What makes a subnet public?
2. What's the difference between a security group and a NACL?
3. Why does a NACL need rules for ephemeral ports, and what problem does that create?
4. Why must source/destination check be off on a software router?
5. Why does VPN traffic stay un-NATed in this design?
6. Why did you skip IPv6?
7. What do flow logs show that Suricata can't?
8. What is Terraform state, and why isn't it stored in Git?
9. What does `terraform import` change in AWS?
10. Why isn't `No changes` the same as proving a rebuild works?
11. Why use temporary credentials rather than access keys?
12. How can Session Manager work with no inbound port?
13. What's the difference between an instance role and your own login?
14. Why keep out-of-band access if you also have SSH over a VPN?
15. What does stopping an instance save, and what still bills?

### What comes next

Task 1.6 builds fw-ips, your first EC2 instance. Running costs begin there. Before launch, decide what happens to the instance between sessions. Then come OpenVPN and the NAT rules you'll write yourself.

## 2026-11-01

### Today's topic: building the front door, and checking what a policy really allows

Yesterday you built roads with nothing on them. Today you launched your first server, fw-ips, gave it an identity, built a private certificate authority and got real devices connecting through OpenVPN. fw-ips doesn't route traffic yet. That starts with your NAT rules.

The most valuable moment wasn't a build step. A statement in our own docs turned out to be false, and checking it uncovered a design flaw that would have exposed every secret to every host.

### The big picture

Everything entering the lab passes through fw-ips, so it's the highest-risk host. It's internet-facing, so assume it could one day be compromised, and ask "what would an attacker get?" That question drove the main decisions today: the CA lives elsewhere, the host can only read its own secrets, and it has no SSH key to steal.

This idea is **assume breach**: design so that one compromised host doesn't hand over everything.

### Part 1: Closing tasks honestly

Tasks 1.3 and 1.4 were closed by checking what their verify steps required: no paid resources in the code, checkov green on main, and every security group and NACL rule compared with §4. `terraform plan` couldn't run because the login had expired. Rather than skip that silently, we checked the Terraform history and found that only comments had changed since the last clean plan, and recorded that in `progress.md`.

The habit to keep: when you can't run a check, say so, and state what evidence you used instead.

### Part 2: The instance role

An instance role gives a VM temporary credentials through the metadata service, so no keys are stored on disk. It has two parts: a **trust policy** saying who may use the role (here, `ec2.amazonaws.com`) and **permission policies** saying what it can do. The console also creates an **instance profile**, the wrapper that actually attaches a role to an instance.

### Part 3: Launching fw-ips

The settings that matter, and why:

- **No key pair:** Session Manager doesn't need one, so there's no key file to steal.
- **Existing ENI, no auto-assigned public IP:** the address, `sg-fw` and routes already existed. Attaching the instance turned the `blackhole` routes `active`.
- **Encrypted gp3:** the disk holds private keys.
- **Shutdown behavior Stop:** "Terminate" would delete the VM on an internal shutdown.
- **Credit specification Standard:** the t3 default is Unlimited, which can bill extra. Standard slows down instead.
- **IMDSv2 required, hop limit 1:** this blocks the classic attack where a forged web request steals a host's role credentials. A request without a token now gets `401`, which we confirmed.

SSM only came `Online` after the Elastic IP was attached, because the agent connects outbound and a host in a public subnet still needs a public address to reach the internet.

### Part 4: The package mirror test

The public NACL allows outbound 443 but not 80, and Ubuntu's sources used `http://`. The test proved it: HTTP timed out, and HTTPS returned 200. We switched apt to the HTTPS regional mirror rather than opening port 80.

A subtle point: apt already verifies packages with GPG signatures, so HTTPS wasn't needed for package integrity. The choice was about firewall policy, because opening port 80 widens the rules for all traffic, not only updates. An own mirror or proxy is parked for after Tier 1.

### Part 5: Delegating a subdomain

NS records say which servers answer for a name. Moving a whole domain would have broken the email forwarding on it, so you delegated one subdomain instead, by adding NS records for it at the parent's DNS provider. Everything else stayed put, which `dig` confirmed. This limits **blast radius**: a mistake in the lab zone can't touch the parent.

### Part 6: The offline CA

OpenVPN accepts any certificate your CA signed, and a certificate's name picks its pool. So whoever holds the CA private key can mint themselves an admin. The server never needs that key, because it verifies clients with the public `ca.crt`.

So the CA stays on your laptop, passphrase-protected, and fw-ips receives only `ca.crt`, its server cert and key, the CRL and the `tls-crypt` key. Taking over fw-ips doesn't give an attacker the ability to issue certificates. The cost is that revoking means signing a new CRL on the laptop and copying it over, which scenario 2.2 will measure.

We chose EC keys on `secp384r1` for small keys and fast handshakes. The server key has no passphrase because OpenVPN must start unattended after a reboot, which is why it's the one unencrypted key and has strict permissions. Server and client certificates are marked differently, so a stolen client cert can't impersonate the server.

A CRL is a signed list of revoked serials. `revoke` alone changes nothing on the server, because only a new `gen-crl` and a copy to fw-ips tell it anything. If a CRL expires, OpenVPN rejects everyone, so it must be re-signed before then.

### Part 7: The finding of the day

Writing up the CA backup, we stated that no instance role could read `/vpn/`. Nobody had checked. Reading `AmazonSSMManagedInstanceCore` showed `ssm:GetParameter` on `Resource: *`, and the IAM simulator returned `allowed`. Encryption didn't help either, because the default `aws/ssm` KMS key decrypts through SSM for anyone in the account allowed to call it.

So every host could have read every secret, including the proxy reading the database password. That defeats "one role per instance", and it was in the design from the start.

The fix was a customer-managed copy of the policy, minus those two actions, plus a narrow inline grant for `/vpn/fw-ips/*`. Now a new host reads nothing until granted, which is called **failing safe**. An explicit `Deny` per host would have failed open: forget one and the secrets are readable. The simulator then returned `implicitDeny` for the CA key, and a real call from fw-ips returned `AccessDeniedException`.

The lessons: a managed policy's name tells you nothing about what it grants, "encrypted" doesn't mean "restricted", and a test from the real host beats a simulator.

### Part 8: tls-crypt and OpenVPN

`tls-crypt` encrypts and authenticates the handshake with a shared key. A packet without it is dropped before TLS starts, so scanners get nothing and your certificates stay hidden. The weakness is that the key is shared by all clients, so a stolen profile exposes it, though it still doesn't let anyone in without a valid cert.

`tun0` uses a `/23`, covering both pools. Automatic addresses come only from the user range, and a `ccd` file gives the admin device its fixed address and an extra route.

You chose dynamic user addresses over `ccd-exclusive`, so that scenario 2.2 has to prove who held an address from the logs. Know the cost: those logs become required evidence, and any valid cert can connect, so revocation is the only way to cut one off.

The log taught something too. `MULTI_sva: pool returned` showed the admin device with a user address, but that line comes before the `ccd` file is applied. The final address is on the `primary virtual IP` line, and Wazuh must use that one.

### Mistakes and what they taught

| What happened | The lesson |
|---|---|
| Docs claimed no role could read `/vpn/` | A security claim needs a test, not an assumption |
| First simulator query printed a strange line | With several resources, results sit in a nested field |
| Steps were checked before they were done | Read each output against the expected one |
| Multi-line pastes lost lines to `sudo` and `apt-get` | Those commands read stdin; paste one command at a time |
| `KEY-MATCHES-CERT` passed with empty files | A comparison of two empty values is true; check for empty first |
| Fetch wrote 0-byte files with exit 0 | Exit 0 isn't proof; the snap `aws` wrote nothing to a file but worked through a pipe. The root cause is still unknown |
| First guess blamed `umask` | Test one thing at a time instead of changing fixes on a guess |
| A `ca.key` turned up on the VM | It was OpenVPN's sample file; look before assuming the worst |
| `pool returned` showed the wrong address | Read the whole log sequence, not one line |

### Decisions from today

Full reasoning is in `rationale.md`, entries 18 to 24.

| Topic | Choice | Why |
|---|---|---|
| fw-ips OS | Ubuntu 24.04 LTS | Long support, SSM agent included |
| `<domain>` | Delegated subdomain | Parent domain stays untouched |
| Packages | HTTPS mirror | Port 80 stays closed |
| VPN CA | Offline on the laptop | Compromising fw-ips can't mint certificates |
| Instance roles | Own minimal SSM policy | The AWS policy reads every parameter |
| VPN addresses | Dynamic users, fixed admin | Attribution has to be proven from logs |
| Between sessions | Stop, release the Elastic IP | Keeps the hand build at almost no cost |

### Interview questions to practise

1. What does IMDSv2 protect against, and why does a hop limit of 1 help?
2. Why does an instance in a public subnet still need a public IP to reach SSM?
3. What's the difference between a trust policy and a permission policy?
4. What is an instance profile?
5. Why doesn't `AmazonSSMManagedInstanceCore` count as least privilege?
6. Why didn't `SecureString` stop a host reading the CA backup?
7. Why does an explicit `Deny` fail open as a design, even though `Deny` beats `Allow`?
8. Why doesn't fw-ips need the CA private key?
9. Walk through revoking a stolen certificate. When does it actually stop working?
10. What happens when a CRL expires?
11. What does `tls-crypt` add on top of TLS, and what's its weakness?
12. Why was HTTPS for apt a firewall decision and not an integrity decision?
13. How does delegating a subdomain limit blast radius?
14. How would you prove which device held a VPN IP at a given time?

### What comes next

You write the 1.9a ruleset: forwarding and NAT for private subnets, with a forward chain that drops by default. Once it's reviewed, a small temporary private VM proves that SSM works through fw-ips. Each session now starts by giving fw-ips a new Elastic IP and updating the `vpn` record.
