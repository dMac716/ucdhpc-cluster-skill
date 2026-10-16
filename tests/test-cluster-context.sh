#!/usr/bin/env bash
# Regression tests for scripts/cluster-context.sh: a failed scontrol/squeue query must say "query failed"
# (not "none"), reservations print "name start end" once, and array job ids are not truncated in "my jobs".
# Cluster-free: stub sinfo/scontrol/squeue/sacctmgr/df/... in a mktemp dir at the front of PATH. Plain bash, TAP-like.
# Usage: bash test-cluster-context.sh   (SCRIPTS_DIR=/other/tree/scripts to test another tree; default ../ucd-hpc/scripts)
#
# Stubs (all under $TMP, removed on exit). Behaviour is chosen per test with env vars STUB_RESV and STUB_SQUEUE.
# `timeout` is stubbed too (macOS has none by default): it drops its first argument (the seconds) and execs the
# command, so the wrapped command's exit status passes through exactly as with the real timeout.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=${SCRIPTS_DIR:-$HERE/../ucd-hpc/scripts}
SCRIPT=$SCRIPTS_DIR/cluster-context.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
STUBS=$TMP/stubs; mkdir -p "$STUBS" "$TMP/home"

mkstub() { cat > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

mkstub timeout <<'S'
#!/bin/sh
shift
exec "$@"
S
mkstub sinfo <<'S'
#!/bin/sh
case "$*" in
  *--version*) echo "slurm 24.05.0" ;;
  "-h -o %R") echo low ;;
  *"-s -p low -o %F"*) echo "1/2/0/3" ;;
  *"-o %G|%D"*) echo "(null)|3" ;;
  *"-p low -o %G"*) echo "(null)" ;;
esac
exit 0
S
mkstub sacctmgr <<'S'
#!/bin/sh
exit 0
S
mkstub df <<'S'
#!/bin/sh
echo "Filesystem Size Used Avail Use% Mounted"
echo "stub 20G 1G 19G 5% /stub"
S
mkstub module <<'S'
#!/bin/sh
exit 0
S
mkstub systemctl <<'S'
#!/bin/sh
exit 0
S
mkstub scontrol <<'S'
#!/bin/sh
case "$*" in
  "show config") echo "ClusterName              = testcluster" ;;
  "show partition low") echo "PartitionName=low MaxTime=1-00:00:00 DefMemPerCPU=1000 PreemptMode=OFF" ;;
  "show reservation")
    case "${STUB_RESV:-none}" in
      fail) echo "slurm_load_reservations error" >&2; exit 1 ;;
      none) echo "No reservations in the system" ;;
      silent) exit 0 ;;
      real) # Slurm's multi-line format: name/start/end all on the first line
        echo "ReservationName=maint StartTime=2026-10-20T08:00:00 EndTime=2026-10-21T08:00:00 Duration=1-00:00:00"
        echo "   Nodes=cn[1-4] NodeCnt=4 CoreCnt=128 Features=(null) PartitionName=(null) Flags=MAINT,IGNORE_JOBS,SPEC_NODES"
        echo "   TRES=cpu=128"
        echo "   Users=root Groups=(null) Accounts=(null) Licenses=(null) State=INACTIVE BurstBuffer=(null) Watts=n/a"
        echo "   MaxStartDelay=(null)" ;;
    esac ;;
esac
exit 0
S
# squeue stub honours the width of the %.<W>i job-id column like real squeue (ids longer than W are cut to W).
mkstub squeue <<'S'
#!/bin/sh
fmt=; while [ $# -gt 0 ]; do [ "$1" = -o ] && { fmt=$2; shift; }; shift; done
w=$(printf %s "$fmt" | sed -n 's/.*%\.\([0-9][0-9]*\)i.*/\1/p'); w=${w:-10}
case "${STUB_SQUEUE:-header}" in
  fail) echo "squeue: error: slurm_load_jobs" >&2; exit 1 ;;
esac
printf "%${w}.${w}s %s\n" JOBID "PARTITION NAME ST TIME TIME_LIMIT CPUS MIN_MEM NODELIST(REASON)"
case "${STUB_SQUEUE:-header}" in
  jobs)  printf "%${w}.${w}s %s\n" 123456 "low myjob R 0:10 1:00:00 4 8G node1" ;;
  array) printf "%${w}.${w}s %s\n" "24034091_[198-500%20]" "low myjob PD 0:00 1:00:00 4 8G (Priority)" ;;
esac
exit 0
S

# run_ctx VAR=val...  -> runs the real script (--brief) with stubs first on PATH; stdout in $TMP/out
run_ctx() {
  env USER=tester UCD_HPC_HPCCF_ROOT="$TMP/no-hpccf" "$@" PATH="$STUBS:$PATH" HOME="$TMP/home" bash "$SCRIPT" --brief >"$TMP/out" 2>"$TMP/err"
}
# section "header prefix" -> body lines of that "== ... ==" section, blank lines removed
section() { awk -v h="== $1" 'index($0,h)==1{on=1;next} /^== /{on=0} on' "$TMP/out" | sed '/^$/d'; }
fail() { printf '# %s\n' "$@"; return 1; }
show() { printf '# got: |%s|\n' "$1"; }

