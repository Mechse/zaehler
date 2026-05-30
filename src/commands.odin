package main

// Read-side subcommands.
//
//   zlr today   summary of calls since local midnight (rich render)
//   zlr week    last 7 days (rich render)
//   zlr all     lifetime (rich render)
//   zlr tail    last N calls (plain text)

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Summary :: struct {
	label:          string,
	bucket_label:   string,
	total_calls:    int,
	input_tokens:   int,
	output_tokens:  int,
	cache_create:   int,
	cache_read:     int,
	cost_usd:       f64,
	saved_usd:      f64,
	buckets:        []int,
	busiest_count:  int,
	busiest_label:  string,
}

Bucket_Kind :: enum { Hourly, Daily }

// ---------------------------------------------------------------------------
// entry points
// ---------------------------------------------------------------------------

run_today :: proc() {
	if !store_open() { os.exit(1) }
	defer store_close()

	now := time.time_to_unix(time.now())
	start := day_start(now)

	s := summarize(start, now, 24, .Hourly)
	s.label = "today"
	s.cost_usd, s.saved_usd = aggregate_costs(start, now)
	render_summary(s)
}

run_week :: proc() {
	if !store_open() { os.exit(1) }
	defer store_close()

	now := time.time_to_unix(time.now())
	start := day_start(now) - 6 * 86400

	s := summarize(start, now, 7, .Daily)
	s.label = "last 7 days"
	s.cost_usd, s.saved_usd = aggregate_costs(start, now)
	render_summary(s)
}

run_all :: proc() {
	if !store_open() { os.exit(1) }
	defer store_close()

	first_ts := first_call_ts()
	if first_ts == 0 {
		fmt.println()
		fmt.printfln("  %s", gray("no calls logged yet"))
		fmt.println()
		return
	}
	now := time.time_to_unix(time.now())

	span := now - first_ts
	day_count := 30
	if span < 30 * 86400 {
		day_count = int(span / 86400) + 1
	}
	start := day_start(now) - i64(day_count - 1) * 86400

	s := summarize(start, now, day_count, .Daily)
	s.label = fmt.tprintf("all-time (since %s)", format_date(first_ts))
	s.cost_usd, s.saved_usd = aggregate_costs(first_ts, now)
	render_summary(s)
}

run_tail :: proc() {
	if !store_open() { os.exit(1) }
	defer store_close()

	limit: i64 = 20
	if len(os.args) >= 3 {
		if n, ok := parse_pos_int(os.args[2]); ok {
			limit = i64(n)
		}
	}

	sql :: "SELECT ts, model, endpoint, input_tokens, output_tokens, cache_create, cache_read FROM calls ORDER BY ts DESC LIMIT ?"

	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
		fmt.eprintfln("zlr: prepare failed: %s", sqlite3_errmsg(db))
		return
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, limit)

	Row :: struct {
		ts:       i64,
		model:    string,
		endpoint: string,
		in_tok:   i64,
		out_tok:  i64,
		cache_c:  i64,
		cache_r:  i64,
	}
	rows: [dynamic]Row
	defer delete(rows)

	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { break }
		if rc != SQLITE_ROW { return }

		append(&rows, Row{
			ts       = sqlite3_column_int64(stmt, 0),
			model    = strings.clone(string(sqlite3_column_text(stmt, 1))),
			endpoint = strings.clone(string(sqlite3_column_text(stmt, 2))),
			in_tok   = sqlite3_column_int64(stmt, 3),
			out_tok  = sqlite3_column_int64(stmt, 4),
			cache_c  = sqlite3_column_int64(stmt, 5),
			cache_r  = sqlite3_column_int64(stmt, 6),
		})
	}

	#reverse for r in rows {
		fmt.printfln(
			"%s  in=%-6d out=%-5d cache=%d/%d  %s  %s",
			format_ts(r.ts),
			r.in_tok, r.out_tok, r.cache_c, r.cache_r,
			r.model, r.endpoint,
		)
		delete(r.model)
		delete(r.endpoint)
	}
}

// ---------------------------------------------------------------------------
// summarize: token totals + sparkline buckets + busiest
// ---------------------------------------------------------------------------

