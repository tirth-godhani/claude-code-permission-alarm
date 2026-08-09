#!/usr/bin/env bash
# Logic-only test suite. Every test uses PERMISSION_ALARM_DRY_RUN=1 so no
# real audio ever plays and no real command ever runs (the two exceptions —
# testing sound-missing and command-failure handling — call lib/attention.sh
# functions directly with a trivial, safe mock like `false`, never through a
# real background worker). Each test gets its own isolated STATE_DIR/LOG_FILE
# under a fresh temp dir so tests never interfere with each other.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 -- $2"; }

# wait_for <file> <pattern> <timeout_secs> -- polls in 0.1s ticks, doesn't sleep fixed amounts
wait_for() {
  local file="$1" pattern="$2" timeout="${3:-5}"
  local ticks=$((timeout * 10))
  local i=0
  while [[ "$i" -lt "$ticks" ]]; do
    if [[ -f "$file" ]] && grep -q -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [[ -f "$file" ]] && grep -q -- "$pattern" "$file" 2>/dev/null
}

not_present() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || return 0
  ! grep -q -- "$pattern" "$file" 2>/dev/null
}

# count_matches <file> <pattern> -- grep -c prints "0" AND exits non-zero on
# no match, so `grep -c ... || echo 0` double-counts; this avoids that.
count_matches() {
  local file="$1" pattern="$2"
  if [[ -f "$file" ]]; then
    grep -c -- "$pattern" "$file" 2>/dev/null
  else
    echo 0
  fi
}

# fixture <name> <session_id> -- prints fixture JSON with session_id substituted
fixture() {
  local name="$1" session_id="$2"
  sed "s/SESSION_ID_PLACEHOLDER/$session_id/" "$ROOT/tests/fixtures/${name}.json"
}

# send_event <fixture_name> <session_id> <state_dir> <log_file> [extra env assignments...]
send_event() {
  local fname="$1" sid="$2" state_dir="$3" log_file="$4"; shift 4
  fixture "$fname" "$sid" | env \
    STATE_DIR="$state_dir" \
    LOG_FILE="$log_file" \
    PERMISSION_ALARM_DRY_RUN=1 \
    "$@" \
    "$ROOT/bin/permission-hook.sh"
}

new_case_dir() {
  local n="$1"
  local d="$TEST_TMP/$n"
  mkdir -p "$d/state"
  echo "$d"
}

echo "=== Permission Timeout & Attention Reminder -- test suite ==="

# 1. Permission detected -> timer starts
{
  name="permission_detected_starts_timer"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-1"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=5
  if wait_for "$log" "permission wait detected" 3 && wait_for "$log" "timer started" 3; then
    pass "$name"
  else
    fail "$name" "expected detection + timer-start log lines"
  fi
}

# 2. User responds before timeout -> timer cancelled, no attention triggered
{
  name="respond_before_timeout_cancels"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-2"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=6
  sleep 0.5
  send_event pretooluse "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=6
  if wait_for "$log" "user responded" 4 && not_present "$log" "triggering attention"; then
    pass "$name"
  else
    fail "$name" "expected cancellation log and no attention trigger"
  fi
}

# 3. Responds around the boundary -> exactly one outcome, never both
{
  name="boundary_response_no_duplicate_reminder"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-3"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1
  sleep 0.9
  send_event pretooluse "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1
  sleep 1.5
  cancels="$(count_matches "$log" "user responded")"
  triggers="$(count_matches "$log" "triggering attention")"
  total=$((cancels + triggers))
  if [[ "$total" -eq 1 ]]; then
    pass "$name"
  else
    fail "$name" "expected exactly one outcome, got $cancels cancels + $triggers triggers"
  fi
}

# 4 & 5. No response -> attention command AND sound both execute (dry-run logged)
{
  name="no_response_triggers_command_and_sound"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-4"
  send_event permission_request "$sid" "$d/state" "$log" \
    PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1 \
    ATTENTION_COMMAND="true" ENABLE_ATTENTION_COMMAND=true ENABLE_ATTENTION_SOUND=true
  if wait_for "$log" "triggering attention" 4 \
     && wait_for "$log" "\[dry-run\] would run command" 2 \
     && wait_for "$log" "\[dry-run\] would play sound" 2; then
    pass "$name"
  else
    fail "$name" "expected both command and sound dry-run log lines after timeout"
  fi
}

