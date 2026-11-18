#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Synthetic stream-json transcript. Hook event field names are the part to confirm on a live run.
cat >round-0.jsonl <<'JSON'
{"type":"system","subtype":"hook_response","hook_event":"SessionStart","stdout":"{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"Mandatory workflows: run sonar context guidelines get\"}}"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sonar context guidelines get --files src/A.java"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"rule one\nrule two"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sonar context navigation get-map --depth 0"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"Exit code 2\ndata_loading"}]}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"cd /work/ws; sonar context guidelines get --languages java 2>&1 | head -80"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"rules"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"ls build | grep x; sonar analyze agentic --depth DEEP --file A.java"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t5","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"./gradlew check"}}]}}
{"type":"result","subtype":"success"}
JSON
echo '{"round":0,"findings":0}' >rounds.jsonl
echo clean >outcome.txt

EVIDENCE_DIR=$tmp BASE_SHA=abc ISSUE_NUMBER=7 "$factory/evidence.sh" >/dev/null
check "outcome" clean "$(jq -r .outcome summary.json)"
check "session start text" "Mandatory workflows: run sonar context guidelines get" "$(jq -r .session_start_context summary.json)"
check "groups" "analyze agentic,context guidelines,context navigation" "$(jq -r '[.sonar_calls[].group] | join(",")' summary.json)"
check "non-sonar calls excluded" 4 "$(jq '[.sonar_calls[].count] | add' summary.json)"
check "exit code from result text" 2 "$(jq '.sonar_calls[] | select(.group == "context navigation") | .calls[0].exit_code' summary.json)"
check "success exit code" 0 "$(jq '.sonar_calls[] | select(.group == "context guidelines") | .calls[0].exit_code' summary.json)"
finish
