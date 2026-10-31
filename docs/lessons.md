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

### What comes next

Task 1.6 builds fw-ips, your first EC2 instance. It turns the `blackhole` routes `active`, and running costs begin there. Then come OpenVPN and the NAT rules you'll write yourself.
