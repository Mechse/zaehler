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
	case "daemon", "start":
		if err := run_proxy(DEFAULT_PORT); err != nil {
			fmt.eprintfln("zlr: daemon failed:", err)
			os.exit(1)
		}

	case "today":
		run_today()

	case "tail":
		run_tail()

	case "status":
		// Step 4: show what's been logged since the last commit boundary.
		fmt.eprintln("zlr status: not implemented yet (roadmap step 4)")
		os.exit(1)

	case "help", "-h", "--help":
		print_usage()

	case:
		fmt.eprintfln("zlr: unknown command %q", os.args[1])
	}
}

print_usage :: proc() {
	fmt.eprintln("zaehler - track token usage per commit")
	fmt.eprintln()
	fmt.eprintln("usage: zlr <command> [args]")
	fmt.eprintln()
	fmt.eprintln("commands:")
	fmt.eprintln("  daemon, start   start the token-tracking proxy on port 8765")
	fmt.eprintln("  today           summary of today's calls and tokens")
	fmt.eprintln("  tail [N]        last N calls (default 20)")
	fmt.eprintln("  help            show this message")
}
