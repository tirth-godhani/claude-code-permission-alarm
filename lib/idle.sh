#!/usr/bin/env bash
# Physical idle-time detection. macOS-only (IOHIDSystem) — this is the single
# seam a Linux/Windows port would replace. Sourced, never executed directly.

# idle_secs — seconds since the last physical keyboard/mouse event, system-wide.
# Fails open: returns 999 (assume present/unknown) rather than erroring, so a
# broken read never blocks the timeout logic.
idle_secs() {
  if [[ -n "$PERMISSION_ALARM_IDLE_OVERRIDE_FILE" && -f "$PERMISSION_ALARM_IDLE_OVERRIDE_FILE" ]]; then
    cat "$PERMISSION_ALARM_IDLE_OVERRIDE_FILE" 2>/dev/null || echo 999
    return
  fi
  if [[ -n "$PERMISSION_ALARM_IDLE_OVERRIDE" ]]; then
    printf '%s' "$PERMISSION_ALARM_IDLE_OVERRIDE"
    return
  fi

  local ns
  ns="$(ioreg -c IOHIDSystem 2>/dev/null | awk -F'= ' '/HIDIdleTime/ {print $2; exit}')"
  if [[ -z "$ns" || ! "$ns" =~ ^[0-9]+$ ]]; then
    echo 999
    return
  fi
  echo $((ns / 1000000000))
}
