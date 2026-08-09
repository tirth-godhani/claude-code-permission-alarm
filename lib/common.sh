#!/usr/bin/env bash
# Shared config loading, logging, and locking primitives.
# Sourced by bin/permission-hook.sh and lib/*.sh — never executed directly.

PERMISSION_ALARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Precedence: explicit environment variable > config.env > built-in default
# below. Since config.env is sourced unconditionally, anything already set in
# the environment has to be snapshotted first and restored after, so a
# caller (or the test suite) can always override config.env per-invocation.
# (No associative arrays: macOS ships bash 3.2, which doesn't have them.)
_orig_PERMISSION_TIMEOUT="${PERMISSION_TIMEOUT-}"
_orig_ATTENTION_SOUND="${ATTENTION_SOUND-}"
_orig_ATTENTION_COMMAND="${ATTENTION_COMMAND-}"
_orig_ENABLE_ATTENTION_SOUND="${ENABLE_ATTENTION_SOUND-}"
_orig_ENABLE_ATTENTION_COMMAND="${ENABLE_ATTENTION_COMMAND-}"
_orig_POLL_INTERVAL="${POLL_INTERVAL-}"
_orig_LOG_FILE="${LOG_FILE-}"
_orig_STATE_DIR="${STATE_DIR-}"
_orig_DEBUG_LOG_PAYLOAD="${DEBUG_LOG_PAYLOAD-}"
_orig_COMMAND_TIMEOUT="${COMMAND_TIMEOUT-}"
_orig_ENABLE_IDLE_FALLBACK_CANCEL="${ENABLE_IDLE_FALLBACK_CANCEL-}"
_orig_ATTENTION_SOUND_GAIN="${ATTENTION_SOUND_GAIN-}"
_orig_FORCE_SYSTEM_VOLUME="${FORCE_SYSTEM_VOLUME-}"
_orig_SYSTEM_VOLUME_LEVEL="${SYSTEM_VOLUME_LEVEL-}"

