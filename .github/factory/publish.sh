#!/usr/bin/env bash
# Publisher: check the worker's patch, apply it on BASE_SHA, push a branch, open a PR.
# usage: publish.sh check PATCH     checks only (hash if PATCH_SHA256 is set, paths, gate guard, size)
#        publish.sh run             full flow, from a checkout of BASE_SHA
# env (run): PATCH PATCH_SHA256 BASE_SHA ISSUE_NUMBER ISSUE_TITLE BASE_BRANCH RUN_URL
#            GH_TOKEN (App token) GITHUB_REPOSITORY APP_SLUG ROUNDS_FILE
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=factory.env
source "$here/factory.env"

records=$(mktemp)
trap 'rm -f "$records"' EXIT

die() { echo "publish: $*" >&2; exit 1; }
sha256() {
  local file=$1
  shasum -a 256 "$file" | cut -d' ' -f1
}

check() {
  local patch=$1
  [[ -s "$patch" ]] || die "empty patch"
  if [[ -n "${PATCH_SHA256:-}" ]] && [[ "$(sha256 "$patch")" != "$PATCH_SHA256" ]]; then
    die "patch SHA-256 does not match the worker's output"
  fi
  if grep -Eq '^(new file mode|old mode|new mode|deleted file mode) (120000|160000)' "$patch"; then
    die "patch touches a symlink or submodule"
  fi

  # F<TAB>old<TAB>new per file; L<TAB>file<TAB>+/-line per changed line
  awk '
    /^diff --git / {
      inhunk = 0
      line = substr($0, 12)
      if (split(line, p, " b/") != 2 || substr(p[1], 1, 2) != "a/") { print "BAD\t" line; next }
      cur = p[2]; files++
      print "F\t" substr(p[1], 3) "\t" cur; next
    }
    /^@@ / { inhunk = 1; next }
    inhunk && /^[+-]/ { print "L\t" cur "\t" $0; lines++ }
    END { print "N\t" files + 0 "\t" lines + 0 }
  ' "$patch" >"$records"

  local kind a b
  while IFS=$'\t' read -r kind a b; do
    case $kind in
      BAD) die "unparseable or quoted path in patch header: $a" ;;
      F)
        for path in "$a" "$b"; do
          [[ $path =~ ^[A-Za-z0-9._@+/-]+$ && $path != /* && $path != *..* ]] || { die "unsupported path: $path"; }
        done ;;
      N)
        [[ "$a" -le "$MAX_PATCH_FILES" ]] || { die "patch touches $a files (cap $MAX_PATCH_FILES)"; }
        [[ "$b" -le "$MAX_PATCH_LINES" ]] || { die "patch changes $b lines (cap $MAX_PATCH_LINES)"; } ;;
      *) ;;
    esac
  done <"$records"

  local pat glob re
  shopt -s nocasematch
  while IFS=$'\t' read -r kind a b; do
    [[ "$kind" = F ]] || continue
    while IFS= read -r pat; do
      case $pat in '' | '#'*) continue ;; *) ;; esac
      # shellcheck disable=SC2053
      if [[ $a == $pat || $b == $pat ]]; then die "protected path: $b (matches $pat)"; fi
    done <"$here/protected-paths.txt"
  done <"$records"
  shopt -u nocasematch

  while IFS= read -r pat; do
    case $pat in '' | '#'*) continue ;; *) ;; esac
    glob=${pat%%:*}
    re=${pat#*:}
    while IFS=$'\t' read -r kind a b; do
      [[ "$kind" = L ]] || continue
      # shellcheck disable=SC2053
      [[ $a == $glob ]] || continue
      if printf '%s\n' "${b:1}" | grep -Eiq -- "$re"; then
        die "gate guard: $a changes a line matching /$re/"
      fi
    done <"$records"
  done <"$here/gate-guard.txt"
}

run() {
  : "${PATCH:?}" "${BASE_SHA:?}" "${ISSUE_NUMBER:?}" "${BASE_BRANCH:?}" "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${APP_SLUG:?}"
  check "$PATCH"
  [[ "$(git rev-parse HEAD)" = "$BASE_SHA" ]] || die "checkout is not at BASE_SHA"

  local title branch bot_id msg
  title=$(printf '%s' "${ISSUE_TITLE:-}" | tr -d '\r\n')
  branch="factory/issue-$ISSUE_NUMBER-${GITHUB_RUN_ID:-local}"
  bot_id=$(gh api "/users/${APP_SLUG}%5Bbot%5D" --jq .id)

  git apply --index --whitespace=nowarn "$PATCH"
  git switch -c "$branch"
  msg=$(mktemp)
  {
    printf 'Resolve #%s: %s\n\n' "$ISSUE_NUMBER" "$title"
    printf 'Factory-Issue: #%s\n' "$ISSUE_NUMBER"
    printf 'Factory-Run: %s\n' "${RUN_URL:-}"
    printf 'Factory-Base: %s\n' "$BASE_SHA"
    printf 'Factory-Patch-SHA256: %s\n' "$(sha256 "$PATCH")"
  } >"$msg"
  git -c "user.name=${APP_SLUG}[bot]" -c "user.email=${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com" commit -q -F "$msg"
  git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/$branch"

  local body
  body=$(mktemp)
  {
    printf 'Implements #%s.\n\nFactory run: %s\n\n' "$ISSUE_NUMBER" "${RUN_URL:-}"
    [[ -z "${ROUNDS_FILE:-}" ]] || cat "$ROUNDS_FILE"
  } >"$body"
  pr_url=$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$BASE_BRANCH" --head "$branch" \
    --title "Resolve #$ISSUE_NUMBER: $title" --body-file "$body")
  echo "$pr_url"
  echo "pr_url=$pr_url" >>"${GITHUB_OUTPUT:-/dev/null}"
}

case "${1:-}" in
  check) check "${2:?usage: publish.sh check PATCH}" ;;
  run) run ;;
  *) die "usage: publish.sh check PATCH | run" ;;
esac
