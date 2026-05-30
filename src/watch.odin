package main

// `zlr watch` — live updating today-view.
//
// Architecture:
//   1. Enter alternate screen buffer (so the dashboard doesn't pollute scrollback).
//   2. Hide the cursor.
//   3. Put stdin into non-blocking raw mode so we can poll for 'q' without
//      consuming whole lines or echoing them.
//   4. Loop: clear screen, render, sleep ~1s, check stdin, repeat.
//   5. Restore terminal on EVERY exit path (q, Ctrl-C, panic, signal).
//
// The most important thing in this file is the cleanup. If we leave the
// terminal in raw mode or alternate-screen mode on exit, the user has to
// type `reset` blind to recover. Two layers protect against that:
//   - A `defer tui_cleanup()` at the top of run_watch.
//   - A flag `tui_active` checked by the existing SIGINT/SIGTERM handler.

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

REFRESH_SECONDS :: 1

// ANSI control sequences
ALT_SCREEN_ON :: "\033[?1049h"
ALT_SCREEN_OFF :: "\033[?1049l"
CURSOR_HIDE :: "\033[?25l"
CURSOR_SHOW :: "\033[?25h"
CLEAR_HOME :: "\033[H\033[J" // home + clear-to-end

// Saved terminal attributes, restored on cleanup.
@(private = "file")
saved_termios: posix.termios
@(private = "file")
tui_active: bool = false

run_watch :: proc() {
	if !store_open() {
		fmt.eprintln("zlr: could not open store")
		os.exit(1)
	}
	defer store_close()

	install_signal_handlers() // so Ctrl-C runs our cleanup via should_exit

	if !tui_setup() {
		fmt.eprintln("zlr: this terminal can't do live mode; try `zlr today`")
		os.exit(1)
	}
	defer tui_cleanup()

	for !should_exit {
		// Build the same Summary the static view uses.
		now := time.time_to_unix(time.now())
		start := day_start(now)
		s := summarize(start, now, 24, .Hourly)
		s.label = "today (live)"
		s.cost_usd, s.saved_usd = aggregate_costs(start, now)

		// Clear and redraw.
		fmt.print(CLEAR_HOME)
		render_summary(s)
		fmt.printfln("  %s", dim("press q to exit"))
		// Force the writes out, the alt screen buffers them otherwise.
		os.flush(os.stdout)

		// Sleep ~1s, but check stdin periodically for 'q'.
		if wait_for_quit(REFRESH_SECONDS * 10) { 	// 10 × 100ms checks
			break
		}
	}
}

// ---------------------------------------------------------------------------
// terminal setup / teardown
// ---------------------------------------------------------------------------

// tui_setup puts the terminal into raw mode and enters the alternate screen.
// Returns false if stdout isn't a TTY (e.g. piped output) — live mode would
// be meaningless there.
tui_setup :: proc() -> bool {
	if !bool(posix.isatty(posix.STDIN_FILENO)) {return false}
	if !bool(posix.isatty(posix.STDOUT_FILENO)) {return false}

	// Snapshot the current termios so we can restore later.
	if posix.tcgetattr(posix.STDIN_FILENO, &saved_termios) != .OK {
		return false
	}

	raw := saved_termios
	// Disable canonical mode (line-buffered) and echo, and disable
	// signal generation on ^C so we get the byte directly.
	raw.c_lflag -= {.ICANON, .ECHO}
	// VMIN=0 VTIME=0: read returns immediately, possibly with 0 bytes.
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)

	// Enter alternate screen, hide cursor.
	fmt.print(ALT_SCREEN_ON)
	fmt.print(CURSOR_HIDE)
	os.flush(os.stdout)

	tui_active = true
	return true
}

// tui_cleanup restores everything tui_setup changed. Safe to call multiple
// times — the tui_active flag prevents double-cleanup.
tui_cleanup :: proc() {
	if !tui_active {return}
	tui_active = false

	// Restore termios, exit alt screen, show cursor — in that order.
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &saved_termios)
	fmt.print(CURSOR_SHOW)
	fmt.print(ALT_SCREEN_OFF)
	os.flush(os.stdout)
}

// ---------------------------------------------------------------------------
// quit detection
// ---------------------------------------------------------------------------

// wait_for_quit sleeps in 100ms chunks, polling stdin for 'q' / Ctrl-C between
// chunks. Returns true if quit was requested.
wait_for_quit :: proc(ticks: int) -> bool {
	buf: [16]u8
	for _ in 0 ..< ticks {
		if should_exit {return true}

		// VMIN=0 VTIME=0 means read returns 0 if nothing is waiting.
		n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), len(buf))
		if n > 0 {
			for i in 0 ..< int(n) {
				ch := buf[i]
				if ch == 'q' || ch == 'Q' || ch == 0x03 { 	// 0x03 = Ctrl-C
					return true
				}
			}
		}

		time.sleep(100 * time.Millisecond)
	}
	return false
}

// Suppress unused warnings on platforms where c isn't directly referenced.
_ :: c
