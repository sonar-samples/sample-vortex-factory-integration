#!/usr/bin/env bash
# Fail closed unless Vortex is fully wired for the agent. Run from the workspace.
set -euo pipefail

: "${EVIDENCE_DIR:?}"
claude_home="$HOME/.claude"
fail() { echo "preflight: $*" >&2; exit 1; }

command -v sonar >/dev/null || fail "sonar is not on PATH (hooks would exit 0 silently)"
sonar auth status >/dev/null || fail "sonar auth status failed (user token and org required)"

jq -e '[.hooks.PostToolUse[]? | select(.matcher == "Edit|Write")] | length > 0' "$claude_home/settings.json" >/dev/null \
  || fail "no Edit|Write PostToolUse hook in $claude_home/settings.json"
jq -e '[.hooks.SessionStart[]? | select(.matcher == "startup|clear")] | length > 0' "$claude_home/settings.json" >/dev/null \
  || fail "no startup|clear SessionStart hook in $claude_home/settings.json"
grep -q 'Vortex analysis protocol' "$claude_home/CLAUDE.md" || fail "Vortex analysis protocol missing from $claude_home/CLAUDE.md"

[[ -f .sonar-config.json ]] || fail ".sonar-config.json missing (run: sonar link <project-key>)"
key=$(jq -r '(.project // .projects[0]).projectKey // empty' .sonar-config.json)
case "$key" in ''|REPLACE_*) fail ".sonar-config.json has no real project key" ;; *) ;; esac

if grep -qi 'skipping' "$EVIDENCE_DIR/integrate.log"; then
  fail "sonar integrate skipped a feature: $(grep -i 'skipping' "$EVIDENCE_DIR/integrate.log" | head -1)"
fi
grep -q '[^[:space:]]' "$EVIDENCE_DIR/warmup-constraints.txt" || fail "architecture get-constraints returned nothing (define the intended architecture)"

echo "vortex: enabled (project $key)" | tee "$EVIDENCE_DIR/vortex-status.txt"
