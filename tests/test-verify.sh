#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/repo"

# Stub sonar: prints $STUB_OUT (a file) and exits $STUB_RC.
cat >"$tmp/bin/sonar" <<'STUB'
#!/usr/bin/env bash
[[ -z "${STUB_OUT:-}" ]] || cat "$STUB_OUT"
[[ -z "${STUB_ERR:-}" ]] || echo "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/bin/sonar"

cd "$tmp/repo"
git init -q -b main
git config user.email t@example.com
git config user.name t
echo base >README.md
git add -A && git commit -qm base
BASE_SHA=$(git rev-parse HEAD)
export BASE_SHA
mkdir -p src
echo 'class New {}' >src/New.java
echo 'notes' >>README.md

run() { # run RC PAYLOAD_JSON [STDERR]  -> sets code, out
  printf '%s' "$2" >"$tmp/payload.json"
  code=0
  out=$(STUB_RC=$1 STUB_OUT=$tmp/payload.json STUB_ERR="${3:-}" PATH="$tmp/bin:$PATH" "$factory/verify.sh" "$tmp/out.json" 2>"$tmp/stderr") || code=$?
  err=$(cat "$tmp/stderr")
}

analyzed='{"files":[{"path":"src/New.java","issues":[]}],"ignored":[],"failures":[],"skipped":[],"summary":{"totalIssues":0,"totalFailures":0,"totalSkipped":0}}'
found='{"files":[{"path":"src/New.java","issues":[{"id":"1","rule":"java:S2095","message":"Close this stream.","textRange":{"startLine":3}}]}],"failures":[],"skipped":[],"summary":{"totalIssues":1}}'

run 0 "$analyzed"
check "0 + analyzed + no problems -> clean" 0 "$code"

run 0 '{"files":[{"path":"/home/runner/work/r/r/ws/src/New.java","issues":[]}],"failures":[],"skipped":[]}'
check "absolute paths still match" 0 "$code"

run 51 "$found"
check "51 -> findings" 51 "$code"
check "findings line on stdout" "src/New.java:3 [java:S2095] Close this stream." "$out"

run 0 '{"files":[{"path":"src/New.java","issues":[]}],"failures":[],"skipped":["src/Other.java"]}'
check "skipped file -> error" 1 "$code"
check_contains "skipped reported" "skipped" "$err"

run 0 '{"files":[{"path":"src/New.java","issues":[]}],"failures":[{"path":"src/New.java","message":"boom"}],"skipped":[]}'
check "failure -> error" 1 "$code"

run 0 '{"files":[{"path":"src/New.java","issues":[]}],"failures":[],"skipped":[],"globalError":{"kind":"NETWORK","message":"timeout"}}'
check "globalError -> error" 1 "$code"

run 0 '{"files":[],"failures":[],"skipped":[]}'
check "changed source file missing from files[] -> error" 1 "$code"
check_contains "names the file" "src/New.java" "$err"

run 0 '{"files":[{"path":"src/New.java","issues":[{"id":"1","rule":"x:S1","message":"m"}]}],"summary":{"totalIssues":1}}'
check "issues reported with exit 0 -> error" 1 "$code"

run 1 "$analyzed"
check "exit 1 with JSON -> error" 1 "$code"

run 0 ""
check "no JSON at all -> error" 1 "$code"

run 2 "" "invalid options"
check "exit 2 -> error" 1 "$code"

run 1 '{"globalError":{"kind":"INVALID_CONTEXT","message":"missing information for branch"}}'
check "INVALID_CONTEXT in JSON -> no CI baseline" 52 "$code"

run 1 "" "Error: INVALID_CONTEXT: missing information"
check "INVALID_CONTEXT on stderr -> no CI baseline" 52 "$code"
finish