RESV="maintenance reservations"; JOBS="my jobs"

test_reservation_query_failure_is_not_none() {
  run_ctx STUB_RESV=fail || { fail "script exited non-zero"; return 1; }
  s=$(section "$RESV")
  case "$s" in *"query failed"*) ;; *) show "$s"; fail "expected 'query failed'"; return 1;; esac
  [ "$s" != none ] || { show "$s"; fail "reported 'none' for a failed query"; return 1; }
}
test_squeue_failure_is_not_none_queued() {
  run_ctx STUB_SQUEUE=fail || { fail "script exited non-zero"; return 1; }
  s=$(section "$JOBS")
  case "$s" in *"query failed"*) ;; *) show "$s"; fail "expected 'query failed'"; return 1;; esac
  case "$s" in *"none queued"*) show "$s"; fail "reported 'none queued or running' for a failed query"; return 1;; esac
}
test_reservation_multiline_prints_name_start_end_once() {
  run_ctx STUB_RESV=real || { fail "script exited non-zero"; return 1; }
  s=$(section "$RESV")
  want="maint StartTime=2026-10-20T08:00:00 EndTime=2026-10-21T08:00:00"
  [ "$s" = "$want" ] || { show "$s"; fail "want |$want|"; return 1; }
}
test_no_reservations_message_prints_none() {
  run_ctx STUB_RESV=none || { fail "script exited non-zero"; return 1; }
  s=$(section "$RESV")
  [ "$s" = none ] || { show "$s"; fail "want |none| for 'No reservations in the system'"; return 1; }
}
test_empty_reservation_output_prints_none() {
  run_ctx STUB_RESV=silent || { fail "script exited non-zero"; return 1; }
  s=$(section "$RESV")
  [ "$s" = none ] || { show "$s"; fail "want |none| for empty scontrol output"; return 1; }
}
test_squeue_header_only_prints_none_queued() {
  run_ctx STUB_SQUEUE=header || { fail "script exited non-zero"; return 1; }
  s=$(section "$JOBS")
  [ "$s" = "none queued or running" ] || { show "$s"; fail "want |none queued or running|"; return 1; }
}
test_array_job_id_not_truncated() {
  run_ctx STUB_SQUEUE=array || { fail "script exited non-zero"; return 1; }
  s=$(section "$JOBS")
  printf '%s\n' "$s" | grep -qF '24034091_[198-500%20]' || { show "$s"; fail "array id cut off in 'my jobs' table"; return 1; }
}
test_control_healthy_output_unchanged() {
  run_ctx STUB_RESV=silent STUB_SQUEUE=jobs || { fail "script exited non-zero"; return 1; }
  grep -q '^cluster=testcluster ' "$TMP/out" || { fail "missing cluster= line"; return 1; }
  [ "$(section "$RESV")" = none ] || { fail "reservations section not 'none'"; return 1; }
  p=$(grep '^low ' "$TMP/out" | tr -s ' ')
  [ "$p" = "low 1-00:00:00 1000M OFF 1/2/0/3 -" ] || { show "$p"; fail "partition row changed"; return 1; }
  # id column width is the one intended difference, so compare the jobs table with whitespace collapsed
  j=$(section "$JOBS" | sed 's/^ *//' | tr -s ' ')
  want=$(printf '%s\n%s' "JOBID PARTITION NAME ST TIME TIME_LIMIT CPUS MIN_MEM NODELIST(REASON)" \
                         "123456 low myjob R 0:10 1:00:00 4 8G node1")
  [ "$j" = "$want" ] || { show "$j"; fail "jobs table changed"; return 1; }
}

N=0; BAD=0
t() { # t NAME  -> run test_NAME, print TAP line (+ diagnostics on failure)
  N=$((N+1))
  out=$("test_$1" 2>&1); if [ $? -eq 0 ]; then echo "ok $N - $1"
  else BAD=$((BAD+1)); echo "not ok $N - $1"; [ -n "$out" ] && printf '%s\n' "$out"; fi
}
[ -r "$SCRIPT" ] || { echo "Bail out! cannot read $SCRIPT"; exit 2; }
echo "# SCRIPTS_DIR=$SCRIPTS_DIR"
t reservation_query_failure_is_not_none
t squeue_failure_is_not_none_queued
t reservation_multiline_prints_name_start_end_once
t no_reservations_message_prints_none
t empty_reservation_output_prints_none
t squeue_header_only_prints_none_queued
t array_job_id_not_truncated
t control_healthy_output_unchanged
echo "1..$N"
[ "$BAD" -eq 0 ]
