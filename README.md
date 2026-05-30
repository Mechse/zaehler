# zaehler

Track API token usage per request, locally.

`zaehler` (binary: `zlr`) is a small daemon that sits between your AI tools and
the AI API's (Claude, Codex, Gemini, ...). It logs the exact token usage of every call to a local
SQLite database. Nothing leaves your machine besides the request itself, which
was going to Anthropic anyway.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/main/install.sh | bash
```

## Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/main/uninstall.sh | bash
```

## Use

```bash
zlr start                                          # start the daemon

zlr today    # today's totals
zlr tail     # last 20 calls

zlr stop     # stop the daemon
unset ANTHROPIC_BASE_URL
```

## Compatibility

### Operating systems

| OS      | Supported  | Notes                                              |
| ------- | ---------- | -------------------------------------------------- |
| macOS   | ✅ yes     | tested on Apple Silicon                            |
| Linux   | ✅ yes     | tested on Ubuntu/Debian                            |
| Windows | ❌ no      | daemonization uses POSIX fork; needs separate port |

### AI tools

| Tool                          | Supported  |
| ----------------------------- | ---------- | 
| Claude Code                   | ✅ yes     | 
| Cursor (own backend mode)     | ❌ no      | 
| GitHub Copilot                | ❌ no      | 
| Claude.ai web                 | ❌ no      | 

## Requirements

- **Odin** — `brew install odin` (macOS) or <https://odin-lang.org/docs/install/>
- **OpenSSL 3** — `brew install openssl@3` (macOS) or `apt install libssl-dev` (Debian/Ubuntu)
- **SQLite 3** — ships with macOS; `apt install libsqlite3-0` (Debian/Ubuntu)

## License

[Elastic License v2](./LICENSE). Free for personal and internal use; you may
not offer it as a hosted service.
