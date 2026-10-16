#!/usr/bin/env bash
# Cluster-free regression tests for ucd-hpc/scripts/job-postmortem.sh (stub sacct/scontrol in a temp PATH dir).
# Covers: octal-looking TotalCPU/Elapsed values, bare array ids and het jobs (multi-record scontrol), log fallback
# globbing, custom --output/--error patterns recovered from sacct, and scontrol paths preferred while the job is live. Run: bash test-job-postmortem.sh  (TAP-like, exit 1 on failure).
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
  # sacct: the script makes exactly one call, '--format=...' = the full accounting table (incl. StdOut/StdErr)
  cat >"$STUB/sacct" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
case "$*" in
  *--format=*) cat "$d/sacct.main" ;;
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
  printf '%s\n' "JobID|JobName|State|ExitCode|Reason|Partition|Account|QOS|Submit|Start|End|Elapsed|Timelimit|ReqCPUS|AllocCPUS|ReqMem|MaxRSS|TotalCPU|NodeList|WorkDir|StdOut|StdErr|JobIDRaw|User" >"$STUB/sacct.main"
}

# sacct_row JOBID NAME STATE ELAPSED ALLOCCPUS TOTALCPU [STDOUT STDERR JOBIDRAW USER]
#   -> appends one 24-column row (WorkDir = $WD; StdOut/StdErr empty = no --output/--error, as sacct reports it)
sacct_row() {
  printf '%s\n' "$1|$2|$3|0:0|None|low|acct|normal|2026-01-01T00:00:00|2026-01-01T00:00:10|2026-01-01T01:00:00|$4|01:00:00|$5|$5|4G||$6|node1|$WD|${7:-}|${8:-}|${9:-$1}|${10:-alice}" >>"$STUB/sacct.main"
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
  printf 'one\ntwo\n' >"$WD/slurm-1234_1.out"
  cat >"$STUB/scontrol.job" <<EOF
JobId=1236 ArrayJobId=1234 ArrayTaskId=5 JobName=arr
   JobState=RUNNING Reason=None
   NodeList=node5
   StdOut=$WD/slurm-1234_5.out

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
  # the live record is task 1 (sacct's main row), not task 5 (first running record); the pending placeholder
  # is shown too because its Reason explains the wait; the other running task is not
  has "scontrol show job 1234_1 (live)"; has "NodeList=node1"; hasnt "node5"
  has "-- also JobId=1234 ArrayTaskId=2-23%3:"; has "Reason=JobArrayTaskLimit"; count_is "JobState=" 2
  has "-- $WD/slurm-1234_1.out (2 lines)"; hasnt "not readable/found"; hasnt "-- /nonexistent/placeholder.out"
}

# ---- (b1) the main task already left the controller: the placeholder must not supply its log path ----
test_array_task_gone_placeholder_not_used_for_logs() {
  new_env
  sacct_row 2345_1 arr COMPLETED 00:01:00 1 00:00:30 "out/%A_%a.out" "" 2346
  sacct_row '2345_[2-9%2]' arr PENDING 00:00:00 1 00:00:00 "out/%A_%a.out" "" 2345
  mkdir -p "$WD/out"; echo "task one" >"$WD/out/2345_1.out"
  printf '%s\n' "JobId=2345 ArrayJobId=2345 ArrayTaskId=2-9%2 JobName=arr" \
    "   JobState=PENDING Reason=JobArrayTaskLimit" "   StdOut=$WD/out/2345_4294967294.out" >"$STUB/scontrol.job"
  run_pm 2345
  has "2345_1 itself is no longer in the controller"; has "-- also JobId=2345 ArrayTaskId=2-9%2:"
  has "-- $WD/out/2345_1.out (1 lines)"; hasnt "-- $WD/out/2345_4294967294.out"
}

# ---- (b2) het job: every component is shown, the one sacct picked first ----------------------
test_het_job_all_components_shown() {
  new_env
  sacct_row 4000+0 het RUNNING 00:01:00 1 00:00:30
  sacct_row 4000+1 het RUNNING 00:01:00 1 00:00:30
  cat >"$STUB/scontrol.job" <<EOF
JobId=4000 HetJobId=4000 HetJobOffset=0 JobName=het
   JobState=RUNNING Reason=None
   NodeList=nodeA

JobId=4001 HetJobId=4000 HetJobOffset=1 JobName=het
   JobState=RUNNING Reason=None
   NodeList=nodeB
EOF
  run_pm 4000 --no-logs
  has "scontrol show job 4000+0 (live)"; has "NodeList=nodeA"
  has "-- also JobId=4001 HetJobOffset=1:"; has "NodeList=nodeB"
}