summarize :: proc(start_ts, end_ts: i64, bucket_count: int, kind: Bucket_Kind) -> Summary {
	s: Summary
	s.buckets = make([]int, bucket_count, context.temp_allocator)
	s.bucket_label = "by hour" if kind == .Hourly else "by day"

	sql :: "SELECT ts, input_tokens, output_tokens, cache_create, cache_read FROM calls WHERE ts >= ? AND ts <= ?"

	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return s }
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, start_ts)
	sqlite3_bind_int64(stmt, 2, end_ts)

	bucket_size: i64 = 3600 if kind == .Hourly else 86400

	busiest_idx := -1
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { break }
		if rc != SQLITE_ROW { return s }

		ts := sqlite3_column_int64(stmt, 0)
		s.total_calls   += 1
		s.input_tokens  += int(sqlite3_column_int64(stmt, 1))
		s.output_tokens += int(sqlite3_column_int64(stmt, 2))
		s.cache_create  += int(sqlite3_column_int64(stmt, 3))
		s.cache_read    += int(sqlite3_column_int64(stmt, 4))

		idx := int((ts - start_ts) / bucket_size)
		if idx >= 0 && idx < bucket_count {
			s.buckets[idx] += 1
			if s.buckets[idx] > s.busiest_count {
				s.busiest_count = s.buckets[idx]
				busiest_idx = idx
			}
		}
	}

	if busiest_idx >= 0 {
		at := start_ts + i64(busiest_idx) * bucket_size
		if kind == .Hourly {
			t := time.unix(at, 0)
			h, _, _ := time.clock(t)
			s.busiest_label = fmt.tprintf("%02d:00\u2013%02d:00", h, h+1)
		} else {
			s.busiest_label = format_date(at)
		}
	}

	return s
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

TABLE_WIDTH :: 44

render_summary :: proc(s: Summary) {
	init_color()

	hit_rate := 0
	if (s.cache_read + s.input_tokens) > 0 {
		hit_rate = (s.cache_read * 100) / (s.cache_read + s.input_tokens)
	}

	rule := strings.repeat("\u2500", TABLE_WIDTH, context.temp_allocator)

	fmt.println()
	fmt.printfln("  %s %s",
		bold("zaehler"),
		gray(fmt.tprintf("\u2014 %s", s.label)),
	)
	fmt.println()

	if s.cost_usd > 0 {
		fmt.printfln("  %s   %s",
			bold(green(fmt_cost(s.cost_usd))),
			gray(fmt.tprintf("on %s requests", fmt_int(s.total_calls))),
		)
	} else {
		fmt.printfln("  %s   %s",
			bold(green(fmt_int(s.total_calls))),
			gray("requests"),
		)
	}

	if s.total_calls > 0 {
		fmt.printfln("  %s  %s",
			cyan(sparkline(s.buckets)),
			gray(s.bucket_label),
		)
	}
	fmt.println()
	fmt.printfln("  %s", gray(rule))

	render_row("input",        fmt_int(s.input_tokens))
	render_row("output",       fmt_int(s.output_tokens))
	render_row("cache reads",  fmt_int(s.cache_read))
	render_row("cache writes", fmt_int(s.cache_create))

	fmt.printfln("  %s", gray(rule))

	render_row("hit rate", fmt.tprintf("%d%%", hit_rate))
	if s.saved_usd > 0 {
		render_row("cache saved you", green(fmt_cost(s.saved_usd)))
	}

	fmt.println()

	if s.busiest_count > 0 {
		fmt.printfln("  %s %s @ %s",
			dim("busiest:"),
			fmt.tprintf("%d requests", s.busiest_count),
			gray(s.busiest_label),
		)
	}

	fmt.println()
}

render_row :: proc(label, value: string) {
	pad := TABLE_WIDTH - len_visible(label) - len_visible(value)
	if pad < 1 { pad = 1 }
	fmt.printfln("  %s%s%s",
		gray(label),
		strings.repeat(" ", pad, context.temp_allocator),
		bold(value),
	)
}

len_visible :: proc(s: string) -> int {
	count := 0
	in_esc := false
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch == 0x1B { in_esc = true; continue }
		if in_esc { if ch == 'm' { in_esc = false }; continue }
		if (ch & 0xC0) != 0x80 { count += 1 }
	}
	return count
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

first_call_ts :: proc() -> i64 {
	sql :: "SELECT MIN(ts) FROM calls"
	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW { return 0 }
	return sqlite3_column_int64(stmt, 0)
}

day_start :: proc(ts: i64) -> i64 {
	return (ts / 86400) * 86400
}

format_ts :: proc(ts: i64) -> string {
	t := time.unix(ts, 0)
	yyyy, mm, dd := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", yyyy, int(mm), dd, h, m, s)
}

format_date :: proc(ts: i64) -> string {
	t := time.unix(ts, 0)
	yyyy, mm, dd := time.date(t)
	return fmt.tprintf("%04d-%02d-%02d", yyyy, int(mm), dd)
}

parse_pos_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 { return 0, false }
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' { return 0, false }
		n = n*10 + int(ch - '0')
	}
	return n, true
}