# 6. Sound disabled -> command still executes
{
  name="sound_disabled_command_still_executes"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-5"
  send_event permission_request "$sid" "$d/state" "$log" \
    PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1 \
    ATTENTION_COMMAND="true" ENABLE_ATTENTION_COMMAND=true ENABLE_ATTENTION_SOUND=false
  if wait_for "$log" "\[dry-run\] would run command" 4 && wait_for "$log" "sound disabled" 2; then
    pass "$name"
  else
    fail "$name" "expected command to run and sound to be skipped"
  fi
}

# 7. Command disabled -> sound still plays
{
  name="command_disabled_sound_still_plays"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-6"
  send_event permission_request "$sid" "$d/state" "$log" \
    PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1 \
    ATTENTION_COMMAND="true" ENABLE_ATTENTION_COMMAND=false ENABLE_ATTENTION_SOUND=true
  if wait_for "$log" "\[dry-run\] would play sound" 4 && wait_for "$log" "attention command disabled" 2; then
    pass "$name"
  else
    fail "$name" "expected sound to play and command to be skipped"
  fi
}

# 8. Both disabled -> nothing happens
{
  name="both_disabled_nothing_happens"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-7"
  send_event permission_request "$sid" "$d/state" "$log" \
    PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1 \
    ATTENTION_COMMAND="true" ENABLE_ATTENTION_COMMAND=false ENABLE_ATTENTION_SOUND=false
  wait_for "$log" "attention sequence complete" 4 >/dev/null
  if not_present "$log" "\[dry-run\] would run command" && not_present "$log" "\[dry-run\] would play sound"; then
    pass "$name"
  else
    fail "$name" "expected neither command nor sound dry-run lines"
  fi
}

# 9. Missing MP3 -> does not crash (unit-level, direct function call)
{
  name="missing_mp3_no_crash"
  d="$(new_case_dir "$name")"; log="$d/log"
  out="$(
    STATE_DIR="$d/state" LOG_FILE="$log" PERMISSION_ALARM_DRY_RUN=1 \
    ATTENTION_SOUND="/nonexistent/path/nope.mp3" ENABLE_ATTENTION_SOUND=true \
    bash -c "source '$ROOT/lib/common.sh'; source '$ROOT/lib/idle.sh'; source '$ROOT/lib/attention.sh'; play_sound" 2>&1
  )"
  rc=$?
  if [[ "$rc" -eq 0 || "$rc" -eq 1 ]] && wait_for "$log" "not found" 2; then
    pass "$name"
  else
    fail "$name" "expected graceful handling (no crash), got exit=$rc, output: $out"
  fi
}

# 10. Command failure -> does not crash (unit-level, mock command `false`)
{
  name="command_failure_no_crash"
  d="$(new_case_dir "$name")"; log="$d/log"
  STATE_DIR="$d/state" LOG_FILE="$log" PERMISSION_ALARM_DRY_RUN=0 \
    ATTENTION_COMMAND="false" ENABLE_ATTENTION_COMMAND=true \
    bash -c "source '$ROOT/lib/common.sh'; source '$ROOT/lib/idle.sh'; source '$ROOT/lib/attention.sh'; run_attention_command"
  rc=$?
  if [[ "$rc" -eq 0 ]] && wait_for "$log" "attention command failed" 2; then
    pass "$name"
  else
    fail "$name" "run_attention_command should always return 0 and log the failure, got exit=$rc"
  fi
}

# 11. Multiple prompts across sessions work independently
{
  name="multiple_prompts_independent"
  d="$(new_case_dir "$name")"; log="$d/log"
  sidA="sess-8a"; sidB="sess-8b"
  send_event permission_request "$sidA" "$d/state" "$log" PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1
  send_event permission_request "$sidB" "$d/state" "$log" PERMISSION_TIMEOUT=6 POLL_INTERVAL=0.1
  sleep 0.4
  send_event pretooluse "$sidB" "$d/state" "$log" PERMISSION_TIMEOUT=6 POLL_INTERVAL=0.1
  a_triggered="$(wait_for "$log" "session=$sidA .*triggering attention" 4 && echo yes || echo no)"
  b_cancelled="$(wait_for "$log" "session=$sidB .*user responded" 4 && echo yes || echo no)"
  if [[ "$a_triggered" == "yes" && "$b_cancelled" == "yes" ]]; then
    pass "$name"
  else
    fail "$name" "expected session A to time out and session B to cancel independently"
  fi
}

