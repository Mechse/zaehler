# zaehler

Track Claude API token usage per request, locally.

`zaehler` (binary: `zlr`) is a small daemon that sits between your AI tools and
the Anthropic API and logs the exact token usage of every call to a local
SQLite database. Nothing leaves your machine besides the request itself, which
was going to Anthropic anyway.

```
   Claude Code  ──┐
   curl / SDK   ──┼──→  zlr daemon ──HTTPS──→  api.anthropic.com
   anything     ──┘     (localhost:8765)
                              │
                              └──→  ~/.zaehler/zaehler.db
```

The proxy streams responses chunk-by-chunk (zero added latency), parses the
`usage` block out of the SSE stream, and writes one row per call. Read commands
let you summarize spend without ever opening a billing dashboard.

## Why

Claude Code (and most AI tools) hide what they're actually spending. A "quick
question" can be 5+ API calls when you factor in title generation, retries,
and context refreshes. Real cost is opaque until your monthly bill arrives.

`zaehler` makes spend visible *as it happens*, with exact ground-truth numbers
from Anthropic's own `usage` blocks — including the cache-create / cache-read
split that affects pricing dramatically but isn't reported anywhere else.

## Status

MVP. Works for the streaming `/v1/messages` endpoint used by Claude Code and
the official Anthropic SDKs. Anthropic-only. macOS and Linux.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/main/install.sh | bash
```

The script:

1. Verifies Odin, OpenSSL, and SQLite are present (and tells you how to
   install whichever is missing).
2. Builds the binary from source.
3. Installs `zlr` to `~/.local/bin/zlr`.

If you want to install manually:

```bash
git clone https://github.com/Mechse/zaehler.git
cd zaehler
./build.sh
cp zlr ~/.local/bin/
```

### Requirements

- **Odin** — install from <https://odin-lang.org/docs/install/>, or
  `brew install odin` on macOS.
- **OpenSSL 3** — `brew install openssl@3` (macOS) or `apt install libssl-dev`
  (Debian/Ubuntu). The proxy makes HTTPS calls to Anthropic.
- **SQLite 3** — ships with macOS; `apt install libsqlite3-0` on Debian/Ubuntu.

## Use

Start the daemon:

```bash
zlr daemon
```

Point your AI tools at it:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8765
```

Claude Code, the Anthropic Python/TS SDKs, and any client that respects
`ANTHROPIC_BASE_URL` will now route through the proxy. Use them normally —
the daemon forwards every request unchanged.

In another terminal:

```
$ zlr today
today: 47 calls
  input:        12,453
  output:       8,891
  cache_create: 2,104
  cache_read:   54,955

$ zlr tail 5
2026-05-30 09:31:12  in=12  out=251  cache=552/54955  claude-opus-4-7  /v1/messages?beta=true
2026-05-30 09:31:15  in=2   out=88   cache=0/0        claude-opus-4-7  /v1/messages?beta=true
...
```

The raw database is at `~/.zaehler/zaehler.db`; query it directly with `sqlite3`
if you want shapes the built-in commands don't cover.

## What gets logged

Per request, one row with: timestamp, model, endpoint, input tokens, output
tokens, cache-create tokens, cache-read tokens, and bytes streamed. Requests
without a usage block (health checks, errors) are skipped.

**Not logged**: prompt content, response content, your API key, anything you
sent. The proxy only reads the four numeric `usage` fields from the response.

## What doesn't work

- **Non-streaming responses.** Currently relies on the `message_start` /
  `message_delta` SSE events to find the usage block. JSON-mode responses
  would need a separate parser.
- **OpenAI-compatible endpoints.** Anthropic-only for now; the response
  schema differs.
- **Tools that bypass `ANTHROPIC_BASE_URL`.** Claude.ai web, GitHub Copilot,
  and Cursor's first-party mode don't route through a base URL; nothing to
  intercept.

## How it works

The proxy is straightforward:

1. Accepts a TCP connection on `localhost:8765`.
2. Reads the full HTTP request (headers + `Content-Length` body).
3. Rewrites `Host:` to `api.anthropic.com`, drops `Connection: keep-alive`
   and `Accept-Encoding: gzip` so the upstream sends plain SSE.
4. Opens TLS to `api.anthropic.com:443` (hand-rolled OpenSSL bindings,
   SNI included).
5. Forwards the request, then streams the response back chunk-by-chunk while
   tee'ing into a side buffer.
6. Parses `"input_tokens":`, `"output_tokens":`, `"cache_creation_input_tokens":`,
   `"cache_read_input_tokens":`, and `"model":` out of the captured body.
7. Inserts one row into SQLite.

~1100 lines of Odin total.

## License

Elastic License v2 — see [LICENSE](./LICENSE).

You can use, modify, and redistribute this code freely. You **cannot**
provide it as a hosted/managed service to third parties.