if [[ -f "$PERMISSION_ALARM_ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$PERMISSION_ALARM_ROOT/config.env"
  set +a
fi

[[ -n "$_orig_PERMISSION_TIMEOUT" ]] && PERMISSION_TIMEOUT="$_orig_PERMISSION_TIMEOUT"
[[ -n "$_orig_ATTENTION_SOUND" ]] && ATTENTION_SOUND="$_orig_ATTENTION_SOUND"
[[ -n "$_orig_ATTENTION_COMMAND" ]] && ATTENTION_COMMAND="$_orig_ATTENTION_COMMAND"
[[ -n "$_orig_ENABLE_ATTENTION_SOUND" ]] && ENABLE_ATTENTION_SOUND="$_orig_ENABLE_ATTENTION_SOUND"
[[ -n "$_orig_ENABLE_ATTENTION_COMMAND" ]] && ENABLE_ATTENTION_COMMAND="$_orig_ENABLE_ATTENTION_COMMAND"
[[ -n "$_orig_POLL_INTERVAL" ]] && POLL_INTERVAL="$_orig_POLL_INTERVAL"
[[ -n "$_orig_LOG_FILE" ]] && LOG_FILE="$_orig_LOG_FILE"
[[ -n "$_orig_STATE_DIR" ]] && STATE_DIR="$_orig_STATE_DIR"
[[ -n "$_orig_DEBUG_LOG_PAYLOAD" ]] && DEBUG_LOG_PAYLOAD="$_orig_DEBUG_LOG_PAYLOAD"
[[ -n "$_orig_COMMAND_TIMEOUT" ]] && COMMAND_TIMEOUT="$_orig_COMMAND_TIMEOUT"
[[ -n "$_orig_ENABLE_IDLE_FALLBACK_CANCEL" ]] && ENABLE_IDLE_FALLBACK_CANCEL="$_orig_ENABLE_IDLE_FALLBACK_CANCEL"
[[ -n "$_orig_ATTENTION_SOUND_GAIN" ]] && ATTENTION_SOUND_GAIN="$_orig_ATTENTION_SOUND_GAIN"
[[ -n "$_orig_FORCE_SYSTEM_VOLUME" ]] && FORCE_SYSTEM_VOLUME="$_orig_FORCE_SYSTEM_VOLUME"
[[ -n "$_orig_SYSTEM_VOLUME_LEVEL" ]] && SYSTEM_VOLUME_LEVEL="$_orig_SYSTEM_VOLUME_LEVEL"

unset _orig_PERMISSION_TIMEOUT _orig_ATTENTION_SOUND _orig_ATTENTION_COMMAND \
  _orig_ENABLE_ATTENTION_SOUND _orig_ENABLE_ATTENTION_COMMAND _orig_POLL_INTERVAL \
  _orig_LOG_FILE _orig_STATE_DIR _orig_DEBUG_LOG_PAYLOAD _orig_COMMAND_TIMEOUT \
  _orig_ENABLE_IDLE_FALLBACK_CANCEL _orig_ATTENTION_SOUND_GAIN _orig_FORCE_SYSTEM_VOLUME \
  _orig_SYSTEM_VOLUME_LEVEL

# --- Built-in defaults for anything still unset after config.env ---
: "${PERMISSION_TIMEOUT:=10}"
: "${ATTENTION_SOUND:=$PERMISSION_ALARM_ROOT/assets/attention.mp3}"
: "${ATTENTION_COMMAND:=}"
: "${ENABLE_ATTENTION_SOUND:=true}"
: "${ENABLE_ATTENTION_COMMAND:=true}"
: "${POLL_INTERVAL:=0.5}"
: "${LOG_FILE:=$PERMISSION_ALARM_ROOT/logs/permission-alarm.log}"
: "${STATE_DIR:=$PERMISSION_ALARM_ROOT/state}"
: "${DEBUG_LOG_PAYLOAD:=false}"
: "${COMMAND_TIMEOUT:=15}"
# Off by default: system-wide physical idle time is a poor proxy for "the
# user answered this specific prompt" on a machine that's otherwise in use
# (any keystroke anywhere resets it), which can cancel the timer even though
# the prompt was never actually looked at. The hook-activity signal (the
# next PreToolUse/PermissionDenied for this session) is precise and is the
# default cancellation path; this is an opt-in extra backup only.
: "${ENABLE_IDLE_FALLBACK_CANCEL:=false}"
# afplay's own gain on the sound file itself. 1.0 is unity; higher values
# boost it further (values much above ~2 tend to just clip/distort rather
# than get meaningfully louder).
: "${ATTENTION_SOUND_GAIN:=1.5}"
# Temporarily raises macOS's system-wide output volume before playback and
# restores the prior level immediately after, so a quiet system volume can't
# defeat the reminder. Off by default -- changing the user's system volume,
# even briefly, is intrusive enough to require an explicit opt-in.
: "${FORCE_SYSTEM_VOLUME:=false}"
: "${SYSTEM_VOLUME_LEVEL:=85}"

# Test seams — never set these in normal use.
: "${PERMISSION_ALARM_DRY_RUN:=0}"
: "${PERMISSION_ALARM_IDLE_OVERRIDE:=}"
: "${PERMISSION_ALARM_IDLE_OVERRIDE_FILE:=}"

# Anchor any relative LOG_FILE/STATE_DIR/ATTENTION_SOUND (as shipped in
# config.env, e.g. "./logs/...") to the project root, not to the invoking
# process's cwd. Claude Code runs hooks with the cwd of whatever project the
# user is actually working in -- not this tool's own install directory --
# so a bare relative path here would silently read/write inside the user's
# unrelated project instead of this tool's own logs/state/assets.
[[ "$LOG_FILE" != /* ]] && LOG_FILE="$PERMISSION_ALARM_ROOT/$LOG_FILE"
[[ "$STATE_DIR" != /* ]] && STATE_DIR="$PERMISSION_ALARM_ROOT/$STATE_DIR"
[[ "$ATTENTION_SOUND" != /* ]] && ATTENTION_SOUND="$PERMISSION_ALARM_ROOT/$ATTENTION_SOUND"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# jq_field <json> <filter> <default>
jq_field() {
  local json="$1" filter="$2" default="${3:-}"
  local val
  val="$(printf '%s' "$json" | jq -r "$filter // empty" 2>/dev/null)"
  printf '%s' "${val:-$default}"
}

# acquire_lock <name> — atomic mkdir-based mutex, stale-lock aware.
# Returns 0 and writes our PID if acquired, 1 if another live holder exists.
acquire_lock() {
  local name="$1"
  local lock_dir="$STATE_DIR/${name}.lock"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" >"$lock_dir/pid"
    return 0
  fi
  local holder_pid
  holder_pid="$(cat "$lock_dir/pid" 2>/dev/null || echo "")"
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$lock_dir" 2>/dev/null
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" >"$lock_dir/pid"
    return 0
  fi
  return 1
}

release_lock() {
  local name="$1"
  rm -rf "$STATE_DIR/${name}.lock" 2>/dev/null || true
}

lock_held() {
  local name="$1"
  local lock_dir="$STATE_DIR/${name}.lock"
  [[ -d "$lock_dir" ]] || return 1
  local holder_pid
  holder_pid="$(cat "$lock_dir/pid" 2>/dev/null || echo "")"
  [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null
}

# now_ms — milliseconds since epoch. Plain `date +%s` has 1-second
# resolution, which is too coarse: a genuine response arriving <1s after a
# timer starts could land in the same second as the start timestamp and be
# missed by a strictly-greater-than comparison. Falls back to second
# resolution (times 1000) if %N isn't supported by the local `date`.
now_ms() {
  local ns
  ns="$(date +%s%N 2>/dev/null)"
  if [[ "$ns" =~ ^[0-9]{13,}$ ]]; then
    echo $((ns / 1000000))
  else
    echo $(($(date +%s) * 1000))
  fi
}

activity_file() {
  local session_id="$1"
  printf '%s/%s.activity' "$STATE_DIR" "$session_id"
}

mark_activity() {
  local session_id="$1"
  now_ms >"$(activity_file "$session_id")" 2>/dev/null || true
}

# mark_activity_at <session_id> <ms> -- writes an explicit timestamp rather
# than deriving a fresh one. Used only to seed the worker's baseline with
# exactly its own start_ms, so the baseline can never appear to be "after
# start" (a fresh now_ms() call here would always be later than a start_ms
# captured a moment earlier, causing an immediate false-positive "response").
mark_activity_at() {
  local session_id="$1" ms="$2"
  printf '%s' "$ms" >"$(activity_file "$session_id")" 2>/dev/null || true
}

last_activity_epoch() {
  local session_id="$1"
  cat "$(activity_file "$session_id")" 2>/dev/null || echo 0
}
