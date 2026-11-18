#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q -b main repo
cd repo
git config user.email t@example.com
git config user.name t
mkdir -p src .github/workflows gradle
printf 'plugins {\n  id "java"\n  id "jacoco"\n}\n' >build.gradle
echo x >src/A.java
echo x >CLAUDE.md
echo x >.github/workflows/ci.yml
git add -A && git commit -qm base

patch_of() { # patch_of NAME  (working tree changes since base -> $tmp/NAME.patch), then reset
  local name=$1
  git add -A
  git diff --cached --binary >"$tmp/$name.patch"
  git reset -q --hard
  git clean -qfd
}
try() { # try NAME [env...] -> sets code, err
  code=0
  err=$(env "${@:2}" "$factory/publish.sh" check "$tmp/$1.patch" 2>&1) || code=$?
}

echo y >>src/A.java; echo 'class B {}' >src/B.java; patch_of ok
try ok
check "plain source change passes" 0 "$code"

try ok PATCH_SHA256="$(shasum -a 256 "$tmp/ok.patch" | cut -d' ' -f1)"
check "matching SHA-256 passes" 0 "$code"
try ok PATCH_SHA256=0000
check "wrong SHA-256 fails" 1 "$code"
check_contains "hash message" "SHA-256" "$err"

echo y >>.github/workflows/ci.yml; patch_of wf
try wf; check "workflow edit rejected" 1 "$code"; check_contains "names the path" ".github/workflows/ci.yml" "$err"

echo y >>CLAUDE.md; patch_of claude
try claude; check "CLAUDE.md edit rejected" 1 "$code"

mkdir -p src/deep; echo x >src/deep/AGENTS.md; patch_of nested
try nested; check "nested AGENTS.md rejected" 1 "$code"

git rm -q .github/workflows/ci.yml; patch_of del
try del; check "deleting a protected file rejected" 1 "$code"

mkdir -p .Claude; echo '{}' >.Claude/settings.json; patch_of case
try case; check "protected paths match case-insensitively" 1 "$code"

printf '  id "org.sonarqube" version "7.6.0.18749"\n' >>build.gradle; patch_of sonar_add
try sonar_add; check "adding a sonar line to build.gradle rejected" 1 "$code"; check_contains "gate guard" "gate guard" "$err"

sed -i.bak '/jacoco/d' build.gradle && rm build.gradle.bak; patch_of jacoco_rm
try jacoco_rm; check "removing a jacoco line rejected" 1 "$code"

printf 'dependencies {\n  implementation "org.apache.commons:commons-csv:1.10.0"\n}\n' >>build.gradle; patch_of dep
try dep; check "adding a dependency to build.gradle passes" 0 "$code"

echo 'sonar.foo=1' >gradle.properties; patch_of props
try props; check "sonar line in gradle.properties rejected" 1 "$code"

echo 'sonar mention' >src/notes.txt; patch_of unrelated
try unrelated; check "gate guard only applies to build files" 0 "$code"

for i in 1 2 3; do echo "$i" >"src/f$i.java"; done; patch_of many
try many MAX_PATCH_FILES=2; check "file cap" 1 "$code"; check_contains "cap message" "cap 2" "$err"

seq 1 50 >src/big.txt; patch_of big
try big MAX_PATCH_LINES=10; check "line cap" 1 "$code"

ln -s /etc/passwd src/link; patch_of symlink
try symlink; check "symlink rejected" 1 "$code"

echo x >"src/has space.txt"; patch_of space
try space; check "path with whitespace rejected" 1 "$code"

echo x >src/b.bin && printf '\0\1\2' >>src/b.bin; patch_of binary
try binary; check "binary patch passes" 0 "$code"

: >"$tmp/empty.patch"
try empty; check "empty patch rejected" 1 "$code"
finish
