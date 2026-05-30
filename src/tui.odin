package main

// Tiny TUI primitives: ANSI colors, isatty detection, sparklines.
//
// No curses, no library. Just the right bytes to stdout. The `ESC` constant
// is the byte every ANSI escape starts with; everything else composes from
// there.

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

ESC :: "\033["

// ANSI color codes. We use these via the color() helper so they auto-disable
// when stdout isn't a terminal (e.g., when piped to less or a file).
ANSI_RESET :: ESC + "0m"
ANSI_BOLD :: ESC + "1m"
ANSI_DIM :: ESC + "2m"

ANSI_BLACK :: ESC + "30m"
ANSI_RED :: ESC + "31m"
ANSI_GREEN :: ESC + "32m"
ANSI_YELLOW :: ESC + "33m"
ANSI_BLUE :: ESC + "34m"
ANSI_MAGENTA :: ESC + "35m"
ANSI_CYAN :: ESC + "36m"
ANSI_GRAY :: ESC + "90m"

// Cached: do we have a terminal on stdout? Set once at startup.
@(private = "file")
color_enabled := true
@(private = "file")
color_initialized := false

// init_color decides whether to emit color codes. Call before printing.
init_color :: proc() {
	if color_initialized {return}
	color_initialized = true
	color_enabled = bool(posix.isatty(posix.STDOUT_FILENO))
}

// color wraps `text` in an ANSI color code, returning the wrapped string
// or the bare text if color is disabled. The result is allocated in the
// temp allocator.
color :: proc(code: string, text: string) -> string {
	init_color()
	if !color_enabled {return text}
	return fmt.tprintf("%s%s%s", code, text, ANSI_RESET)
}

// Convenience wrappers
green :: proc(s: string) -> string {return color(ANSI_GREEN, s)}
red :: proc(s: string) -> string {return color(ANSI_RED, s)}
yellow :: proc(s: string) -> string {return color(ANSI_YELLOW, s)}
cyan :: proc(s: string) -> string {return color(ANSI_CYAN, s)}
gray :: proc(s: string) -> string {return color(ANSI_GRAY, s)}
bold :: proc(s: string) -> string {return color(ANSI_BOLD, s)}
dim :: proc(s: string) -> string {return color(ANSI_DIM, s)}

// ----- sparkline ------------------------------------------------------------

// The 8 block-height characters that make a sparkline. ▁ is shortest, █ tallest.
@(private = "file")
SPARK_BLOCKS := [?]rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// sparkline turns N integer buckets into a string of N unicode blocks.
// The tallest bucket becomes '█'; everything else is scaled proportionally.
// Zero buckets render as ' ' (space), not the shortest block — so flat-zero
// gaps in the data are visibly empty rather than a misleading low line.
sparkline :: proc(buckets: []int) -> string {
	if len(buckets) == 0 {return ""}

	max_val := 0
	for v in buckets {
		if v > max_val {max_val = v}
	}

	sb := strings.builder_make(context.temp_allocator)
	if max_val == 0 {
		for _ in buckets {
			strings.write_rune(&sb, ' ')
		}
		return strings.to_string(sb)
	}

	for v in buckets {
		if v == 0 {
			strings.write_rune(&sb, ' ')
			continue
		}
		// Scale into [0, 7] inclusive. v / max_val is in [0, 1]; multiply by 7.
		idx := (v * 7) / max_val
		if idx > 7 {idx = 7}
		strings.write_rune(&sb, SPARK_BLOCKS[idx])
	}
	return strings.to_string(sb)
}

// ----- number formatting ---------------------------------------------------

// fmt_int formats an integer with thousands separators. 12453 -> "12,453".
// Negative numbers handled. No allocation beyond what tprintf does.
fmt_int :: proc(n: int) -> string {
	if n < 0 {
		return fmt.tprintf("-%s", fmt_int(-n))
	}
	if n < 1000 {
		return fmt.tprintf("%d", n)
	}

	// Build right-to-left in a fixed buffer, then reverse-copy.
	buf: [32]u8
	i := len(buf)
	digit_count := 0
	x := n
	for x > 0 {
		if digit_count > 0 && digit_count % 3 == 0 {
			i -= 1
			buf[i] = ','
		}
		i -= 1
		buf[i] = u8('0' + x % 10)
		x /= 10
		digit_count += 1
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// fmt_cost formats a USD amount. We use "$" because that's how Anthropic
// publishes prices; localization is a future problem.
fmt_cost :: proc(cents: f64) -> string {
	return fmt.tprintf("$%.2f", cents)
}

// Used by some files to keep imports tidy.
_ :: c