# ---- (c) fallback glob (no StdOut known): dirs, header lines and longer ids must not leak ----
test_log_fallback_only_regular_file_for_exact_id() {
  new_env; sacct_row 5555 j COMPLETED 00:01:00 1 00:00:30
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
  new_env; local L=$D/elsewhere; mkdir -p "$L"
  sacct_row 7777_3 named COMPLETED 00:01:00 1 00:00:30 "$L/name-%A_%a.out" "$L/name-%A_%a.err" 7778
  printf 'hello\nError: boom\n' >"$L/name-7777_3.out"; echo "warn" >"$L/name-7777_3.err"
  run_pm 7777_3
  hasnt "No log file found"; has "-- $L/name-7777_3.out (2 lines)"; has "-- $L/name-7777_3.err (1 lines)"; has "Error: boom"
}
test_custom_output_relative_pattern_with_x_u_j() {
  new_env; sacct_row 8888 myjob COMPLETED 00:01:00 1 00:00:30 "logs/%x-%u-%j.log" "logs/%x-%u-%j.log" 8888 alice
  mkdir -p "$WD/logs"; echo "line" >"$WD/logs/myjob-alice-8888.log"
  run_pm 8888
  hasnt "No log file found"; has "-- $WD/logs/myjob-alice-8888.log (1 lines)"
}
# only --error was set and the job has left scontrol: the stderr file must still be read
test_error_only_pattern_used_when_job_gone() {
  new_env; sacct_row 9100 e FAILED 00:01:00 1 00:00:30 "" "logs/err-%j.txt"
  mkdir -p "$WD/logs"; echo "Error: real cause" >"$WD/logs/err-9100.txt"
  run_pm 9100
  has "-- $WD/logs/err-9100.txt (1 lines)"; has "Error: real cause"; hasnt "No log file found"
}
# live job: scontrol's expanded path wins over sacct's pattern (%a of a non-array job is 4294967294, not the id)
test_live_scontrol_path_preferred_over_sacct_pattern() {
  new_env; sacct_row 9200 run RUNNING 00:01:00 1 00:00:30 "run-%a.log" "" 9200
  echo "progress" >"$WD/run-4294967294.log"
  printf '%s\n' "JobId=9200 JobName=run" "   JobState=RUNNING Reason=None" "   StdOut=$WD/run-4294967294.log" >"$STUB/scontrol.job"
  run_pm 9200
  has "-- $WD/run-4294967294.log (1 lines)"; hasnt "run-9200.log"; hasnt "not readable/found"
}
# scontrol has forgotten the job: %a of a non-array job still expands to 4294967294
test_non_array_percent_a_expanded_from_sacct() {
  new_env; sacct_row 9300 run COMPLETED 00:01:00 1 00:00:30 "run-%a.log" "" 9300
  echo "done" >"$WD/run-4294967294.log"
  run_pm 9300
  has "-- $WD/run-4294967294.log (1 lines)"; hasnt "not readable/found"
}
# job names containing '&' are substituted literally (bash 5.2 patsub_replacement would insert the match)
test_ampersand_in_job_name_kept_literally() {
  new_env; sacct_row 9400 'a&b' COMPLETED 00:01:00 1 00:00:30 "%x-%j.out" "" 9400
  echo "ok" >"$WD/a&b-9400.out"
  run_pm 9400
  has "-- $WD/a&b-9400.out (1 lines)"; hasnt "No log file found"
}

# ---- (e) control: ordinary COMPLETED job + default slurm-<id>.out; output must not change ----
# The golden text below was captured from the pristine script. The sacct table is excluded (column(1) differs by OS).
test_control_completed_default_log_unchanged() {
  new_env; sacct_row 4242 ctrl COMPLETED 00:10:00 2 00:12:00
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
  test_array_task_gone_placeholder_not_used_for_logs \
  test_het_job_all_components_shown \
  test_log_fallback_only_regular_file_for_exact_id \
  test_custom_output_pattern_array_expanded_from_sacct \
  test_custom_output_relative_pattern_with_x_u_j \
  test_error_only_pattern_used_when_job_gone \
  test_live_scontrol_path_preferred_over_sacct_pattern \
  test_non_array_percent_a_expanded_from_sacct \
  test_ampersand_in_job_name_kept_literally \
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
