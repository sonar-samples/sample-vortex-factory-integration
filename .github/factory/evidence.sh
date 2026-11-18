#!/usr/bin/env bash
# Build evidence/summary.json from the raw transcripts. Everything comes from tool calls and
# hook events in the stream-json files, never from the agent's own account.
# env: EVIDENCE_DIR BASE_SHA ISSUE_NUMBER
set -euo pipefail

: "${EVIDENCE_DIR:?}"
cd "$EVIDENCE_DIR"

events=$(mktemp)
for f in round-*.jsonl; do
  [[ -e "$f" ]] || continue
  jq -cR --arg f "$f" 'fromjson? | select(type == "object") | . + {_file: $f}' "$f"
done >"$events"

session_ctx=$(jq -s -r '
  [ .[] | select(.type == "system" and (.hook_event // .hook_event_name // "") == "SessionStart" and .subtype == "hook_response")
    | (.stdout // .output // "") | (try (fromjson | .hookSpecificOutput.additionalContext) catch .) ] | first // ""' "$events")

calls=$(jq -s '
  def text: if type == "string" then . else map(.text? // "") | join("") end;
  (map(select(.type == "user") | .message.content[]? | select(type == "object" and .type == "tool_result"))
    | map({key: .tool_use_id, value: .}) | from_entries) as $res
  | [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "Bash" and (.input.command | test("(^|[;&|]\\s*)sonar\\s+(context|analyze agentic)")))
      | ($res[.id] // {}) as $r
      | ($r.content // "" | text) as $t
      | (.input.command | capture("(?:^|[;&|]\\s*)(?<s>sonar\\s+(?:context|analyze agentic).*)").s | split(" ") | map(select(. != ""))) as $w
      | { group: ($w[1:3] | join(" ")),
          command: .input.command,
          exit_code: (($t | capture("^Exit code (?<c>[0-9]+)").c? | tonumber) // (if $r.is_error then 1 else 0 end)),
          output_head: ($t | split("\n") | .[0:20] | join("\n")) } ]
  | group_by(.group) | map({group: .[0].group, count: length, calls: .})' "$events")

jq -n \
  --arg outcome "$(cat outcome.txt 2>/dev/null || echo unknown)" \
  --arg base "${BASE_SHA:-}" --arg issue "${ISSUE_NUMBER:-}" \
  --arg vortex "$(cat vortex-status.txt 2>/dev/null || echo not-checked)" \
  --arg ctx "$session_ctx" --argjson calls "$calls" \
  --slurpfile rounds <(cat rounds.jsonl 2>/dev/null || true) \
  '{outcome: $outcome, issue: $issue, base_sha: $base, vortex: $vortex, rounds: $rounds,
    session_start_context: $ctx, sonar_calls: $calls}' >summary.json
rm -f "$events"
echo "wrote $EVIDENCE_DIR/summary.json"
