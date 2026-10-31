#!/usr/bin/env bash
# SessionStart hook: asks Claude to write the lesson if the latest session
# in docs/progress.md has no matching date section in docs/lessons.md.
root="${CLAUDE_PROJECT_DIR:-.}"
latest=$(grep -oE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}' "$root/docs/progress.md" 2>/dev/null | tail -1 | cut -d' ' -f2)
[ -n "$latest" ] || exit 0
grep -qx "## $latest" "$root/docs/lessons.md" 2>/dev/null && exit 0
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"docs/lessons.md has no section for session %s. Before starting new work, write it from docs/progress.md, docs/decisions.md, docs/rationale.md and git log, following the lessons rule in CLAUDE.md."}}\n' "$latest"
