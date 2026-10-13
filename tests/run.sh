#!/usr/bin/env bash
# Runs every tests/test-*.sh next to this file, in name order, each in its own bash process.
# Honours SCRIPTS_DIR from the environment (exported to the test files); works from any cwd.
# Prints one summary line; exits 1 if any test file failed (or none were found), else 0.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -n "${SCRIPTS_DIR:-}" ] && export SCRIPTS_DIR
total=0; failed=0; failed_names=""
for t in "$HERE"/test-*.sh; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  echo "# == $(basename "$t")"
  if ! bash "$t"; then
    failed=$((failed + 1)); failed_names="$failed_names $(basename "$t")"
  fi
done
if [ "$total" -eq 0 ]; then echo "run.sh: no test files found in $HERE"; exit 1; fi
echo "run.sh: $total file(s), $failed failed${failed_names:+ ($failed_names )} [SCRIPTS_DIR=${SCRIPTS_DIR:-default}]"
[ "$failed" -eq 0 ]
