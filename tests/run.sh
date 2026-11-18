#!/usr/bin/env bash
# Run all local tests: bash tests/run.sh
set -uo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$dir"/test-*.sh; do
  bash "$t" || rc=1
done
exit $rc
