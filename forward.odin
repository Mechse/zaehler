package main

import "core:c"
import "core:fmt"
import "core:net"
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

// forward_to_anthropic does the full outbound trip and streams the response
// directly back to the client socket. No big buffer; each chunk we read from
// Anthropic gets immediately written to Claude Code.
//
//   phase 1: rewrite Host + Connection headers
//   phase 2: DNS resolve + TCP dial
//   phase 3: TLS handshake
//   phase 4: send request, then STREAM the response chunk-by-chunk
//
// Returns the total bytes streamed (for logging) and an error code.
forward_to_anthropic :: proc(
	req: HTTP_Request,
	client: net.TCP_Socket,
) -> (
	bytes_streamed: int,
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
	//   3. Otherwise, write that chunk straight to the client.
	//
	// No buffer holding the full response — chunks arrive and leave.
	tmp: [8192]u8
	for {
		ret := SSL_read(ssl, raw_data(tmp[:]), c.int(len(tmp)))
		if ret <= 0 {
			break
		}

		chunk := tmp[:ret]
		bytes_streamed += int(ret)

		// Forward immediately. send_tcp may also write less than asked,
		// so we loop until the whole chunk is delivered.
		sent := 0
		for sent < int(ret) {
			n, send_err := net.send_tcp(client, chunk[sent:])
			if send_err != nil {
				err = .Client_Write_Failed
				return
			}
			sent += n
		}
	}

	SSL_shutdown(ssl)
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
