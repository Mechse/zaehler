package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

UPSTREAM_HOST :: "api.anthropic.com"
UPSTREAM_PORT :: 443

// Forward_Error names the small fixed set of failure modes in the
// outbound trip to Anthropic. .None means success.
Forward_Error :: enum {
	None,
	DNS_Failed,
	Connect_Failed,
	TLS_Setup_Failed,
	TLS_Handshake_Failed,
	Write_Failed,
	Read_Failed,
	Client_Write_Failed,
}

// Usage holds the token counts we parse out of the upstream response.
// All zero means "we didn't find it" — Anthropic may have responded with
// an error and no usage block, or the request wasn't a /v1/messages call.
Usage :: struct {
	model:                       string,
	input_tokens:                int,
	output_tokens:               int,
	cache_creation_input_tokens: int,
	cache_read_input_tokens:     int,
}

// parse_usage scans a captured response body for the four numeric fields we
// care about. It is NOT a real JSON parser; it just looks for the literal
// "key":N pattern and pulls N out. That's safe here because:
//   - Anthropic emits each field at most once across the whole stream
//     (input/cache numbers in message_start, output in message_delta).
//   - Field names are unique enough that they don't appear elsewhere.
//   - The numbers are always integers — no escaping concerns.
//
// If the response is plain text or an error, most fields stay 0.
parse_usage :: proc(body: []u8) -> Usage {
	u: Usage
	text := string(body)

	u.input_tokens = find_int_field(text, "\"input_tokens\":")
	u.output_tokens = find_int_field(text, "\"output_tokens\":")
	u.cache_creation_input_tokens = find_int_field(text, "\"cache_creation_input_tokens\":")
	u.cache_read_input_tokens = find_int_field(text, "\"cache_read_input_tokens\":")
	u.model = find_string_field(text, "\"model\":")

	return u
}

// find_int_field finds the FIRST occurrence of `key` in `text` and parses
// the integer that follows (after optional whitespace). Returns 0 if the
// key isn't present or the value isn't a valid integer.
//
// For the streaming case, only the FIRST occurrence matters: input_tokens
// and cache_* are emitted exactly once in the message_start event; for
// output_tokens, Anthropic streams an initial 0 in message_start and the
// final count in message_delta — so we actually want the LAST one. We
// handle that specially below.
find_int_field :: proc(text: string, key: string) -> int {
	if key == "\"output_tokens\":" {
		return find_int_field_last(text, key)
	}
	idx := strings.index(text, key)
	if idx == -1 {return 0}
	return parse_int_at(text, idx + len(key))
}

find_int_field_last :: proc(text: string, key: string) -> int {
	// Walk forward, tracking the most recent occurrence.
	last := -1
	rest := text
	offset := 0
	for {
		i := strings.index(rest, key)
		if i == -1 {break}
		last = offset + i
		// advance past this match
		offset += i + len(key)
		rest = rest[i + len(key):]
	}
	if last == -1 {return 0}
	return parse_int_at(text, last + len(key))
}

parse_int_at :: proc(text: string, start: int) -> int {
	// Skip leading whitespace
	i := start
	for i < len(text) && (text[i] == ' ' || text[i] == '\t') {i += 1}

	// Find end of the integer (digits only)
	j := i
	for j < len(text) && text[j] >= '0' && text[j] <= '9' {j += 1}
	if j == i {return 0}

	n, _ := strconv.parse_int(text[i:j])
	return n
}

// forward_to_anthropic does the full outbound trip and streams the response
// directly back to the client socket. As chunks fly through, it also
// accumulates them into a side buffer so we can parse the upstream's token
// usage when streaming finishes.
//
//   phase 1: rewrite Host + Connection + Accept-Encoding headers
//   phase 2: DNS resolve + TCP dial
//   phase 3: TLS handshake
//   phase 4: send request, then STREAM the response chunk-by-chunk
//   phase 5: parse token usage from the captured body
//
// Returns the total bytes streamed, the parsed Usage, and an error code.
forward_to_anthropic :: proc(
	req: HTTP_Request,
	client: net.TCP_Socket,
) -> (
	bytes_streamed: int,
	usage: Usage,
	err: Forward_Error,
) {

	// ----- Phase 1: rewrite the request --------------------------------------

	rewritten := rewrite_request_for_upstream(req)

	// ----- Phase 2: DNS resolve + TCP dial -----------------------------------

	endpoint, dns_err := net.resolve_ip4(UPSTREAM_HOST)
	if dns_err != nil {
		err = .DNS_Failed
		return
	}
	endpoint.port = UPSTREAM_PORT

	tcp_socket, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {
		err = .Connect_Failed
		return
	}
	defer net.close(tcp_socket)

	// ----- Phase 3: TLS setup + handshake ------------------------------------

	ctx := SSL_CTX_new(TLS_client_method())
	if ctx == nil {
		err = .TLS_Setup_Failed
		return
	}
	defer SSL_CTX_free(ctx)

	ssl := SSL_new(ctx)
	if ssl == nil {
		err = .TLS_Setup_Failed
		return
	}
	defer SSL_free(ssl)

	SSL_set_fd(ssl, c.int(tcp_socket))

	// SNI: required for any server behind a CDN like Cloudflare.
	host_c := strings.clone_to_cstring(UPSTREAM_HOST, context.temp_allocator)
	SSL_set_tlsext_host_name(ssl, host_c)

	if SSL_connect(ssl) != 1 {
		err = .TLS_Handshake_Failed
		return
	}

	// ----- Phase 4: write request, stream response --------------------------

	// Write the whole rewritten request. SSL_write may write less than asked,
	// so we loop until everything is on the wire.
	to_write := len(rewritten)
	written := 0
	for written < to_write {
		ret := SSL_write(ssl, raw_data(rewritten[written:]), c.int(to_write - written))
		if ret <= 0 {
			err = .Write_Failed
			return
		}
		written += int(ret)
	}

	// THE STREAMING LOOP.
	//
	// Each iteration:
	//   1. Read a chunk from Anthropic (SSL_read).
	//   2. If it's empty/negative, the upstream is done. Exit.
	//   3. Append the chunk to a side buffer (for usage parsing later).
	//   4. Write that chunk straight to the client (real streaming).
	//
	// The side buffer holds the whole uncompressed response. Typical
	// Claude Code responses are 10-30 KB — trivial. We'd revisit this
	// if we ever streamed huge responses.
	resp_capture: [dynamic]u8
	resp_capture.allocator = context.temp_allocator

	tmp: [8192]u8
	for {
		ret := SSL_read(ssl, raw_data(tmp[:]), c.int(len(tmp)))
		if ret <= 0 {
			break
		}
		n_read := int(ret)

		chunk := tmp[:n_read]
		bytes_streamed += n_read

		// Tee: accumulate for parsing, also forward.
		append(&resp_capture, ..chunk)

		// Forward immediately. send_tcp may also write less than asked,
		// so we loop until the whole chunk is delivered.
		sent := 0
		for sent < n_read {
			n, send_err := net.send_tcp(client, chunk[sent:])
			if send_err != nil {
				err = .Client_Write_Failed
				return
			}
			sent += n
		}
	}

	SSL_shutdown(ssl)

	// ----- Phase 5: parse usage from the captured body ----------------------

	usage = parse_usage(resp_capture[:])
	return
}

