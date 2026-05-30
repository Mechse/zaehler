
package main

import "core:fmt"
import "core:net"

// run_proxy starts the TCP listener and handles connections one at a time.
//
// Current state: forwards each request to api.anthropic.com over HTTPS and
// STREAMS the response back to the client chunk-by-chunk. SQLite logging
// is the next step.
run_proxy :: proc(port: int) -> net.Network_Error {
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

	// forward_to_anthropic streams the response straight back to `client`.
	// We just get a byte count for logging purposes.
	bytes, fwd_err := forward_to_anthropic(req, client)
	if fwd_err != .None {
		fmt.eprintln("zlr: forward failed:", fwd_err)
		// If forwarding failed before we started streaming, we can still
		// send a 502. If failure was Client_Write_Failed, the client is
		// already dead — sending another response would be pointless.
		if fwd_err != .Client_Write_Failed {
			send_bad_gateway(client, fwd_err)
		}
		return
	}

	fmt.printfln("streamed %d bytes to client", bytes)
}
