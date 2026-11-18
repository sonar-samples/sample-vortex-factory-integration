#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Shape of `sonar analyze agentic --format json` (sonarqube-cli 1.12.0.17622, sqaa-display-json.ts)
payload='{
  "files": [
    {"path": "src/main/java/app/B.java", "issues": [
      {"id": "2", "rule": "java:S2095", "message": "Use try-with-resources\nor close this \"InputStream\".",
       "textRange": {"startLine": 40, "endLine": 41, "startOffset": 0, "endOffset": 9}}]},
    {"path": "src/main/java/app/A.java", "issues": [
      {"id": "1", "rule": "java:S3776", "message": "Refactor this method.", "filePath": "src/main/java/app/A.java",
       "textRange": {"startLine": 7, "endLine": 7, "startOffset": 0, "endOffset": 3}},
      {"id": "3", "rule": "java:S1134", "message": "No range on this one."}]},
    {"path": "src/main/java/app/C.java", "issues": []}
  ],
  "ignored": [{"path": "logo.png", "reason": "binary"}],
  "failures": [], "skipped": [],
  "summary": {"totalIssues": 3, "totalFailures": 0, "totalSkipped": 0},
  "analysisDepth": "DEEP"
}'

actual=$(printf '%s' "$payload" | jq -r -f "$factory/findings.jq")
expected='src/main/java/app/A.java:0 [java:S1134] No range on this one.
src/main/java/app/A.java:7 [java:S3776] Refactor this method.
src/main/java/app/B.java:40 [java:S2095] Use try-with-resources or close this "InputStream".'
check "sorted lines, newlines collapsed, missing range -> 0" "$expected" "$actual"

check "no issues, no output" "" "$(echo '{"files":[{"path":"a","issues":[]}]}' | jq -r -f "$factory/findings.jq")"
check "no files key, no output" "" "$(echo '{}' | jq -r -f "$factory/findings.jq")"

ranges='[{"path":"src/main/java/app/A.java","start":7,"end":7},{"path":"src/main/java/app/B.java","start":41,"end":50}]'
new=$(printf '%s' "$payload" | jq -r -f "$factory/findings.jq" --argjson ranges "$ranges" --arg scope new)
pre=$(printf '%s' "$payload" | jq -r -f "$factory/findings.jq" --argjson ranges "$ranges" --arg scope preexisting)
check "scope new: A:7 and the B range 40-41 touching changed line 41" 'src/main/java/app/A.java:7 [java:S3776] Refactor this method.
src/main/java/app/B.java:40 [java:S2095] Use try-with-resources or close this "InputStream".' "$new"
check "scope preexisting: the file-level issue in a touched file" "src/main/java/app/A.java:0 [java:S1134] No range on this one." "$pre"
check "no ranges means every issue is new" "3" "$(printf '%s' "$payload" | jq -r -f "$factory/findings.jq" --arg scope new | grep -c .)"
finish
