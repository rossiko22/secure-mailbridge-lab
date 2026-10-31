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
- Next: confirm marko-admin MFA (1.1), then hand-build the network (1.5a). NACLs (rest of 1.4) and CI (0.5) still open; the stacked branches wait for CI.
