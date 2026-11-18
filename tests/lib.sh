# shellcheck shell=bash
# shellcheck disable=SC2034
# Tiny assertion helpers. Source from a test script.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
factory="$root/.github/factory"
fails=0
passes=0

check() { # check NAME EXPECTED ACTUAL
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" = "$actual" ]]; then
    passes=$((passes + 1))
  else
    fails=$((fails + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

check_contains() { # check_contains NAME NEEDLE HAYSTACK
  local name=$1 needle=$2 haystack=$3
  case $haystack in
    *"$needle"*) passes=$((passes + 1)) ;;
    *) fails=$((fails + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$name" "$needle" "$haystack" ;;
  esac
}

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$passes" "$fails"
  [[ "$fails" -eq 0 ]]
}