// rewrite_request_for_upstream copies the request, swapping in:
//   - Host: api.anthropic.com
//   - Connection: close (overriding any keep-alive)
// All other headers and the body pass through untouched.
// Returned bytes are allocated in the temp allocator.
rewrite_request_for_upstream :: proc(req: HTTP_Request) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)

	// Request line, unchanged.
	fmt.sbprintf(&sb, "%s %s %s\r\n", req.method, req.path, req.version)

	// Iterate headers. Skip the request line we already wrote; rewrite
	// Host; drop Connection (we add our own at the end); keep everything else.
	headers := string(req.raw[:req.header_end])
	remaining := headers

	if i := strings.index(remaining, "\r\n"); i != -1 {
		remaining = remaining[i + 2:]
	}

	for len(remaining) > 0 {
		line: string
		if i := strings.index(remaining, "\r\n"); i != -1 {
			line = remaining[:i]
			remaining = remaining[i + 2:]
		} else {
			line = remaining
			remaining = ""
		}
		if len(line) == 0 {continue}

		colon := strings.index_byte(line, ':')
		if colon == -1 {
			fmt.sbprintf(&sb, "%s\r\n", line)
			continue
		}

		name_lower := strings.to_lower(line[:colon], context.temp_allocator)
		switch name_lower {
		case "host":
			fmt.sbprintf(&sb, "Host: %s\r\n", UPSTREAM_HOST)
		case "connection":
		// drop; replaced below
		case "accept-encoding":
		// drop; we want plain text responses so we can parse the
		// SSE usage block. Anthropic will respond uncompressed.
		case:
			fmt.sbprintf(&sb, "%s\r\n", line)
		}
	}

	fmt.sbprintf(&sb, "Connection: close\r\n")
	fmt.sbprintf(&sb, "\r\n")

	// Append body bytes verbatim.
	headers_str := strings.to_string(sb)
	body_start := req.header_end + 4
	body := req.raw[body_start:]

	result := make([]u8, len(headers_str) + len(body), context.temp_allocator)
	copy(result, transmute([]u8)headers_str)
	copy(result[len(headers_str):], body[:])

	return result
}

// send_bad_gateway tells the client we couldn't reach upstream.
// 502 is the standard HTTP status for "I'm a proxy and the thing I'm
// proxying to is broken."
send_bad_gateway :: proc(client: net.TCP_Socket, reason: Forward_Error) {
	body := fmt.tprintf("zaehler: forward failed: %v\n", reason)
	response := fmt.tprintf(
		"HTTP/1.1 502 Bad Gateway\r\n" +
		"Content-Type: text/plain\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: close\r\n" +
		"\r\n" +
		"%s",
		len(body),
		body,
	)
	net.send_tcp(client, transmute([]u8)response)
}

// find_string_field finds the first `"key":` and returns the string literal
// that follows (between the next pair of double quotes). Returns "" on miss.
find_string_field :: proc(text: string, key: string) -> string {
	idx := strings.index(text, key)
	if idx == -1 {return ""}

	// Skip past key and any whitespace
	i := idx + len(key)
	for i < len(text) && (text[i] == ' ' || text[i] == '\t') {i += 1}
	if i >= len(text) || text[i] != '"' {return ""}
	i += 1

	// Find the closing quote
	j := i
	for j < len(text) && text[j] != '"' {j += 1}
	if j >= len(text) {return ""}

	return strings.clone(text[i:j], context.temp_allocator)
}
