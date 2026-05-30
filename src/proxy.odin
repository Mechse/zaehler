package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"

// run_proxy starts the TCP listener and handles connections one at a time.
// Logs every forwarded API call to ~/.zaehler/zaehler.db.
run_proxy :: proc(port: int) -> net.Network_Error {
	// Open the SQLite database before we start listening. If this fails
	// the daemon won't be useful, so we abort early.
	if !store_open() {
		fmt.eprintln("zlr: failed to open store; aborting")
		os.exit(1)
	}
	defer store_close()

	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = port,
	}

	listener := net.listen_tcp(endpoint) or_return
	defer net.close(listener)

	fmt.printfln("zlr daemon listening on http://127.0.0.1:%d", port)
	fmt.println("point your tools at it with:")
	fmt.printfln("  export ANTHROPIC_BASE_URL=http://localhost:%d", port)

	for {
		client, source, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			fmt.eprintln("zlr: accept failed:", accept_err)
			continue
		}
		handle_connection(client, source)
	}
}

handle_connection :: proc(client: net.TCP_Socket, source: net.Endpoint) {
	defer net.close(client)
	defer free_all(context.temp_allocator)

	fmt.printfln("--- connection from %v ---", source)

	req, read_err := read_request(client)
	defer destroy_request(&req)

	if read_err != .None {
		fmt.eprintln("zlr: read_request failed:", read_err)
		return
	}

	print_redacted(req)

	bytes, usage, fwd_err := forward_to_anthropic(req, client)
	if fwd_err != .None {
		fmt.eprintln("zlr: forward failed:", fwd_err)
		if fwd_err != .Client_Write_Failed {
			send_bad_gateway(client, fwd_err)
		}
		return
	}

	fmt.printfln(
		"streamed %d bytes  |  in: %d  out: %d  cache_create: %d  cache_read: %d",
		bytes,
		usage.input_tokens,
		usage.output_tokens,
		usage.cache_creation_input_tokens,
		usage.cache_read_input_tokens,
	)


	// Persist the call. Skip rows where ALL token counts are zero
	// (health checks, errors, HEAD probes — they don't contribute to spend).
	if has_usage(usage) {
		ts := time.time_to_unix(time.now())
		store_insert_call(ts, usage.model, req.path, usage, bytes)
	}
}

has_usage :: proc(u: Usage) -> bool {
	return(
		u.input_tokens > 0 ||
		u.output_tokens > 0 ||
		u.cache_creation_input_tokens > 0 ||
		u.cache_read_input_tokens > 0 \
	)
}
