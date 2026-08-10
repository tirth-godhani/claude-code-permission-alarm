# Permission Timeout & Attention Reminder

Sometimes Claude Code stops and waits for you to click Allow/Deny, and you
don't notice for a while. This tool fixes that.

If a permission prompt sits unanswered for 10 seconds, it plays a sound (and
can run a command too) to get your attention. It never clicks Allow or Deny
for you — it only makes noise.

## Requirements

- macOS
- `jq` installed (`brew install jq` if you don't have it)

## How to install

**One command — no need to clone this repo first:**

```bash
curl -fsSL https://raw.githubusercontent.com/tirth-godhani/claude-code-permission-alarm/master/get.sh | bash
```

This downloads the tool into `~/.claude-code-permission-alarm` and wires it
into Claude Code for all your projects. Re-running it later upgrades to the
latest version without touching your `config.env` settings.

If you'd rather clone the repo yourself (e.g. to edit the code), that still
works the same way it always did:

```bash
git clone https://github.com/tirth-godhani/claude-code-permission-alarm.git
cd claude-code-permission-alarm
./install.sh              # for all your projects
./install.sh --project    # or, for just the current project
```

## How to uninstall

If you installed with the one-line command above:

```bash
~/.claude-code-permission-alarm/uninstall.sh
rm -rf ~/.claude-code-permission-alarm
```

If you cloned the repo yourself, run `./uninstall.sh` from inside it instead.

Either way, this removes only this tool's settings — anything else you've
configured in Claude Code is left alone.

All the commands below (`config.env`, `tests/run-tests.sh`, etc.) are run
from wherever the tool lives — `~/.claude-code-permission-alarm` if you used
the one-line install, or the folder you cloned into otherwise.

## How to change the sound

1. Get a short sound file you like. [myinstants.com](https://www.myinstants.com/en/index/in/)
   has a big library of free sound effects you can download — or use any
   mp3/aiff/wav you already have.
2. Put the file in the `assets/` folder, e.g. `assets/my-sound.mp3`.
3. Open `config.env` and change this line to point at your file:
   ```env
   ATTENTION_SOUND=./assets/my-sound.mp3
   ```
4. Save the file. That's it — no need to reinstall or restart anything.

## Other settings

Everything is in `config.env`, with a comment above each line explaining it.
The most useful ones:

- `PERMISSION_TIMEOUT=10` — how many seconds to wait before the reminder
  goes off. Change to any number.
- `ATTENTION_SOUND=./assets/attention.mp3` — which sound file plays.
- `ATTENTION_COMMAND=` — an optional extra command to run when the timer
  goes off (e.g. a desktop notification). Leave empty to skip this.
- `ENABLE_ATTENTION_SOUND` / `ENABLE_ATTENTION_COMMAND` — turn the sound or
  the command on/off independently.
- `FORCE_SYSTEM_VOLUME=true` / `SYSTEM_VOLUME_LEVEL=85` — temporarily turns
  your Mac's volume up so the sound isn't missed, then puts it back
  afterward. Set `FORCE_SYSTEM_VOLUME=false` if you don't want this.

## Testing it works

```bash
./tests/run-tests.sh
```

Runs a full check without playing any real sound or touching your system
volume.

## Troubleshooting

- **Nothing happens on a permission prompt.** Check it's installed:
  `jq '.hooks.PermissionRequest' ~/.claude/settings.json` should show
  something. Also check `logs/permission-alarm.log` for recent activity.
- **Sound doesn't play.** Test the file directly:
  `afplay ./assets/attention.mp3`. Check `logs/permission-alarm.log` for an
  error.
- **Command doesn't run.** Check `logs/permission-alarm.log` for the error,
  or test it yourself: `bash -c "$ATTENTION_COMMAND"`.

## Notes

- macOS only, for now.
- Only makes noise — it never answers the permission prompt for you.