# 12. Timer cleans itself up even with no supervising parent process
{
  name="orphaned_timer_self_cleans"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-9"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=1 POLL_INTERVAL=0.1
  if wait_for "$log" "attention sequence complete" 4; then
    sleep 0.3
    if [[ ! -d "$d/state/${sid}.lock" ]]; then
      pass "$name"
    else
      fail "$name" "lock directory was not released after worker completed"
    fi
  else
    fail "$name" "worker never completed"
  fi
}

# 13. Configured timeout value is honored (relative timing sanity check)
{
  name="configured_timeout_honored"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-10"
  start_ts="$(date +%s)"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=2 POLL_INTERVAL=0.1
  wait_for "$log" "triggering attention" 5 >/dev/null
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))
  if [[ "$elapsed" -ge 1 && "$elapsed" -le 4 ]]; then
    pass "$name"
  else
    fail "$name" "expected trigger roughly ~2s in, took ${elapsed}s"
  fi
}

# 14. No duplicate timers for the same prompt
{
  name="no_duplicate_timers"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-11"
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=2 POLL_INTERVAL=0.1
  sleep 0.2
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=2 POLL_INTERVAL=0.1
  sleep 0.2
  send_event permission_request "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=2 POLL_INTERVAL=0.1
  wait_for "$log" "triggering attention" 5 >/dev/null
  starts="$(count_matches "$log" "timer started")"
  dupes="$(count_matches "$log" "not spawning another")"
  if [[ "$starts" -eq 1 && "$dupes" -eq 2 ]]; then
    pass "$name"
  else
    fail "$name" "expected exactly 1 timer start and 2 duplicate-suppressions, got $starts starts / $dupes suppressions"
  fi
}

# Bonus: physical idle-based cancellation path (distinct from hook-activity path)
{
  name="idle_based_cancellation"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-12"
  idle_file="$d/idle_override"
  echo 999 >"$idle_file"
  fixture permission_request "$sid" | env \
    STATE_DIR="$d/state" LOG_FILE="$log" PERMISSION_ALARM_DRY_RUN=1 \
    PERMISSION_TIMEOUT=4 POLL_INTERVAL=0.1 ENABLE_IDLE_FALLBACK_CANCEL=true \
    PERMISSION_ALARM_IDLE_OVERRIDE_FILE="$idle_file" \
    "$ROOT/bin/permission-hook.sh"
  sleep 0.6
  echo 0 >"$idle_file"
  if wait_for "$log" "physical input detected" 3; then
    pass "$name"
  else
    fail "$name" "expected idle-based cancellation once override file dropped to 0"
  fi
}

# Bonus: idle_prompt notifications never start a timer -- Claude Code sends
# these just for sitting idle waiting on your next message, not only for an
# actual permission dialog, so treating it as a wait event fired the alarm
# with nothing to respond to.
{
  name="idle_prompt_notification_ignored"
  d="$(new_case_dir "$name")"; log="$d/log"; sid="sess-14"
  send_event notification_idle_prompt "$sid" "$d/state" "$log" PERMISSION_TIMEOUT=1
  sleep 0.3
  if not_present "$log" "timer started"; then
    pass "$name"
  else
    fail "$name" "idle_prompt notification must never start a timer"
  fi
}

# Bonus: malformed / unrelated events never start a timer
{
  name="malformed_and_unrelated_events_ignored"
  d="$(new_case_dir "$name")"; log="$d/log"
  cat "$ROOT/tests/fixtures/malformed.json" | env STATE_DIR="$d/state" LOG_FILE="$log" PERMISSION_ALARM_DRY_RUN=1 "$ROOT/bin/permission-hook.sh"
  rc1=$?
  send_event notification_unrelated "sess-13" "$d/state" "$log" PERMISSION_TIMEOUT=1
  sleep 0.3
  if [[ "$rc1" -eq 0 ]] && not_present "$log" "timer started"; then
    pass "$name"
  else
    fail "$name" "malformed/unrelated events must exit 0 and never start a timer"
  fi
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
