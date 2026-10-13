#!/usr/bin/env bash
# Cluster-free regression tests for ucd-hpc/scripts/job-postmortem.sh (stub sacct/scontrol in a temp PATH dir).
# Covers: octal-looking TotalCPU/Elapsed values, bare array ids (multi-record scontrol), log fallback globbing,
# and custom --output patterns recovered from sacct. Run: bash test-job-postmortem.sh  (TAP-like, exit 1 on failure).
# SCRIPTS_DIR=/path/to/scripts selects the tree under test (default ../ucd-hpc/scripts). Needs bash 3.2+, column, fold.
#
# Stubs: sacct and scontrol return canned files from a per-test temp dir. 'timeout' is stubbed too (it drops the
# duration and runs the command) so macOS without coreutils works; no test depends on a timeout actually firing.
# squeue/sinfo/sacctmgr/getent are never called by this script, so they are not stubbed.

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=${SCRIPTS_DIR:-$HERE/../ucd-hpc/scripts}
SCRIPT=$SCRIPTS_DIR/job-postmortem.sh
[ -r "$SCRIPT" ] || { echo "Bail out! cannot read $SCRIPT"; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pm-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

N=0; FAILED=0; T_FAILS=""

# ---- helpers --------------------------------------------------------------------------
note() { T_FAILS="$T_FAILS
    # $*"; }

# new_env: fresh per-test dir $D with stub bin dir $STUB, workdir $WD; OUT/ERR are set by run_pm.
new_env() {
  D=$TMP/t$N; STUB=$D/stub; WD=$D/work
  mkdir -p "$STUB" "$WD"
  printf '#!/bin/sh\nshift\nexec "$@"\n' >"$STUB/timeout"
  # sacct: '--format=' call = full accounting table; '-o StdOut,...' call = output-path lookup
  cat >"$STUB/sacct" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
case "$*" in
  *--format=*) cat "$d/sacct.main" ;;
  *StdOut,StdErr*) [ -f "$d/sacct.paths" ] && cat "$d/sacct.paths"; exit 0 ;;
  *) echo "stub sacct: unexpected args: $*" >&2; exit 1 ;;
esac
EOF
  cat >"$STUB/scontrol" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
case "$*" in
  "show job"*) [ -f "$d/scontrol.job" ] && cat "$d/scontrol.job"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/timeout" "$STUB/sacct" "$STUB/scontrol"
  printf '%s\n' "JobID|JobName|State|ExitCode|Reason|Partition|Account|QOS|Submit|Start|End|Elapsed|Timelimit|ReqCPUS|AllocCPUS|ReqMem|MaxRSS|TotalCPU|NodeList|WorkDir" >"$STUB/sacct.main"
}

# sacct_row JOBID NAME STATE ELAPSED ALLOCCPUS TOTALCPU  -> appends one 20-column row (WorkDir = $WD)
sacct_row() {
  printf '%s\n' "$1|$2|$3|0:0|None|low|acct|normal|2026-01-01T00:00:00|2026-01-01T00:00:10|2026-01-01T01:00:00|$4|01:00:00|$5|$5|4G||$6|node1|$WD" >>"$STUB/sacct.main"
}

# run_pm ARGS...: run the script under test with stubs first on PATH; fills OUT (stdout) and ERR (stderr)
run_pm() {
  # wc -l pads its count on macOS ("(       3 lines)"); squeeze that so output is the same on BSD and GNU
  OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$@" 2>"$D/stderr" | sed 's/(  *\([0-9][0-9]*\) lines)/(\1 lines)/'); ERR=$(cat "$D/stderr")
}

# assertions: record a failure note (plus one output excerpt) instead of aborting
has() { case $OUT in *"$1"*) ;; *) note "missing in stdout: $1"; excerpt;; esac; }
hasnt() { case $OUT in *"$1"*) note "unexpected in stdout: $1"; excerpt;; esac; }
errhasnt() { case $ERR in *"$1"*) note "unexpected on stderr: $1";; esac; }
count_is() { # PATTERN WANT  (fixed-string occurrences in stdout)
  local got; got=$(printf '%s\n' "$OUT" | grep -oF -- "$1" | wc -l | tr -d ' ')
  [ "$got" = "$2" ] || { note "expected $2 x '$1' in stdout, got $got"; excerpt; }
}
excerpt() {
  case $T_FAILS in *"--- stdout"*) ;; *)
    note "--- stdout (stderr: ${ERR:-empty}) ---"
    T_FAILS="$T_FAILS
