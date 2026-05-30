package main

import "core:fmt"
import "core:os"

DEFAULT_PORT :: 8765

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(1)
	}

	switch os.args[1] {
	case "start":
		run_start()

	case "stop":
		run_stop()

	case "daemon":
		// Foreground mode — useful for debugging. Same code path as
		// `start` except we don't fork.
		install_signal_handlers()
		if err := run_proxy(DEFAULT_PORT); err != nil {
			fmt.eprintln("zlr: daemon failed:", err)
			os.exit(1)
		}

	case "today":
		run_today()

	case "tail":
		run_tail()

	case "help", "-h", "--help":
		print_usage()

	case:
		fmt.eprintfln("zlr: unknown command %q", os.args[1])
		print_usage()
		os.exit(1)
	}
}

// run_start backgrounds the proxy via the double-fork dance.
//
// If a daemon is already running (pid file exists and pid is alive),
// we exit silently with a friendly note.
run_start :: proc() {
	if pid, ok := read_pid_file(); ok && is_process_running(pid) {
		fmt.printfln("zlr: already running (pid %d)", pid)
		print_env_hint()
		os.exit(0)
	}

	// daemonize() forks twice. The original process and the intermediate
	// child both exit inside daemonize(). Code below this line only runs
	// in the daemon grandchild.
	//
	// BUT — the message we want to print ("started") needs to come from
	// the original parent, before it exits. We handle that by printing
	// FIRST, then calling daemonize(). The first fork-and-exit happens
	// inside daemonize() so the parent's stdout already has our message.
	fmt.printfln("zlr: starting daemon on http://127.0.0.1:%d", DEFAULT_PORT)
	print_env_hint()

	daemonize()

	// Past this point we are the daemon grandchild. stdin/out/err are
	// /dev/null, we have no controlling terminal, we have a pid file,
	// and signal handlers are installed.
	if err := run_proxy(DEFAULT_PORT); err != nil {
		os.exit(1)
	}
}

run_stop :: proc() {
	pid, ok := stop_running_daemon()
	if pid == 0 {
		fmt.println("zlr: no daemon running")
		return
	}
	if !ok {
		fmt.printfln("zlr: pid %d not running; cleaned up stale pid file", pid)
		return
	}
	fmt.printfln("zlr: sent SIGTERM to pid %d", pid)
	print_unset_hint()
}

print_env_hint :: proc() {
	fmt.println("")
	fmt.println("to route your AI tools through the proxy, run:")
	fmt.printfln("    export ANTHROPIC_BASE_URL=http://localhost:%d", DEFAULT_PORT)
}

print_unset_hint :: proc() {
	fmt.println("")
	fmt.println("to stop routing tools through the proxy, run:")
	fmt.println("    unset ANTHROPIC_BASE_URL")
}

print_usage :: proc() {
	fmt.eprintln("zaehler - track Claude API token usage")
	fmt.eprintln()
	fmt.eprintln("usage: zlr <command> [args]")
	fmt.eprintln()
	fmt.eprintln("commands:")
	fmt.eprintln("  start           run the proxy in the background")
	fmt.eprintln("  stop            stop a backgrounded proxy")
	fmt.eprintln("  daemon          run the proxy in the foreground (for debugging)")
	fmt.eprintln("  today           summary of today's calls and tokens")
	fmt.eprintln("  tail [N]        last N calls (default 20)")
	fmt.eprintln("  help            show this message")
}
