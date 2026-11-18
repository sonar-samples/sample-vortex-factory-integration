#!/usr/bin/env bash
# Run the agent, check its work, and repair up to MAX_REPAIR times. Writes the patch on success.
# env: WS TASK_FILE BASE_SHA EVIDENCE_DIR PATCH_DIR   (GITHUB_OUTPUT optional)
# outcome: clean | no-change | unresolved | no-ci-baseline | agent-error | error
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=factory.env
source "$here/factory.env"
: "${WS:?}" "${TASK_FILE:?}" "${BASE_SHA:?}" "${EVIDENCE_DIR:?}" "${PATCH_DIR:?}"
mkdir -p "$EVIDENCE_DIR" "$PATCH_DIR"
export BASE_SHA
# Optional gateway settings arrive as empty strings when their secrets are unset.
for v in ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS; do [[ -z "${!v:-}" ]] && unset "$v"; done
shopt -u patsub_replacement 2>/dev/null || true

tools="$(tr '\n' ' ' <"$here/allowed-tools.txt") $AGENT_BUILD_TOOLS"
sid=$(uuidgen | tr '[:upper:]' '[:lower:]')
outcome=error
patch_sha=""
round=0
last_fp=""

{
  jq -r '"# \(.title)\n\n\(.body)\n"' "$TASK_FILE"
  tpl=$(<"$here/prompt.md")
  printf '%s\n' "${tpl//@TEST_CMD@/$TEST_CMD}"
} >"$EVIDENCE_DIR/prompt-0.txt"

run_claude() { # run_claude ROUND SESSION_FLAG...
  local n=$1
  shift
  (cd "$WS" && claude -p "$@" \
    --permission-mode dontAsk --permission-prompts none \
    --allowedTools "$tools" \
    --strict-mcp-config --mcp-config "$here/mcp-empty.json" \
    --max-turns "$MAX_TURNS" --max-budget-usd "$MAX_BUDGET_USD" \
    --output-format stream-json --verbose --include-hook-events \
    <"$EVIDENCE_DIR/prompt-$n.txt" >"$EVIDENCE_DIR/round-$n.jsonl" 2>"$EVIDENCE_DIR/round-$n.err")
}

finish() {
  echo "$outcome" >"$EVIDENCE_DIR/outcome.txt"
  {
    echo "outcome=$outcome"
    echo "patch_sha256=$patch_sha"
    echo "rounds=$((round + 1))"
  } >>"${GITHUB_OUTPUT:-/dev/null}"
  echo "factory outcome: $outcome"
  case "$outcome" in clean | no-change | unresolved) exit 0 ;; *) exit 1 ;; esac
}

while :; do
  claude_rc=0
  if [[ "$round" -eq 0 ]]; then
    run_claude 0 --session-id "$sid" || claude_rc=$?
  else
    run_claude "$round" --resume "$sid" || claude_rc=$?
  fi

  result=$(jq -cR 'fromjson? | select(type == "object" and .type == "result")' "$EVIDENCE_DIR/round-$round.jsonl" | tail -n 1)
  result=${result:-"{}"}
  subtype=$(jq -r '.subtype // "none"' <<<"$result")
  turns=$(jq -r '.num_turns // 0' <<<"$result")
  cost=$(jq -r '.total_cost_usd // 0' <<<"$result")
  if [[ "$claude_rc" -ne 0 ]] || [[ "$subtype" != "success" ]] || [[ "$(jq -r '.is_error // false' <<<"$result")" = true ]]; then
    outcome=agent-error
    jq -nc --argjson r "$round" --arg s "$subtype" --argjson t "$turns" --argjson c "$cost" --argjson rc "$claude_rc" \
      '{round:$r, agent:$s, agent_rc:$rc, turns:$t, cost_usd:$c}' >>"$EVIDENCE_DIR/rounds.jsonl"
    finish
  fi

  if [[ -z "$(git -C "$WS" status --porcelain --untracked-files=all)" ]]; then
    outcome=no-change
    jq -nc --argjson r "$round" --argjson t "$turns" --argjson c "$cost" \
      '{round:$r, agent:"success", turns:$t, cost_usd:$c, changed:false}' >>"$EVIDENCE_DIR/rounds.jsonl"
    finish
  fi

  tests_rc=0
  (cd "$WS" && bash -c "$TEST_CMD") >"$EVIDENCE_DIR/tests-r$round.log" 2>&1 || tests_rc=$?

  vrc=0
  (cd "$WS" && "$here/verify.sh" "$EVIDENCE_DIR/verify-r$round.json") >"$EVIDENCE_DIR/findings-r$round.txt" 2>"$EVIDENCE_DIR/verify-r$round.err" || vrc=$?
  nfind=$(grep -c . "$EVIDENCE_DIR/findings-r$round.txt" || true)
  npre=$(grep -c . "$EVIDENCE_DIR/verify-r$round.json.preexisting.txt" 2>/dev/null || true)
  jq -nc --argjson r "$round" --argjson t "$turns" --argjson c "$cost" --argjson tr "$tests_rc" --argjson v "$vrc" --argjson n "$nfind" --argjson p "${npre:-0}" \
    '{round:$r, agent:"success", turns:$t, cost_usd:$c, tests_rc:$tr, verify_rc:$v, findings:$n, preexisting:$p}' >>"$EVIDENCE_DIR/rounds.jsonl"

  case "$vrc" in
    52) outcome=no-ci-baseline; finish ;;
    0 | 51) ;;
    *) outcome=error; finish ;;
  esac

  if [[ "$vrc" -eq 0 ]] && [[ "$tests_rc" -eq 0 ]]; then
    outcome=clean
    break
  fi

  tail_log=""
  [[ "$tests_rc" -eq 0 ]] || tail_log=$(tail -n 60 "$EVIDENCE_DIR/tests-r$round.log")
  fp=$( { cat "$EVIDENCE_DIR/findings-r$round.txt"; printf '%s' "$tail_log" | tr -d '0-9'; } | shasum -a 256 | cut -d' ' -f1)
  if [[ "$round" -ge "$MAX_REPAIR" ]] || [[ "$fp" = "$last_fp" ]]; then
    outcome=unresolved
    finish
  fi
  last_fp=$fp
  round=$((round + 1))

  {
    echo "Checks failed on your change. Fix these, then run the tests again:"
    cat "$EVIDENCE_DIR/findings-r$((round - 1)).txt"
    [[ -z "$tail_log" ]] || printf '\nLast 60 lines of the failing test run:\n%s\n' "$tail_log"
  } >"$EVIDENCE_DIR/prompt-$round.txt"
done

git -C "$WS" add -A
git -C "$WS" diff --cached --binary "$BASE_SHA" >"$PATCH_DIR/factory.patch"
patch_sha=$(shasum -a 256 "$PATCH_DIR/factory.patch" | cut -d' ' -f1)
echo "$patch_sha" >"$PATCH_DIR/factory.patch.sha256"
jq -rs '"| Round | Tests | Vortex | Findings |\n| --- | --- | --- | --- |\n" + (map("| \(.round) | \(if .tests_rc == 0 then "pass" else "fail" end) | \(if .verify_rc == 0 then "clean" else "findings" end) | \(.findings) |") | join("\n"))' \
  "$EVIDENCE_DIR/rounds.jsonl" >"$PATCH_DIR/rounds.md"
finish