$(printf '%s\n' "$OUT" | sed 's/^/    # | /')";; esac
}
log_section() { printf '%s\n' "$OUT" | sed -n '/^== log files ==/,/^== verdict ==/p'; }

# ---- (a) TotalCPU/Elapsed with leading-zero 08/09 fields were parsed as octal --------------
# 03:08.563 over 8 CPUs x 00:03:27 -> 188s / (207s*8) = 11%
test_cpu_efficiency_08_seconds_not_octal() {
  new_env; sacct_row 3001 j COMPLETED 00:03:27 8 03:08.563
  run_pm 3001 --no-logs
  has "cpu efficiency: 11%"; errhasnt "value too great for base"
}
# 00:09:27 elapsed and TotalCPU on 1 CPU -> 100%
test_cpu_efficiency_09_minutes_not_octal() {
  new_env; sacct_row 3002 j COMPLETED 00:09:27 1 00:09:27
  run_pm 3002 --no-logs
  has "cpu efficiency: 100%"; errhasnt "value too great for base"
}
# D-HH:MM:SS: 1-08:09:08 on 4 CPUs, TotalCPU equal to elapsed -> 25%
test_cpu_efficiency_days_08_09_not_octal() {
  new_env; sacct_row 3003 j COMPLETED 1-08:09:08 4 1-08:09:08
  run_pm 3003 --no-logs
  has "cpu efficiency: 25%"; errhasnt "value too great for base"
}

# ---- (b) bare array id: scontrol prints a pending placeholder AND a running task ----------
test_array_bare_id_single_live_record_and_log() {
  new_env
  sacct_row 1234_1 arr RUNNING 00:01:00 1 00:00:30
  sacct_row '1234_[2-23%3]' arr PENDING 00:00:00 1 00:00:00
  : >"$STUB/sacct.paths"
  printf 'one\ntwo\n' >"$WD/slurm-1234_1.out"
  cat >"$STUB/scontrol.job" <<EOF
JobId=1234 ArrayJobId=1234 ArrayTaskId=2-23%3 JobName=arr
   JobState=PENDING Reason=JobArrayTaskLimit Dependency=(null)
   NodeList=(null)
   StdOut=/nonexistent/placeholder.out

JobId=1235 ArrayJobId=1234 ArrayTaskId=1 JobName=arr
   JobState=RUNNING Reason=None
   NodeList=node1
   StdOut=$WD/slurm-1234_1.out
   StdErr=$WD/slurm-1234_1.out
EOF
  run_pm 1234
  count_is "JobState=" 1; count_is "NodeList=" 1; count_is "StdOut=" 1
  has "JobState=RUNNING"; has "NodeList=node1"
  has "-- $WD/slurm-1234_1.out (2 lines)"; hasnt "not readable/found"
}

# ---- (c) fallback glob (no StdOut known): dirs, header lines and longer ids must not leak ----
test_log_fallback_only_regular_file_for_exact_id() {
  new_env; sacct_row 5555 j COMPLETED 00:01:00 1 00:00:30
  : >"$STUB/sacct.paths"
  mkdir "$WD/job-5555"; echo x >"$WD/job-5555/inner.txt"      # directory named like the job
  echo "ok" >"$WD/slurm-5555.out"                              # the right log
  echo "other" >"$WD/slurm-95555.out"; echo "other" >"$WD/slurm-55550.out"   # id inside longer numbers
  run_pm 5555
  local sec; sec=$(log_section)
  [ "$(printf '%s\n' "$sec" | grep -c '^-- ')" = 1 ] || { note "expected exactly one '-- ' log header"; OUT=$sec; excerpt; }
  OUT=$sec
  has "-- $WD/slurm-5555.out (1 lines)"
  hasnt "slurm-95555"; hasnt "slurm-55550"; hasnt "inner.txt"; hasnt "job-5555"; hasnt "not readable/found"
}

