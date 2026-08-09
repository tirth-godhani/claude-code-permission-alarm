# Permission Timeout & Attention Reminder

A Claude Code hook that notices when Claude is blocked waiting for your
permission or input, gives you 10 seconds to respond, and — only if you
don't — plays a sound and runs a command to get your attention. It never
answers the prompt for you.

## What it does

```
Claude Code shows a permission prompt (Allow/Deny, Yes/No, tool approval, ...)
        |
        v
  PermissionDetector: PermissionRequest / Notification hook fires
        |
        v
  PermissionTimeoutManager: starts a per-session countdown (default 10s)
        |
   did you respond?
   (a PreToolUse/PermissionDenied hook fires for the same session)
        |
   +----+----+
   |         |
  yes        no
   |         |
 cancel    timeout reached
   |         |
   |    AttentionManager
   |     +-- run ATTENTION_COMMAND
   |     +-- play ATTENTION_SOUND
   |         |
   v         v
   Claude Code is still waiting for your actual answer, either way.
```

The reminder is purely observational. It logs, makes noise, and gets out of
the way — it never sends input to Claude Code, never presses Enter, and
never selects Yes/No/Allow/Deny on your behalf.

## Architecture

```
bin/permission-hook.sh   PermissionDetector + dispatcher. Invoked directly by
                          Claude Code. Reads the hook JSON once, classifies it,
                          and returns in milliseconds. Never prints to stdout
                          (stdout on a PermissionRequest hook is parsed by
                          Claude Code as a decision payload -- this tool must
                          never touch that channel).

lib/timer.sh              PermissionTimeoutManager. The detached worker that
                          actually waits out the countdown and fires the
                          reminder. Runs after the hook has already exited, so
                          Claude Code's process is never blocked.

lib/attention.sh          AttentionManager. Plays ATTENTION_SOUND (afplay,
                          falling back to a bundled macOS system sound),
                          optionally boosted via afplay gain and a temporary
                          system-volume raise (restored right after), and
                          runs ATTENTION_COMMAND (bash -c, with a watchdog
                          timeout). Both independently toggleable, and both
                          fail closed -- a missing file or a failing command
                          is logged and swallowed, never crashes anything.

lib/common.sh              Config loading (env > config.env > built-in
                          default), logging, and the mkdir-based lock/
                          activity-file primitives everything else uses.

lib/idle.sh                Physical idle-time detection (macOS IOHIDSystem).
                          The single platform-specific seam; see "Linux/
                          Windows" below.
```

Locking is a per-`session_id` atomic `mkdir`, acquired **synchronously in the
hook process** (a single syscall, sub-millisecond) before the worker is
backgrounded — not inside the worker itself. Acquiring it asynchronously
would leave a race window where two rapid-fire hook invocations for the same
prompt could both see "no timer running" and each spawn one. The lock records
the worker's PID (not the hook's, which exits almost immediately by design)
so a later invocation can tell a genuinely-still-running timer from an
abandoned one.

## Detection: how "waiting for permission" is recognized

This registers on Claude Code's structured hook events, not text-scraped
terminal output:

- **`PermissionRequest`** — fires when a tool call needs a permission
  decision. Always treated as a wait event.
- **`Notification`** with `notification_type` in `permission_prompt`,
  `idle_prompt`, or `agent_needs_input` — Claude Code's own reactive
  notification classification, matched via the `matcher` field in
  `settings.json`, not by parsing the free-text `message`.

"You responded" is detected the same structured way: a `PreToolUse` firing
again for that `session_id` means the tool was approved and is about to run;
`PermissionDenied` means you said no. Either way, that's forward progress in
Claude Code's own event stream, so it's treated as a response and the timer
is cancelled. `PostToolUse`, `UserPromptSubmit`, `Stop`, and `SubagentStop`
are also treated as activity signals as a broader safety net.

There's a second, **opt-in** cancellation path: `ENABLE_IDLE_FALLBACK_CANCEL`
also cancels on physical keyboard/mouse input (macOS `IOHIDSystem`). It's off
by default — on a machine you're actively using for something else, any
keystroke anywhere would cancel the reminder even though you never looked at
the actual prompt. The hook-activity signal is precise and always on; this is
purely a backup for people who want "any sign of life" behavior instead.

