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
export ANTHROPIC_BASE_URL=http://localhost:8765    # route tools through it

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

| Tool                          | Supported  | Notes                                              |
| ----------------------------- | ---------- | -------------------------------------------------- |
| Claude Code                   | ✅ yes     | works out of the box with `ANTHROPIC_BASE_URL`     |
| Anthropic Python SDK          | ✅ yes     | respects `ANTHROPIC_BASE_URL`                      |
| Anthropic TypeScript SDK      | ✅ yes     | respects `ANTHROPIC_BASE_URL`                      |
| Direct Anthropic REST calls   | ✅ yes     | curl, custom scripts, etc.                         |
| OpenAI / Codex CLI            | ❌ not yet | different API schema; would need a separate parser |
| Cursor (own backend mode)     | ❌ no      | doesn't route through `ANTHROPIC_BASE_URL`         |
| GitHub Copilot                | ❌ no      | doesn't route through `ANTHROPIC_BASE_URL`         |
| Claude.ai web                 | ❌ no      | browser traffic, no env var to intercept           |

### Features

| Feature                                | Supported  | Notes                                              |
| -------------------------------------- | ---------- | -------------------------------------------------- |
| Streaming responses (SSE)              | ✅ yes     | the common case for Claude Code                    |
| Token usage logging                    | ✅ yes     | input, output, cache-create, cache-read            |
| Background daemon (start/stop)         | ✅ yes     | double-fork, survives terminal close               |
| Daily / recent summaries (today, tail) | ✅ yes     | reads from local SQLite                            |
| Non-streaming JSON responses           | ❌ not yet | parser is SSE-only                                 |
| Multi-request concurrency              | ❌ not yet | handles one request at a time                      |
| Per-commit attribution                 | ❌ not yet | scoped out of MVP                                  |
| Cost estimation (€/$ per call)         | ❌ not yet | tokens are logged, pricing isn't applied           |
| CSV / JSON export                      | ❌ not yet | query SQLite directly for now                      |

## Requirements

- **Odin** — `brew install odin` (macOS) or <https://odin-lang.org/docs/install/>
- **OpenSSL 3** — `brew install openssl@3` (macOS) or `apt install libssl-dev` (Debian/Ubuntu)
- **SQLite 3** — ships with macOS; `apt install libsqlite3-0` (Debian/Ubuntu)

## License

[Elastic License v2](./LICENSE). Free for personal and internal use; you may
not offer it as a hosted service.
