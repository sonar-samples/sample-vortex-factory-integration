#!/usr/bin/env bash
# Vortex DEEP check of the working tree against BASE_SHA.
# usage: verify.sh OUT.json   (run from the workspace)
# Scope: only issues that overlap lines the candidate added or changed vs BASE_SHA fail the check.
#   Issues elsewhere in touched files are pre-existing: recorded, never fed back.
# stdout: one "path:line [rule] message" per new finding
# files:  OUT.json (full result), OUT.json.ranges.json, OUT.json.new.txt, OUT.json.preexisting.txt
# exit:   0 clean | 51 new findings | 52 no CI baseline yet | 1 error (never counts as clean)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=factory.env
source "$here/factory.env"
: "${BASE_SHA:?}"
out=${1:?usage: verify.sh OUT.json}

rc=0
sonar analyze agentic --base "$BASE_SHA" --depth DEEP --format json --force >"$out" 2>"$out.err" || rc=$?

if grep -qi 'INVALID_CONTEXT' "$out" "$out.err"; then
  echo "verify: no CI baseline for this project and branch yet" >&2
  exit 52
fi

if ! jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
  echo "verify: sonar exited $rc without a JSON result" >&2
  exit 1
fi

# Lines added or changed vs BASE_SHA, as path<TAB>start<TAB>end (new-side line numbers).
# Pure deletions add no lines. Untracked files count in full.
changed_ranges() {
  git -c core.quotepath=off diff --unified=0 --no-color --no-ext-diff --no-renames "$BASE_SHA" |
    awk '
      /^\+\+\+ / { path = ($2 == "/dev/null") ? "" : substr($0, 7); sub(/\t.*$/, "", path); next }
      /^@@ / && path != "" {
        plus = $3; sub(/^\+/, "", plus)
        n = split(plus, parts, ",")
        start = parts[1] + 0
        count = (n > 1) ? parts[2] + 0 : 1
        if (count > 0) printf "%s\t%d\t%d\n", path, start, start + count - 1
      }'
  git -c core.quotepath=off ls-files --others --exclude-standard | while IFS= read -r f; do
    printf '%s\t1\t2147483647\n' "$f"
  done
}
changed_ranges | jq -Rn '[inputs | split("\t") | {path: .[0], start: (.[1] | tonumber), end: (.[2] | tonumber)}]' >"$out.ranges.json"

jq -r -f "$here/findings.jq" --argjson ranges "$(cat "$out.ranges.json")" --arg scope new "$out" >"$out.new.txt"
jq -r -f "$here/findings.jq" --argjson ranges "$(cat "$out.ranges.json")" --arg scope preexisting "$out" >"$out.preexisting.txt"
cat "$out.new.txt"

if [[ "$rc" -ne 0 ]] && [[ "$rc" -ne 51 ]]; then
  echo "verify: sonar exited $rc" >&2
  exit 1
fi

if [[ "$rc" -eq 51 ]]; then
  if [[ -s "$out.new.txt" ]]; then
    exit 51
  fi
  if [[ ! -s "$out.preexisting.txt" ]]; then
    echo "verify: sonar exited 51 without any issue in the result" >&2
    exit 1
  fi
fi

changed=$( { git diff --name-only --diff-filter=ACMR "$BASE_SHA"; git ls-files --others --exclude-standard; } | grep -E "$SOURCE_REGEX" || true)

problems=$(jq -r --arg changed "$changed" --argjson rc "$rc" '
  [ (if (.globalError // null) != null then "globalError: \(.globalError.message // .globalError.kind)" else empty end),
    (if ((.failures // []) | length) > 0 then "\(.failures | length) file failure(s)" else empty end),
    (if ((.skipped // []) | length) > 0 then "\(.skipped | length) skipped file(s)" else empty end),
    (if $rc == 0 and (.summary.totalIssues // 0) > 0 then "issues reported with exit 0" else empty end),
    ( [ .files[]?.path ] as $seen
      | $changed | split("\n") | map(select(. != "")) | .[]
      | . as $f | select(any($seen[]; . == $f or endswith("/" + $f)) | not)
      | "changed file not analyzed: \($f)" ) ] | .[]' "$out")

if [[ -n "$problems" ]]; then
  echo "verify: not clean" >&2
  echo "$problems" >&2
  exit 1
fi
