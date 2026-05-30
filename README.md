# zaehler

Track API token usage per request, locally.

zaehler (binary: `zlr`) is a small daemon that sits between your AI tools and
the AI API's (Claude, Codex, Gemini, ...). It logs the exact token usage of every call to a local
SQLite database. Nothing leaves your machine besides the request itself, which
was going to Anthropic anyway.

<img width="534" height="720" alt="export-1780166108966" src="https://github.com/user-attachments/assets/223c24f5-41c7-49bf-8d49-8b412bd68e71" />

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/master/install.sh | bash
```

## Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/master/uninstall.sh | bash
```

## Use

```bash
zlr start                                          # start the daemon

zlr today    # today's totals
zlr tail     # last 20 calls

zlr stop     # stop the daemon
```

## Compatibility

### Operating systems

| OS      | Supported  | 
| ------- | ---------- |
| macOS   | ✅ yes     |
| Linux   | ✅ yes     |
| Windows | ❌ no      |

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
