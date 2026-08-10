#!/usr/bin/env bash
# PermissionDetector + dispatcher. Invoked directly by Claude Code as a
# `command` hook on PermissionRequest, Notification, PreToolUse,
# UserPromptSubmit, and Stop. Must return in milliseconds and must never
# exit non-zero or print to stdout — any stdout on a PermissionRequest hook
# is parsed by Claude Code as a decision-control payload, and this tool must
# never influence Allow/Deny. All real work happens in the detached worker
# spawned below, which runs after this script has already exited.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/idle.sh"

PAYLOAD="$(cat 2>/dev/null || true)"

if [[ "$DEBUG_LOG_PAYLOAD" == "true" ]]; then
  log DEBUG "raw payload: $PAYLOAD"
fi

# Single jq call for all three fields instead of three separate jq spawns --
# this runs on every PreToolUse/PostToolUse, so it's the hottest path in the
# tool. On invalid JSON, jq exits non-zero with no stdout, `read` then fails
# and leaves the vars unset; the :- defaults below cover that exactly the
# same way the old per-field jq_field defaults did.
IFS=$'\t' read -r HOOK_EVENT SESSION_ID NOTIFICATION_TYPE < <(
  printf '%s' "$PAYLOAD" | jq -r '[(.hook_event_name // ""), (.session_id // "unknown"), (.notification_type // "")] | @tsv' 2>/dev/null
) || true
HOOK_EVENT="${HOOK_EVENT:-}"
SESSION_ID="${SESSION_ID:-unknown}"
NOTIFICATION_TYPE="${NOTIFICATION_TYPE:-}"

if [[ -z "$HOOK_EVENT" ]]; then
  log WARN "malformed payload, no hook_event_name field, ignoring"
  exit 0
fi

# session_id becomes a filesystem path component (lock/activity files) and is
# spliced into an embedded `bash -c` string below to launch the timeout
# worker, so it must be restricted to a safe charset before either happens.
# Claude Code generates this internally as a UUID today, but nothing
# upstream guarantees that, so this validates defensively rather than
# trusting the payload.
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  log WARN "session_id contains unexpected characters, ignoring event"
  exit 0
fi

is_wait_event() {
  case "$HOOK_EVENT" in
    PermissionRequest) return 0 ;;
    Notification)
      case "$NOTIFICATION_TYPE" in
        # Only an actual Allow/Deny dialog counts. idle_prompt and
        # agent_needs_input fire whenever Claude Code is simply waiting for
        # your next message (normal, constant background noise between
        # turns) -- treating those as a wait event fired the alarm for no
        # reason, with nothing to actually respond to.
        permission_prompt) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

is_activity_event() {
  case "$HOOK_EVENT" in
    PreToolUse|PostToolUse|UserPromptSubmit|Stop|SubagentStop|PermissionDenied) return 0 ;;
    *) return 1 ;;
  esac
}

if is_wait_event; then
  log INFO "session=$SESSION_ID permission wait detected (event=$HOOK_EVENT type=${NOTIFICATION_TYPE:-n/a})"
  # Housekeeping lives here rather than on the hot PreToolUse/PostToolUse
  # path -- a permission wait is comparatively rare, so this never adds
  # overhead to every tool call.
  rotate_log_if_needed
  prune_stale_activity_files
  # Lock is acquired synchronously, here, in the fast hook path (a single
  # atomic mkdir) rather than inside the backgrounded worker -- doing it
  # asynchronously would leave a race window where two rapid invocations
  # both see "not held" before either actually acquires it, spawning
  # duplicate timers. The worker inherits an already-held lock and is
  # responsible only for releasing it.
  if ! acquire_lock "$SESSION_ID"; then
    log INFO "session=$SESSION_ID timer already active, not spawning another"
  else
    nohup env \
      PERMISSION_TIMEOUT="$PERMISSION_TIMEOUT" \
      ATTENTION_SOUND="$ATTENTION_SOUND" \
      ATTENTION_COMMAND="$ATTENTION_COMMAND" \
      ENABLE_ATTENTION_SOUND="$ENABLE_ATTENTION_SOUND" \
      ENABLE_ATTENTION_COMMAND="$ENABLE_ATTENTION_COMMAND" \
      POLL_INTERVAL="$POLL_INTERVAL" \
      LOG_FILE="$LOG_FILE" \
      STATE_DIR="$STATE_DIR" \
      COMMAND_TIMEOUT="$COMMAND_TIMEOUT" \
      ENABLE_IDLE_FALLBACK_CANCEL="$ENABLE_IDLE_FALLBACK_CANCEL" \
      ATTENTION_SOUND_GAIN="$ATTENTION_SOUND_GAIN" \
      FORCE_SYSTEM_VOLUME="$FORCE_SYSTEM_VOLUME" \
      SYSTEM_VOLUME_LEVEL="$SYSTEM_VOLUME_LEVEL" \
      PERMISSION_ALARM_DRY_RUN="$PERMISSION_ALARM_DRY_RUN" \
      PERMISSION_ALARM_IDLE_OVERRIDE="$PERMISSION_ALARM_IDLE_OVERRIDE" \
      PERMISSION_ALARM_IDLE_OVERRIDE_FILE="$PERMISSION_ALARM_IDLE_OVERRIDE_FILE" \
      bash -c '
        source "'"$SCRIPT_DIR"'/lib/common.sh"
        source "'"$SCRIPT_DIR"'/lib/idle.sh"
        source "'"$SCRIPT_DIR"'/lib/attention.sh"
        source "'"$SCRIPT_DIR"'/lib/timer.sh"
        run_timeout_worker "'"$SESSION_ID"'"
      ' >/dev/null 2>&1 </dev/null &
    # acquire_lock recorded this (parent) process's PID, but this process
    # exits within milliseconds by design -- overwrite the lock's pid file
    # with the backgrounded worker's PID so the stale-lock check in the next
    # invocation reflects the actually-still-running process, not us.
    echo "$!" >"$STATE_DIR/${SESSION_ID}.lock/pid" 2>/dev/null || true
    disown
  fi
elif is_activity_event; then
  mark_activity "$SESSION_ID"
  log INFO "session=$SESSION_ID activity event ($HOOK_EVENT), any pending timer will cancel"
fi

exit 0
