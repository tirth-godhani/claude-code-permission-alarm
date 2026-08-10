# Security Policy

## Scope

This project is a local macOS shell tool that hooks into Claude Code to play
a sound (and optionally run a command you configure) when a permission
prompt goes unanswered. It does not run a server, does not handle user
accounts, and does not transmit data anywhere except the one-time download
of the tool itself during install.

The two places most worth scrutiny if you're auditing this code:

- `lib/attention.sh`'s `run_attention_command()` — runs your own
  `ATTENTION_COMMAND` from `config.env` via `bash -c`. This is intentional,
  operator-controlled configuration (the same trust boundary as a line in
  your `.bashrc`), not something built from any hook payload, tool call, or
  model output.
- `bin/permission-hook.sh` — reads the `session_id` field from Claude Code's
  own hook JSON and validates it against `^[A-Za-z0-9_-]+$` before using it
  in a file path or an embedded `bash -c` invocation.

## Reporting a vulnerability

If you find a genuine security issue (not a general bug — see
[CONTRIBUTING.md](CONTRIBUTING.md) for those), please report it privately
rather than opening a public issue:

**[Open a private security advisory](https://github.com/tirth-godhani/claude-code-permission-alarm/security/advisories/new)**

Include what you found, how to reproduce it, and what you think the impact
is. This is a small project maintained in spare time, so please allow a
reasonable window for a response and a fix before any public disclosure.