# ---- (d) custom --output/--error: recovered from sacct, scontrol has forgotten the job ------
test_custom_output_pattern_array_expanded_from_sacct() {
  new_env; sacct_row 7777_3 named COMPLETED 00:01:00 1 00:00:30
  local L=$D/elsewhere; mkdir -p "$L"
  printf '%s\n' "$L/name-%A_%a.out|$L/name-%A_%a.err|7778|alice" >"$STUB/sacct.paths"
  printf 'hello\nError: boom\n' >"$L/name-7777_3.out"; echo "warn" >"$L/name-7777_3.err"
  run_pm 7777_3
  hasnt "No log file found"; has "-- $L/name-7777_3.out (2 lines)"; has "-- $L/name-7777_3.err (1 lines)"; has "Error: boom"
}
test_custom_output_relative_pattern_with_x_u_j() {
  new_env; sacct_row 8888 myjob COMPLETED 00:01:00 1 00:00:30
  mkdir -p "$WD/logs"; echo "line" >"$WD/logs/myjob-alice-8888.log"
  printf '%s\n' "logs/%x-%u-%j.log|logs/%x-%u-%j.log|8888|alice" >"$STUB/sacct.paths"
  run_pm 8888
  hasnt "No log file found"; has "-- $WD/logs/myjob-alice-8888.log (1 lines)"
}

# ---- (e) control: ordinary COMPLETED job + default slurm-<id>.out; output must not change ----
# The golden text below was captured from the pristine script. The sacct table is excluded (column(1) differs by OS).
test_control_completed_default_log_unchanged() {
  new_env; sacct_row 4242 ctrl COMPLETED 00:10:00 2 00:12:00
  : >"$STUB/sacct.paths"
  printf 'step 1\nstep 2\ndone\n' >"$WD/slurm-4242.out"
  run_pm 4242
  printf '%s\n' "$OUT" | sed -n '/^== summary ==/,$p' | sed "s#$WD#@WD@#g" >"$D/got"
  cat >"$D/want" <<'EOF'
== summary ==
job 4242 (ctrl): state=COMPLETED exit=0:0 partition=low account=acct qos=normal
time: elapsed=00:10:00 of limit=01:00:00   cpus=2   nodes=node1
memory: requested 4G (no RSS recorded; job may not have run)
cpu efficiency: 60%  (TotalCPU 00:12:00 over 2 CPUs × 00:10:00)

== diagnosis ==
Exited 0. If results are wrong/missing, add 'set -euo pipefail' so intermediate failures surface, and check the log below.

== log files ==

-- @WD@/slurm-4242.out (3 lines)
   program output:
   | step 1
   | step 2
   | done

== verdict ==
* No fatal messages found in the logs; the job ran to completion. If results are wrong, the problem is in the program's logic or inputs.
EOF
  diff -u "$D/want" "$D/got" >"$D/diff" 2>&1 || { note "output differs from golden:"; T_FAILS="$T_FAILS
$(sed 's/^/    # /' "$D/diff")"; }
  [ -z "$ERR" ] || note "unexpected stderr: $ERR"
}

# ---- runner -----------------------------------------------------------------------------------
for t in \
  test_cpu_efficiency_08_seconds_not_octal \
  test_cpu_efficiency_09_minutes_not_octal \
  test_cpu_efficiency_days_08_09_not_octal \
  test_array_bare_id_single_live_record_and_log \
  test_log_fallback_only_regular_file_for_exact_id \
  test_custom_output_pattern_array_expanded_from_sacct \
  test_custom_output_relative_pattern_with_x_u_j \
  test_control_completed_default_log_unchanged
do
  N=$((N+1)); T_FAILS=""
  "$t"
  if [ -z "$T_FAILS" ]; then echo "ok $N - $t"
  else echo "not ok $N - $t"; printf '%s\n' "$T_FAILS"; FAILED=$((FAILED+1)); fi
done
echo "1..$N"
[ "$FAILED" -eq 0 ] || { echo "# $FAILED of $N failed (SCRIPTS_DIR=$SCRIPTS_DIR)"; exit 1; }
exit 0
