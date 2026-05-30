package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

run_today :: proc() {
	if !store_open() {
		os.exit(1)
	}

	defer store_close()

	now := time.time_to_unix(time.now())
	midnight := (now / 86400) * 86400

	sql :: "SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_create),0), COALESCE(SUM(cache_read),0) FROM calls WHERE ts >= ?"

	stmt: ^sqlite3_stmt
	if rc := sqlite3_prepare_v2(db, sql, -1, &stmt, nil); rc != SQLITE_OK {
		fmt.eprintfln("zlr: prepare failed: %s", sqlite3_errmsg(db))
		return
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, midnight)

	if rc := sqlite3_step(stmt); rc != SQLITE_ROW {
		fmt.eprintln("zlr today: no rows")
		return
	}

	count := sqlite3_column_int64(stmt, 0)
	in_tok := sqlite3_column_int64(stmt, 1)
	out_tok := sqlite3_column_int64(stmt, 2)
	cache_c := sqlite3_column_int64(stmt, 3)
	cache_r := sqlite3_column_int64(stmt, 4)

	fmt.printfln("today: %d calls", count)
	fmt.printfln("  input:        %d", in_tok)
	fmt.printfln("  output:       %d", out_tok)
	fmt.printfln("  cache_create: %d", cache_c)
	fmt.printfln("  cache_read:   %d", cache_r)
}

// run_tail prints the last N calls (default 20), most recent last.
run_tail :: proc() {
	if !store_open() {
		os.exit(1)
	}
	defer store_close()

	limit: i64 = 20
	if len(os.args) >= 3 {
		// `zlr tail 50`
		if n, ok := parse_pos_int(os.args[2]); ok {
			limit = i64(n)
		}
	}

	sql :: "SELECT ts, model, endpoint, input_tokens, output_tokens, cache_create, cache_read FROM calls ORDER BY ts DESC LIMIT ?"

	stmt: ^sqlite3_stmt
	if rc := sqlite3_prepare_v2(db, sql, -1, &stmt, nil); rc != SQLITE_OK {
		fmt.eprintfln("zlr: prepare failed: %s", sqlite3_errmsg(db))
		return
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, limit)

	// We're going to print most-recent LAST, so we collect rows then
	// print in reverse.
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
		if rc == SQLITE_DONE {break}
		if rc != SQLITE_ROW {
			fmt.eprintfln("zlr: step failed: %s", sqlite3_errmsg(db))
			return
		}

		// column_text returns a cstring (pointer to SQLite's internal copy
		// of the bytes, valid only until the next step()/reset()/finalize()).
		// We immediately clone to own the string.
		model_cs := sqlite3_column_text(stmt, 1)
		endpoint_cs := sqlite3_column_text(stmt, 2)

		append(
			&rows,
			Row {
				ts = sqlite3_column_int64(stmt, 0),
				model = strings.clone(string(model_cs)),
				endpoint = strings.clone(string(endpoint_cs)),
				in_tok = sqlite3_column_int64(stmt, 3),
				out_tok = sqlite3_column_int64(stmt, 4),
				cache_c = sqlite3_column_int64(stmt, 5),
				cache_r = sqlite3_column_int64(stmt, 6),
			},
		)
	}

	// Print oldest first.
	#reverse for r in rows {
		fmt.printfln(
			"%s  in=%-6d out=%-5d cache=%d/%d  %s  %s",
			format_ts(r.ts),
			r.in_tok,
			r.out_tok,
			r.cache_c,
			r.cache_r,
			r.model,
			r.endpoint,
		)
		delete(r.model)
		delete(r.endpoint)
	}
}

// ----- tiny helpers --------------------------------------------------------

format_ts :: proc(ts: i64) -> string {
	t := time.unix(ts, 0)
	yyyy, mm, dd := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", yyyy, int(mm), dd, h, m, s)
}

parse_pos_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {return 0, false}
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' {return 0, false}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}
