package main

// Minimal OpenSSL bindings. Only the functions forward.odin actually uses.
//
// Why hand-rolled: Homebrew's Odin doesn't ship vendor:openssl, and we only
// need ~10 calls. Writing the bindings ourselves teaches a real Odin skill
// (calling C libraries) and avoids dragging in a whole HTTP library.
//
// The dylibs live in the Homebrew openssl@3 keg. The two `foreign import`
// statements below resolve to libssl + libcrypto on macOS via Homebrew.
//
// On Linux you'd use "system:ssl" and "system:crypto" instead; we'll worry
// about that the day this needs to run on Linux.

import "core:c"

when ODIN_OS == .Darwin {
	// Homebrew openssl@3 on Apple Silicon and Intel Macs.
	when ODIN_ARCH == .arm64 {
		foreign import libssl    "system:/opt/homebrew/opt/openssl@3/lib/libssl.dylib"
		foreign import libcrypto "system:/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib"
	} else {
		foreign import libssl    "system:/usr/local/opt/openssl@3/lib/libssl.dylib"
		foreign import libcrypto "system:/usr/local/opt/openssl@3/lib/libcrypto.dylib"
	}
} else when ODIN_OS == .Linux {
	foreign import libssl    "system:ssl"
	foreign import libcrypto "system:crypto"
}

// Opaque C structs. We never look inside; we only pass pointers around.
// The empty `struct{}` is Odin's way of saying "an opaque type, size unknown."
SSL_CTX    :: struct{}
SSL        :: struct{}
SSL_METHOD :: struct{}

// Magic constants used by SSL_ctrl to implement the SSL_set_tlsext_host_name
// macro. The numeric values come from openssl/tls1.h — they're part of the
// stable ABI and won't change.
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
TLSEXT_NAMETYPE_host_name    :: 0

// All the libssl functions we call. The @(default_calling_convention="c")
// attribute makes every proc in the block use the C calling convention,
// which is what the linker expects for symbols in a C library.
@(default_calling_convention = "c")
foreign libssl {
	TLS_client_method        :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new              :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_CTX_free             :: proc(ctx: ^SSL_CTX) ---
	SSL_new                  :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_free                 :: proc(ssl: ^SSL) ---
	SSL_set_fd               :: proc(ssl: ^SSL, fd: c.int) -> c.int ---
	SSL_ctrl                 :: proc(ssl: ^SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_connect              :: proc(ssl: ^SSL) -> c.int ---
	SSL_write                :: proc(ssl: ^SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_read                 :: proc(ssl: ^SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_shutdown             :: proc(ssl: ^SSL) -> c.int ---
}

// SSL_set_tlsext_host_name is a MACRO in C — there's no symbol with that name
// in libssl. The macro expands to a particular SSL_ctrl call. We replicate
// that here as a normal Odin proc. SNI is required when connecting to any
// CDN-backed host like api.anthropic.com (Cloudflare).
SSL_set_tlsext_host_name :: proc(ssl: ^SSL, name: cstring) -> c.int {
	return c.int(SSL_ctrl(
		ssl,
		SSL_CTRL_SET_TLSEXT_HOSTNAME,
		TLSEXT_NAMETYPE_host_name,
		rawptr(name),
	))
}