If your Claude Code version emits different field names, set
`DEBUG_LOG_PAYLOAD=true` in `config.env` to dump the raw JSON of every hook
event to the log file, so you can see exactly what's available and adjust
`bin/permission-hook.sh`'s classification if needed.

## Installation

Requires `jq` (used by both the hook and the installer) and `afplay`
(preinstalled on macOS). `osascript` (also preinstalled) is used only for the
optional `FORCE_SYSTEM_VOLUME` feature. No other dependencies, nothing to
install beyond `jq` if it's missing.

```bash
./install.sh              # registers hooks in ~/.claude/settings.json
./install.sh --project    # registers hooks in ./.claude/settings.json instead
```

`install.sh` backs up your existing `settings.json` before writing, strips
any prior entries for this script before re-adding (safe to re-run after an
upgrade or a path change), and validates the resulting JSON before saving it.

```bash
./uninstall.sh             # or --project, matching how you installed
```

removes only this tool's hook entries; every other hook you have configured
is left untouched.

## Configuration

Edit `config.env` directly — every value has an inline comment and a
built-in default in `lib/common.sh`, so a missing or partially-edited file
never breaks anything.

```env
PERMISSION_TIMEOUT=10
ATTENTION_SOUND=./assets/attention.mp3
ATTENTION_COMMAND=
ENABLE_ATTENTION_SOUND=true
ENABLE_ATTENTION_COMMAND=true
ATTENTION_SOUND_GAIN=1.5
FORCE_SYSTEM_VOLUME=true
SYSTEM_VOLUME_LEVEL=85
POLL_INTERVAL=0.5
COMMAND_TIMEOUT=15
LOG_FILE=./logs/permission-alarm.log
STATE_DIR=./state
DEBUG_LOG_PAYLOAD=false
ENABLE_IDLE_FALLBACK_CANCEL=false
```

- **Timeout**: change `PERMISSION_TIMEOUT` to any integer number of seconds
  (e.g. `20`, `30`) — no code changes needed.
- **Sound**: point `ATTENTION_SOUND` at any file `afplay` can play (mp3,
  aiff, wav, ...). Ships pointing at `assets/attention.mp3`. Relative paths
  resolve from the project root. If the file is missing, it falls back to a
  bundled macOS system sound rather than failing silently or crashing.
- **Loudness**: two independent levers, both on by default.
  `ATTENTION_SOUND_GAIN` boosts the sound file itself via `afplay -v` (1.0 is
  unity; pushing much past ~2 just clips/distorts rather than getting
  louder). `FORCE_SYSTEM_VOLUME` + `SYSTEM_VOLUME_LEVEL` temporarily raise
  macOS's system-wide output volume right before playback and restore your
  exact previous level immediately after — so a quiet system volume can't
  quietly defeat the reminder. Set `FORCE_SYSTEM_VOLUME=false` if you'd
  rather this tool never touch your system volume, even briefly.
- **Command**: `ATTENTION_COMMAND` runs via `bash -c`, so normal shell syntax
  works. It is operator-supplied configuration, not built from any hook
  payload data — nothing from Claude's tool calls or prompt text is ever
  interpolated into it, so there's no shell-injection path from untrusted
  input. Runs under a `COMMAND_TIMEOUT`-second watchdog so a hung command
  can't leak a process. Example:
  ```env
  ATTENTION_COMMAND=osascript -e 'display notification "Claude Code is waiting for you" with title "Permission needed"'
  ```

Precedence is: an explicit environment variable (as the test suite uses) >
`config.env` > the built-in default.

## Supported operating systems

macOS only, currently. The single platform-specific piece is `idle_secs()`
in `lib/idle.sh` (reads `ioreg -c IOHIDSystem`), used only by the optional
`ENABLE_IDLE_FALLBACK_CANCEL` path — everything else (hook dispatch, timer,
locking, sound via `afplay`, command execution) is portable bash. A
Linux/Windows port needs: (1) an `idle_secs()` replacement (`xprintidle` on
X11, or simply leave the fallback path disabled), and (2) a sound-playback
substitute for `afplay` in `lib/attention.sh` (e.g. `paplay`/`aplay` on
Linux, or a PowerShell `SoundPlayer` call on Windows).

## Example usage

```bash
./install.sh
# ... edit config.env: set ATTENTION_COMMAND, or swap assets/attention.mp3 for your own sound ...
./tests/run-tests.sh   # verify everything works, no real audio/commands run
```

