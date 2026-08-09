#!/usr/bin/env bash
# PermissionTimeoutManager worker. Runs detached, off the hook's critical
# path. One instance per session_id, enforced via acquire_lock. Sourced by
# bin/permission-hook.sh right before it backgrounds this function; never
# executed as its own process.

run_timeout_worker() {
  local session_id="$1"

  # The lock for this session is already held -- bin/permission-hook.sh
  # acquires it synchronously (atomic mkdir) before spawning this worker, to
  # avoid a TOCTOU race between checking and acquiring across process
  # boundaries. This trap guarantees release on normal completion, a signal,
  # or an unexpected error, so an orphaned worker never wedges future prompts.
  trap 'release_lock "$session_id"' EXIT INT TERM

  local start_ms baseline_idle
  start_ms="$(now_ms)"
  baseline_idle="$(idle_secs)"
  mark_activity_at "$session_id" "$start_ms"  # baseline == start_ms; only a later real activity event counts as a response

  log INFO "session=$session_id timer started (${PERMISSION_TIMEOUT}s, baseline_idle=${baseline_idle}s)"

  while true; do
    local now_ms_val elapsed_ms elapsed
    now_ms_val="$(now_ms)"
    elapsed_ms=$((now_ms_val - start_ms))
    elapsed=$((elapsed_ms / 1000))

    if [[ "$elapsed" -ge "$PERMISSION_TIMEOUT" ]]; then
      trigger_attention "$session_id"
      break
    fi

    local last_act
    last_act="$(last_activity_epoch "$session_id")"
    if [[ "$last_act" -gt "$start_ms" ]]; then
      log INFO "session=$session_id user responded after ${elapsed}s (hook activity detected), timer cancelled"
      break
    fi

    if [[ "$ENABLE_IDLE_FALLBACK_CANCEL" == "true" ]]; then
      local cur_idle
      cur_idle="$(idle_secs)"
      if [[ "$cur_idle" =~ ^[0-9]+$ ]] && [[ "$cur_idle" -lt "$elapsed" ]]; then
        log INFO "session=$session_id user responded after ${elapsed}s (physical input detected), timer cancelled"
        break
      fi
    fi

    sleep "$POLL_INTERVAL"
  done

  release_lock "$session_id"
  trap - EXIT INT TERM
}
