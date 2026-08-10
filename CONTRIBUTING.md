# Contributing

Thanks for considering a contribution. This is a small, pure-Bash project —
there's no build step and no package manager, so getting set up is quick.

## Setup

```bash
git clone https://github.com/tirth-godhani/claude-code-permission-alarm.git
cd claude-code-permission-alarm
./install.sh --project   # installs against this repo's own .claude/settings.json,
                          # so you can develop without touching your real
                          # user-wide Claude Code config
```

Requirements: macOS, `jq`. Nothing else to install.

## Running the tests

```bash
./tests/run-tests.sh          # core hook/timer/attention logic (dry-run, no real audio/commands)
./tests/install-tests.sh      # install.sh/uninstall.sh settings.json merge logic (isolated $HOME)
./tests/remote-install-test.sh # get.sh end-to-end smoke test (needs network; skips if GitHub is unreachable)
```

All three are safe to run repeatedly — none of them touch your real
`~/.claude/settings.json`, play real audio, or run a real `ATTENTION_COMMAND`.

## Making a change

1. Fork the repo and create a branch off `master`.
2. Make your change. Keep functions small and single-purpose, and match the
   existing style: 2-space indent, `set -uo pipefail` (or `-euo pipefail` for
   scripts that mutate real files), and a comment only where the *why* isn't
   obvious from the code itself — not restating what a line does.
3. If you touched `bin/permission-hook.sh`, `lib/*.sh`, `install.sh`, or
   `uninstall.sh`, add a test that would have caught the bug you're fixing or
   exercises the behavior you're adding, in whichever of the three suites
   above fits.
4. Run all three test suites and confirm they pass.
5. Open a PR against `master` with a short description of what changed and
   why. Small, focused PRs are easier to review than large ones.

## Reporting bugs

Open a GitHub issue. Include: your macOS version, whether you installed via
the one-line `get.sh` command or a manual clone, and the relevant lines from
`logs/permission-alarm.log` (set `DEBUG_LOG_PAYLOAD=true` in `config.env`
first if the issue is about detection not firing — it dumps the raw hook
JSON so we can see exactly what Claude Code sent).

## Security issues

Please don't open a public issue for a security concern — see
[SECURITY.md](SECURITY.md) instead.
