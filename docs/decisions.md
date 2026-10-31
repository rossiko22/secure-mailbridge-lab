# Decisions

Format: date · decision · why

- 2026-10-31 · Moved ARCHITECTURE.md to docs/ · CLAUDE.md and the repo layout both reference that path
- 2026-10-31 · Moved settings.json to .claude/ · Claude Code does not load permissions from the repo root
- 2026-10-31 · terraform/ has persistent/ + lab/ root stacks sharing modules/ · persistent resources survive the per-session destroy of lab
- 2026-10-31 · Pre-commit uses local hooks (installed gitleaks and terraform binaries) · no third-party hook repos to download or pin; local gitleaks is an older build, so it uses `protect --staged`