That's it — there's no server or daemon to start. Once installed, the hook
fires automatically whenever Claude Code shows a permission prompt.

## Troubleshooting

- **Nothing happens on a permission prompt.** Confirm the hook is registered:
  `jq '.hooks.PermissionRequest' ~/.claude/settings.json`. Set
  `DEBUG_LOG_PAYLOAD=true` and check `logs/permission-alarm.log` for a
  `permission wait detected` line the next time a prompt appears — if it's
  missing, your Claude Code version may be emitting a different
  `hook_event_name`/`notification_type` than expected; the debug payload
  will show you the actual field names to adjust in
  `bin/permission-hook.sh`.
- **Sound doesn't play.** Check the log for `sound playback failed` — most
  commonly a bad `ATTENTION_SOUND` path or macOS's system-wide "silent"
  toggle. Test directly: `afplay ./assets/attention.mp3`.
- **Command doesn't run.** Check the log for `attention command failed
  (exit N)` — the exit code is logged. Test it standalone first:
  `bash -c "$ATTENTION_COMMAND"`.
- **Reminder never fires even though you didn't respond.** If you've enabled
  `ENABLE_IDLE_FALLBACK_CANCEL`, any physical input anywhere on the machine
  cancels the timer — that's expected behavior for that opt-in mode; leave
  it off (default) if you want cancellation tied only to actually answering
  the prompt.
- **Stale lock after a crash.** `acquire_lock` in `lib/common.sh` checks
  whether the PID recorded in a lock is still alive before treating it as
  stale and reclaiming it, so this self-heals on the next prompt. To force
  it, `rm -rf state/<session_id>.lock`.

## Security considerations

- **Never influences the actual decision.** The hook script never emits the
  `hookSpecificOutput.decision` payload Claude Code looks for on
  `PermissionRequest` — it only logs and exits 0. There is no code path in
  this tool that can allow, deny, or otherwise answer a prompt.
- **`ATTENTION_COMMAND` is trusted, operator-supplied config** — you write
  it, it runs via `bash -c` with normal shell semantics. Treat it like any
  other line in your shell profile: don't paste in commands from untrusted
  sources. No data from Claude's tool calls, prompts, or output is ever
  interpolated into it.
- **Fails closed, never fails loud.** A missing sound file, a failing
  attention command, a malformed hook payload, or an unreadable config all
  degrade to "the reminder doesn't fire this time" — never to a crashed hook
  or a blocked Claude Code session.
- **`FORCE_SYSTEM_VOLUME` changes your real macOS output volume, briefly.**
  It reads your current level before changing it and restores that exact
  value immediately after playback (even if playback fails partway through),
  so it's self-limiting and never permanent — but it is a real, visible
  system-wide side effect while it's in progress. Set it to `false` if you
  don't want this tool touching system volume at all.

## Testing

```bash
./tests/run-tests.sh
```

Runs 15 scenarios end-to-end against the real hook script and worker, using
`PERMISSION_ALARM_DRY_RUN=1` throughout so no real audio ever plays, no real
command ever runs, and your actual macOS system volume is never touched
(two scenarios that specifically test failure-handling call
`lib/attention.sh` functions directly with a trivial, safe mock like
`false`, still never a real background worker or real playback). Covers:
detection, cancellation before timeout, cancellation exactly at the
boundary, both attention actions firing on timeout, each independently
toggled off, a missing sound file, a failing command, two sessions handled
independently, self-cleanup with no supervising parent, configurable
timeout values, no duplicate timers on repeated prompts, the opt-in
idle-cancellation path, and malformed/unrelated events being ignored.

## Limitations & edge cases

- **Remote/SSH sessions**: the optional idle-fallback path reads local
  macOS HID state, which doesn't reflect keystrokes typed over SSH into a
  remote Claude Code session. It's off by default for this and the false-
  positive reason above; the hook-activity signal works regardless of
  where you're typing.
- **Exact `PermissionRequest`/`Notification` field names** are not fully
  pinned down across every Claude Code version in the public docs at the
  time this was built. `DEBUG_LOG_PAYLOAD=true` exists specifically so you
  can confirm the fields your installed version actually sends.
- **Multiple concurrent Claude Code sessions** are handled independently
  (state is keyed by `session_id`), but they currently share one
  `STATE_DIR`/`LOG_FILE` — fine for a single machine, just means the log
  interleaves sessions.
