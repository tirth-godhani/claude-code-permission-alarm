#!/usr/bin/env bash
# AttentionManager: plays the configured sound and runs the configured
# command. Never touches Claude Code's permission decision — this module
# only ever logs and makes noise. Sourced, never executed directly.

FALLBACK_SOUND="/System/Library/Sounds/Sosumi.aiff"

play_sound() {
  if [[ "$ENABLE_ATTENTION_SOUND" != "true" ]]; then
    log INFO "sound disabled (ENABLE_ATTENTION_SOUND=$ENABLE_ATTENTION_SOUND), skipping"
    return 0
  fi

  local sound="$ATTENTION_SOUND"
  if [[ ! -f "$sound" ]]; then
    log WARN "attention sound not found at '$sound', falling back to system sound"
    sound="$FALLBACK_SOUND"
  fi
  if [[ ! -f "$sound" ]]; then
    log ERROR "fallback sound also missing at '$sound', skipping playback"
    return 1
  fi

  log INFO "sound playback started ($sound, gain=${ATTENTION_SOUND_GAIN}, forced_volume=${FORCE_SYSTEM_VOLUME}:${SYSTEM_VOLUME_LEVEL})"

  if [[ "$PERMISSION_ALARM_DRY_RUN" == "1" ]]; then
    log INFO "[dry-run] would play sound: $sound"
    return 0
  fi

  if ! command -v afplay >/dev/null 2>&1; then
    log ERROR "afplay not found, cannot play sound"
    return 1
  fi

  # Temporarily raise system output volume so a quiet system volume doesn't
  # defeat the point of the reminder. Always restored afterward, even if
  # afplay fails partway through. Off by default's opposite -- this only
  # runs when FORCE_SYSTEM_VOLUME=true, since silently changing the user's
  # system volume is intrusive enough to require an explicit opt-in.
  local prev_volume=""
  if [[ "$FORCE_SYSTEM_VOLUME" == "true" ]] && command -v osascript >/dev/null 2>&1; then
    prev_volume="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
    if [[ "$prev_volume" =~ ^[0-9]+$ ]]; then
      if osascript -e "set volume output volume $SYSTEM_VOLUME_LEVEL" >/dev/null 2>&1; then
        log INFO "system volume raised to ${SYSTEM_VOLUME_LEVEL} (was ${prev_volume})"
      else
        log WARN "failed to raise system volume, playing at current volume"
        prev_volume=""
      fi
    else
      prev_volume=""
    fi
  fi

  # Runs synchronously (not backgrounded): this already executes inside the
  # detached timer worker, off Claude Code's critical path, so blocking here
  # doesn't affect Claude Code at all -- and it lets us restore the system
  # volume deterministically right after playback finishes rather than racing
  # a backgrounded afplay process.
  afplay -v "$ATTENTION_SOUND_GAIN" "$sound" >/dev/null 2>>"$LOG_FILE"
  local rc=$?

  if [[ -n "$prev_volume" ]]; then
    if osascript -e "set volume output volume $prev_volume" >/dev/null 2>&1; then
      log INFO "system volume restored to ${prev_volume}"
    else
      log WARN "failed to restore system volume to ${prev_volume}"
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    log ERROR "sound playback failed (afplay exit $rc)"
    return 1
  fi
  log INFO "sound playback finished"
  return 0
}

# run_attention_command — executes ATTENTION_COMMAND exactly as configured,
# via `bash -c`, with no interpolation of any hook/tool payload data into the
# command string. ATTENTION_COMMAND is operator-supplied config, not
# attacker-controlled input, so this is not a shell-injection vector as long
# as callers never build the string from untrusted data (they don't).
run_attention_command() {
  if [[ "$ENABLE_ATTENTION_COMMAND" != "true" ]]; then
    log INFO "attention command disabled (ENABLE_ATTENTION_COMMAND=$ENABLE_ATTENTION_COMMAND), skipping"
    return 0
  fi
  if [[ -z "$ATTENTION_COMMAND" ]]; then
    log INFO "no ATTENTION_COMMAND configured, skipping"
    return 0
  fi

  log INFO "attention command started: $ATTENTION_COMMAND"

  if [[ "$PERMISSION_ALARM_DRY_RUN" == "1" ]]; then
    log INFO "[dry-run] would run command: $ATTENTION_COMMAND"
    return 0
  fi

  local timeout_bin=""
  command -v timeout >/dev/null 2>&1 && timeout_bin="timeout"
  command -v gtimeout >/dev/null 2>&1 && timeout_bin="gtimeout"

  local rc=0
  if [[ -n "$timeout_bin" ]]; then
    "$timeout_bin" "$COMMAND_TIMEOUT" bash -c "$ATTENTION_COMMAND" >>"$LOG_FILE" 2>&1 || rc=$?
  else
    bash -c "$ATTENTION_COMMAND" >>"$LOG_FILE" 2>&1 || rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    log INFO "attention command completed successfully"
  else
    log ERROR "attention command failed (exit $rc), continuing anyway"
  fi
  return 0
}

trigger_attention() {
  local session_id="$1"
  log INFO "session=$session_id timeout reached, no response — triggering attention"
  run_attention_command
  play_sound
  log INFO "session=$session_id attention sequence complete; permission prompt still awaiting user response"
}
