package main

// Daemonize: turn the current process into a proper Unix daemon.
//
// The textbook recipe (double fork) does five things in order:
//   1. fork() — parent exits so the caller's shell returns.
//   2. setsid() — child becomes a new session leader, detaches from
//      the controlling terminal.
//   3. fork() — first child exits; the grandchild is no longer a
//      session leader and can never reacquire a controlling terminal.
//   4. chdir("/") so we don't hold the launching directory busy.
//   5. close stdin/stdout/stderr and redirect them to /dev/null so any
//      stray print() is silently swallowed.
//
// After all that the daemon will survive the launching terminal closing,
// won't show up in shell job tables, and won't interfere with anyone's
// filesystem unmount.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// One bool the accept loop checks each iteration to know when to bow out.
// Set by the SIGTERM handler.
should_exit: bool = false

// pid_file_path returns ~/.zaehler/zlr.pid (and creates ~/.zaehler if needed).
pid_file_path :: proc() -> (string, bool) {
	dir, ok := zaehler_dir()
	if !ok {return "", false}
	if err := os.make_directory(dir); err != 0 && !os.exists(dir) {
		return "", false
	}
	return fmt.tprintf("%s/zlr.pid", dir), true
}

// read_pid_file reads the pid out of the pid file. Returns (pid, true) on
// success, (0, false) if the file is absent or unreadable.
read_pid_file :: proc() -> (int, bool) {
	path, ok := pid_file_path()
	if !ok {return 0, false}

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return 0, false}

	s := strings.trim_space(string(data))
	pid, parse_ok := strconv.parse_int(s)
	if !parse_ok {return 0, false}
	return pid, true
}


// write_pid_file writes the current pid to ~/.zaehler/zlr.pid.
write_pid_file :: proc() -> bool {
	path, ok := pid_file_path()
	if !ok {return false}

	content := fmt.tprintf("%d\n", posix.getpid())
	err := os.write_entire_file(path, transmute([]u8)content)
	return err == nil
}; remove_pid_file :: proc() {
	if path, ok := pid_file_path(); ok {
		os.remove(path)
	}
}

// is_process_running checks whether a pid points at a live process.
// kill(pid, 0) is the standard "ping" — it doesn't actually send a signal,
// just returns 0 if the process exists and we have permission to signal it.
is_process_running :: proc(pid: int) -> bool {
	if pid <= 0 {return false}
	return posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK
}

// signal_handler is what the kernel actually invokes on SIGTERM/SIGINT.
// Inside a signal handler, you can only do "async-signal-safe" things —
// basically: set flags, write to file descriptors, exit. Anything that
// touches the allocator is forbidden. So we just flip a bool.
@(private = "file")
signal_handler :: proc "c" (sig: posix.Signal) {
	should_exit = true
}

// install_signal_handlers wires SIGTERM and SIGINT to the handler above.
install_signal_handlers :: proc() {
	posix.signal(.SIGTERM, signal_handler)
	posix.signal(.SIGINT, signal_handler)
}

// daemonize performs the double-fork + setsid + chdir + close-stdio dance.
// On return, the calling process is the grandchild daemon. The original
// parent and the intermediate child both exit cleanly.
//
// The forked grandchild then writes the pid file and installs signal handlers.
daemonize :: proc() {
	// ----- first fork -------------------------------------------------------

	pid1 := posix.fork()
	if pid1 < 0 {
		fmt.eprintln("zlr: first fork failed")
		os.exit(1)
	}
	if pid1 > 0 {
		// Parent: exit immediately so the user's shell returns.
		os.exit(0)
	}

	// ----- become session leader -------------------------------------------

	if posix.setsid() < 0 {
		fmt.eprintln("zlr: setsid failed")
		os.exit(1)
	}

	// ----- second fork ------------------------------------------------------

	pid2 := posix.fork()
	if pid2 < 0 {
		fmt.eprintln("zlr: second fork failed")
		os.exit(1)
	}
	if pid2 > 0 {
		// Intermediate child: exit. Only the grandchild continues.
		os.exit(0)
	}

	// ----- chdir + close stdio ---------------------------------------------

	posix.chdir("/")

	// Open /dev/null and dup it onto fd 0/1/2. This way every existing
	// print() call still works — it just goes to a bit-sink.
	devnull := posix.open("/dev/null", {.RDWR})
	if devnull >= 0 {
		posix.dup2(devnull, posix.STDIN_FILENO)
		posix.dup2(devnull, posix.STDOUT_FILENO)
		posix.dup2(devnull, posix.STDERR_FILENO)
		if devnull > 2 {
			posix.close(devnull)
		}
	}

	// ----- pid file + signals ----------------------------------------------

	write_pid_file()
	install_signal_handlers()
}

// stop_running_daemon reads the pid file, sends SIGTERM, removes the file.
// Returns (pid_we_killed, ok).
stop_running_daemon :: proc() -> (int, bool) {
	pid, ok := read_pid_file()
	if !ok {
		return 0, false
	}
	if !is_process_running(pid) {
		// Stale pid file — clean it up but tell the caller.
		remove_pid_file()
		return pid, false
	}
	if posix.kill(posix.pid_t(pid), .SIGTERM) != .OK {
		return pid, false
	}
	// We don't wait for the process to actually exit — that's the daemon's
	// own responsibility (its signal handler will flip should_exit and the
	// accept loop will notice). Remove the pid file optimistically.
	remove_pid_file()
	return pid, true
}
