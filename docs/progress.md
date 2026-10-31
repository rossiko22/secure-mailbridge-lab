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
- Next: 1.5c: run `aws login` if needed, `terraform destroy`, `terraform apply`, then re-run the 1.5a checks. Use `-no-color` when grepping Terraform output. NACLs (rest of 1.4) and CI (0.5) still open; the stacked branches wait for CI.
