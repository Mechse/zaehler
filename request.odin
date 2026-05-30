package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

MAX_HEADER_SIZE :: 64 * 1024
MAX_BODY_SIZE :: 8 * 1024 * 1024

HTTP_Request :: struct {
	method:         string,
	path:           string,
	version:        string,
	content_length: int,
	header_end:     int,
	raw:            [dynamic]u8,
}

Request_Error :: enum {
	None,
	Network,
	Connection_Closed,
	Headers_Too_Large,
	Malformed_Request_Line,
	Body_Too_Large,
}

// destroy_request frees the underlying buffer AND the cloned strings.
// After this, every string field on req is invalid — don't touch them.
destroy_request :: proc(req: ^HTTP_Request) {
	delete(req.raw)
	delete(req.method)
	delete(req.path)
	delete(req.version)
}

read_request :: proc(client: net.TCP_Socket) -> (req: HTTP_Request, err: Request_Error) {
	tmp: [4096]u8

	header_end := -1
	for header_end == -1 {
		if len(req.raw) >= MAX_HEADER_SIZE {
			err = .Headers_Too_Large
			return
		}

		n, recv_err := net.recv_tcp(client, tmp[:])
		if recv_err != nil {
			err = .Network
			return
		}
		if n == 0 {
			err = .Connection_Closed
			return
		}

		append(&req.raw, ..tmp[:n])
		header_end = find_header_terminator(req.raw[:])
	}
	req.header_end = header_end

	headers := string(req.raw[:header_end])
	if !parse_request_line(headers, &req) {
		err = .Malformed_Request_Line
		return
	}
	req.content_length = parse_content_length(headers)

	if req.content_length > MAX_BODY_SIZE {
		err = .Body_Too_Large
		return
	}

	body_start := header_end + 4
	body_target := body_start + req.content_length

	for len(req.raw) < body_target {
		n, recv_err := net.recv_tcp(client, tmp[:])
		if recv_err != nil {
			err = .Network
			return
		}
		if n == 0 {
			err = .Connection_Closed
			return
		}
		append(&req.raw, ..tmp[:n])
	}

	return
}

// find_header_terminator returns the byte index of "\r\n\r\n" in buf, or -1.
find_header_terminator :: proc(buf: []u8) -> int {
	if len(buf) < 4 {
		return -1
	}
	for i in 0 ..= len(buf) - 4 {
		if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
			return i
		}
	}
	return -1
}

// parse_request_line splits the first line ("POST /path HTTP/1.1") into
// the three fields on req. Returns false if the line is malformed.
//
// IMPORTANT: we CLONE each substring rather than slicing into the buffer.
// req.raw is a dynamic array that may reallocate (and move in memory) during
// subsequent body reads, which would invalidate any pointer into it. The
// cloned strings own their bytes and survive any later realloc.
parse_request_line :: proc(headers: string, req: ^HTTP_Request) -> bool {
	line_end := strings.index(headers, "\r\n")
	if line_end == -1 {
		line_end = len(headers)
	}
	line := headers[:line_end]

	sp1 := strings.index_byte(line, ' ')
	if sp1 == -1 {return false}
	rest := line[sp1 + 1:]
	sp2_rel := strings.index_byte(rest, ' ')
	if sp2_rel == -1 {return false}
	sp2 := sp1 + 1 + sp2_rel

	req.method = strings.clone(line[:sp1])
	req.path = strings.clone(line[sp1 + 1:sp2])
	req.version = strings.clone(line[sp2 + 1:])
	return true
}

// parse_content_length scans headers for "Content-Length: N". Case-insensitive
// header name (HTTP spec); returns 0 if absent or unparsable.
parse_content_length :: proc(headers: string) -> int {
	KEY :: "content-length:"

	lower := strings.to_lower(headers, context.temp_allocator)
	idx := strings.index(lower, KEY)
	if idx == -1 {
		return 0
	}

	after := headers[idx + len(KEY):]
	after = strings.trim_left(after, " \t")

	line_end := strings.index(after, "\r\n")
	if line_end == -1 {
		line_end = len(after)
	}

	n, _ := strconv.parse_int(strings.trim_space(after[:line_end]))
	return n
}

// print_redacted prints a parsed request to stdout with the Authorization
// header value blanked. Use this for diagnostics; never print the raw bytes
// of a request you haven't redacted.
print_redacted :: proc(req: HTTP_Request) {
	fmt.printfln("%s %s %s", req.method, req.path, req.version)

	headers := string(req.raw[:req.header_end])
	remaining := headers
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
		if strings.has_prefix(line, req.method) {continue}

		if colon := strings.index_byte(line, ':'); colon != -1 {
			name := line[:colon]
			lower_name := strings.to_lower(name, context.temp_allocator)
			if lower_name == "authorization" {
				fmt.printfln("%s: [REDACTED]", name)
				continue
			}
		}
		fmt.println(line)
	}

	body_size := len(req.raw) - req.header_end - 4
	fmt.printfln("(body: %d bytes)", body_size)
}
