# Decisions

Format: date · decision · why

- 2026-10-31 · Moved ARCHITECTURE.md to docs/ · CLAUDE.md and the repo layout both reference that path
- 2026-10-31 · Moved settings.json to .claude/ · Claude Code does not load permissions from the repo root
- 2026-10-31 · terraform/ has persistent/ + lab/ root stacks sharing modules/ · persistent resources survive the per-session destroy of lab
