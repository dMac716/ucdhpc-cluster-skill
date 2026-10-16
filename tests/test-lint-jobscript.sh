#!/usr/bin/env bash
# Regression tests for scripts/lint-jobscript.sh: usage exit code, --time/--mem option-prefix
# matching and value parsing, apptainer --nv and rsync --delete detection, and sbatch --test-only
# timeout (rc 124, a warning).
# Cluster-free: stub sbatch/timeout go in a mktemp dir at the front of PATH. Run: bash tests/test-lint-jobscript.sh
# Override the tree under test with SCRIPTS_DIR=/path/to/scripts. TAP-like output; exit 1 if any test fails.
# Note: a pass-through 'timeout' stub (drops the duration, runs the command) is added only when the host has no
# 'timeout' (stock macOS); test (f) always shadows 'timeout' with a stub that exits 124.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=${SCRIPTS_DIR:-$HERE/../ucd-hpc/scripts}
LINT="$SCRIPTS_DIR/lint-jobscript.sh"
[ -r "$LINT" ] || { echo "Bail out! cannot read $LINT"; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lintjob.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

MSG=""; OUT=""; RC=0; STUBS=""

# fresh stub dir per test (optionally with a pass-through timeout when the host lacks one)
new_stubs() {
  STUBS=$(mktemp -d "$TMP/stubs.XXXXXX")
  if [ $HAVE_TIMEOUT = 0 ]; then
    printf '#!/bin/sh\nshift\nexec "$@"\n' >"$STUBS/timeout"; chmod +x "$STUBS/timeout"
  fi
}
# stub NAME EXITCODE [OUTPUT...]: executable that prints OUTPUT and exits EXITCODE
stub() {
  local n=$1 c=$2; shift 2
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "$*" "$c" >"$STUBS/$n"; chmod +x "$STUBS/$n"
}
# job NAME LINE...: write a job script (shebang + given lines, one per line, printf-escapes honoured)
job() {
  local f="$TMP/$1.sh"; shift
  { echo '#!/bin/bash'; for l in "$@"; do printf '%b\n' "$l"; done; } >"$f"
  JOBFILE=$f
}
BASE1='#SBATCH --account=testacct'; BASE2='#SBATCH --partition=low'
# UCD_HPC_HPCCF_ROOT points at nothing so a run on a real cluster node does not pick up its cluster name
run_lint() { OUT=$(UCD_HPC_HPCCF_ROOT="$TMP/no-hpccf" PATH="$STUBS:$PATH" bash "$LINT" "$@" 2>&1); RC=$?; }

has_text()  { case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
want()      { has_text "$1" || MSG="$MSG
    expected output to contain: $1"; }
refuse()    { has_text "$1" && MSG="$MSG
    expected output NOT to contain: $1"; }
want_rc()   { [ "$RC" -eq "$1" ] || MSG="$MSG
    expected exit $1, got $RC"; }

# (a) ---------------------------------------------------------------------------------
t_no_args_exits_2_with_usage() {
  run_lint
  want_rc 2; want "usage: lint-jobscript.sh SCRIPT"
}
# (b) ---------------------------------------------------------------------------------
t_time_min_and_mem_bind_do_not_satisfy_time_and_mem() {
  job b "$BASE1" "$BASE2" '#SBATCH --time-min=5' '#SBATCH --mem-bind=local' 'echo hi'
  run_lint "$JOBFILE" --no-test
  want "ERROR: no --time"; want "no memory request"; want_rc 1
}
# (c) ---------------------------------------------------------------------------------
t_time_and_mem_spellings_still_accepted() {
  local v
  for v in '--time 10|--mem=1G' '--time\t10|--mem\t1G' '--time=10|--mem 1G'; do
    job c "$BASE1" "$BASE2" "#SBATCH ${v%%|*}" "#SBATCH ${v#*|}" 'echo hi'
    run_lint "$JOBFILE" --no-test
    refuse "no --time"; refuse "no memory request"
    [ -z "$MSG" ] || { MSG="$MSG
    (variant: $v)"; return; }
  done
}
# (d) ---------------------------------------------------------------------------------
t_apptainer_nv_after_bind_is_not_warned() {
  job d1 "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' '#SBATCH --gres=gpu:1' \
    'apptainer exec --bind /data:/data --nv img.sif python x.py'
  run_lint "$JOBFILE" --no-test
  refuse "without --nv"
}
t_apptainer_without_nv_on_gpu_job_still_warned() {
  job d2 "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' '#SBATCH --gres=gpu:1' \
    'apptainer exec img.sif python x.py'
  run_lint "$JOBFILE" --no-test
  want "GPU job runs apptainer without --nv"
}
# (e) ---------------------------------------------------------------------------------
t_rsync_delete_after_info_flag_is_warned() {
  job e1 "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' \
    'rsync -a --info=progress2 src/ dst/ --delete'
  run_lint "$JOBFILE" --no-test
  want "rsync --delete permanently removes"
}
t_rsync_without_delete_is_not_warned() {
  job e2 "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' \
    'rsync -a --info=progress2 src/ dst/'
  run_lint "$JOBFILE" --no-test
  refuse "rsync --delete"
}
# (f) ---------------------------------------------------------------------------------
t_sbatch_timeout_reported_as_timeout_not_rejection() {
  stub sbatch 0 "Job 1 to start at 2026-01-01T00:00:00 using 1 processors"   # never reached
  printf '#!/bin/sh\nexit 124\n' >"$STUBS/timeout"; chmod +x "$STUBS/timeout" # simulates 30 s expiry
  job f "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' 'echo hi'
  run_lint "$JOBFILE"
  want "timed out"; refuse "the scheduler rejects this request"; refuse "ERROR:"; want_rc 0
}
# (h) values written with a tab or a space are read, not only detected ---------------------
t_tab_or_space_separated_values_are_read() {
  local v
  for v in '--mem\t200' '--mem 200' '--mem=200'; do
    job h "$BASE1" "$BASE2" '#SBATCH --time=10' "#SBATCH $v" 'echo hi'
    run_lint "$JOBFILE" --no-test
    want "--mem=200 has no unit"
    [ -z "$MSG" ] || { MSG="$MSG
    (variant: $v)"; return; }
  done
}
t_short_option_values_are_read() {
  job h2 '#SBATCH -A testacct' '#SBATCH -p low' '#SBATCH -t 10' '#SBATCH -c8' '#SBATCH --mem=1G' \
    '#SBATCH -o out.log' 'echo hi'
  run_lint "$JOBFILE" --no-test
  refuse "no --account"; refuse "no --partition"; refuse "no --time"; want "--output=out.log has no %j"
}
t_exclusive_with_trailing_space_is_seen() {
  job h3 "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' '#SBATCH --exclusive   ' 'echo hi'
  run_lint "$JOBFILE" --no-test
  want "--exclusive reserves whole nodes"
}
# (g) control -------------------------------------------------------------------------
t_clean_script_with_accepting_sbatch_has_no_errors() {
  stub sbatch 0 "sbatch: Job 123 to start at 2026-10-13T15:00:00 using 1 processors on nodes n1 in partition low"
  job g "$BASE1" "$BASE2" '#SBATCH --time=10' '#SBATCH --mem=1G' 'echo hi'
  run_lint "$JOBFILE"
  want "lint: 0 error(s), 0 warning(s)"; want "accepted; nothing was submitted"
  refuse "ERROR:"; want_rc 0
}

N=0; FAILED=0
run_test() {
  N=$((N+1)); MSG=""; new_stubs
  "$1"
  if [ -z "$MSG" ]; then echo "ok $N - $1"
  else
    FAILED=$((FAILED+1)); echo "not ok $N - $1"
    echo "$MSG"; echo "    exit: $RC; output was:"; printf '%s\n' "$OUT" | sed 's/^/    | /'
  fi
}
for t in t_no_args_exits_2_with_usage \
         t_time_min_and_mem_bind_do_not_satisfy_time_and_mem \
         t_time_and_mem_spellings_still_accepted \
         t_apptainer_nv_after_bind_is_not_warned \
         t_apptainer_without_nv_on_gpu_job_still_warned \
         t_rsync_delete_after_info_flag_is_warned \
         t_rsync_without_delete_is_not_warned \
         t_sbatch_timeout_reported_as_timeout_not_rejection \
         t_tab_or_space_separated_values_are_read \
         t_short_option_values_are_read \
         t_exclusive_with_trailing_space_is_seen \
         t_clean_script_with_accepting_sbatch_has_no_errors; do
  run_test "$t"
done
echo "1..$N"
[ $FAILED -eq 0 ] || { echo "# $FAILED of $N failed (SCRIPTS_DIR=$SCRIPTS_DIR)"; exit 1; }
exit 0
