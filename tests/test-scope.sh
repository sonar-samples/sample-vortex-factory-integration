#!/usr/bin/env bash
# verify.sh scope: only issues overlapping lines the candidate added or changed vs BASE_SHA fail.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/repo"

cat >"$tmp/bin/sonar" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_OUT"
exit "${STUB_RC:-51}"
STUB
chmod +x "$tmp/bin/sonar"

cd "$tmp/repo"
git init -q -b main
git config user.email t@example.com
git config user.name t
mkdir -p src
printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n' >src/A.java
printf 'a\nb\nc\nd\n' >src/Keep.java
git add -A && git commit -qm base
BASE_SHA=$(git rev-parse HEAD)
export BASE_SHA

# A.java: line 3 changed, line 7 deleted, a line inserted after L9. New-side changed lines: 3 and 9.
printf 'L1\nL2\nX3\nL4\nL5\nL6\nL8\nL9\nN\nL10\n' >src/A.java
# Keep.java: first line deleted only. No added lines.
printf 'b\nc\nd\n' >src/Keep.java
# New.java is untracked: every line is new.
printf 'class New {\n}\n' >src/New.java

issue() { # issue PATH RULE START [END]
  local path=$1 rule=$2 start=$3 end=${4:-$3}
  if [[ "$start" = none ]]; then
    printf '{"rule":"%s","message":"m","filePath":"%s"}' "$rule" "$path"
  else
    printf '{"rule":"%s","message":"m","filePath":"%s","textRange":{"startLine":%s,"endLine":%s}}' "$rule" "$path" "$start" "$end"
  fi
}

# run ISSUES_BY_FILE_JSON  -> sets code, out, pre
run() {
  printf '{"files":%s,"failures":[],"skipped":[],"summary":{"totalIssues":1}}' "$1" >"$tmp/payload.json"
  code=0
  out=$(STUB_OUT=$tmp/payload.json PATH="$tmp/bin:$PATH" "$factory/verify.sh" "$tmp/out.json" 2>"$tmp/stderr") || code=$?
  err=$(cat "$tmp/stderr")
  pre=$(cat "$tmp/out.json.preexisting.txt")
}
files() { # files A_ISSUES KEEP_ISSUES NEW_ISSUES  (comma-joined issue objects, may be empty)
  printf '[{"path":"src/A.java","issues":[%s]},{"path":"src/Keep.java","issues":[%s]},{"path":"src/New.java","issues":[%s]}]' "$1" "$2" "$3"
}

run "$(files "$(issue src/A.java java:S1 3)" "" "")"
check "issue on a changed line -> 51" 51 "$code"
check "reported as new" "src/A.java:3 [java:S1] m" "$out"

run "$(files "$(issue src/A.java java:S1 9)" "" "")"
check "issue on an inserted line -> 51" 51 "$code"

run "$(files "$(issue src/A.java java:S1 2),$(issue src/A.java java:S2 4),$(issue src/A.java java:S3 10)" "" "")"
check "issues on unchanged lines around the changes -> clean" 0 "$code"
check "nothing fed back" "" "$out"
check "recorded as pre-existing" "src/A.java:10 [java:S3] m
src/A.java:2 [java:S1] m
src/A.java:4 [java:S2] m" "$pre"

run "$(files "$(issue src/A.java java:S1 1 3)" "" "")"
check "range ending on a changed line counts as new" 51 "$code"

run "$(files "$(issue src/A.java java:S1 2 5)" "" "")"
check "range spanning changed and unchanged lines counts as new" 51 "$code"
check "the spanning issue is not pre-existing" "" "$pre"

run "$(files "$(issue src/A.java java:S1 4 8)" "" "")"
check "range from unchanged to unchanged across the deletion -> pre-existing" 0 "$code"

run "$(files "$(issue src/A.java java:S1 6 7)" "" "")"
check "lines next to a deleted line are not changed -> pre-existing" 0 "$code"

run "$(files "$(issue src/A.java java:S1 none)" "" "")"
check "file-level issue in a touched file -> pre-existing" 0 "$code"

run "$(files "" "$(issue src/Keep.java java:S1 1)$(printf ',')$(issue src/Keep.java java:S2 3)" "")"
check "pure deletions add no lines, so nothing in Keep.java is new" 0 "$code"

run "$(files "" "" "$(issue src/New.java java:S1 2)")"
check "any line of a new file is new" 51 "$code"
run "$(files "" "" "$(issue src/New.java java:S1 none)")"
check "file-level issue in a new file is new" 51 "$code"
check_contains "listed with its path" "src/New.java:0 [java:S1] m" "$out"

run "$(files "$(issue src/A.java java:S1 2)" "" "$(issue src/New.java java:S2 1)")"
check "mixed: only the new-file issue is fed back" "src/New.java:1 [java:S2] m" "$out"
check "mixed: the old-line issue is recorded" "src/A.java:2 [java:S1] m" "$pre"

run '[{"path":"/home/runner/work/r/r/ws/src/A.java","issues":[{"rule":"java:S1","message":"m","textRange":{"startLine":3}}]},{"path":"/home/runner/work/r/r/ws/src/Keep.java","issues":[]},{"path":"/home/runner/work/r/r/ws/src/New.java","issues":[]}]'
check "absolute paths still map to changed ranges" 51 "$code"

run '[{"path":"src/A.java","issues":[]},{"path":"src/Keep.java","issues":[]},{"path":"src/New.java","issues":[]}]'
check "exit 51 with no issue anywhere -> error" 1 "$code"
check_contains "says why" "without any issue" "$err"

# Same result after the agent commits and stages its work.
git add -A && git commit -qm candidate
run "$(files "$(issue src/A.java java:S1 3)" "" "")"
check "committed changes count against BASE_SHA" 51 "$code"
run "$(files "$(issue src/A.java java:S1 2)" "" "")"
check "committed: unchanged line still pre-existing" 0 "$code"
finish
