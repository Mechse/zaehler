package main

import "core:fmt"
import "core:os"
import "core:strings"

db: ^sqlite3

// store_open creates ~/.zaehler/ if needed, opens (creating if needed)
// ~/.zaehler/zaehler.db, and runs the schema. Returns false on failure.
store_open :: proc() -> bool {
	dir, ok := zaehler_dir()
	if !ok {
		fmt.eprintln("zlr: could not resolve home directory")
		return false
	}

	if err := os.make_directory(dir); err != 0 && !os.exists(dir) {
		fmt.eprintfln("zlr: could not create %s: %v", dir, err)
		return false
	}

	path := fmt.tprintf("%s/zaehler.db", dir)
	path_c := strings.clone_to_cstring(path, context.temp_allocator)

	rc := sqlite3_open(path_c, &db)
	if rc != SQLITE_OK {
		fmt.eprintfln("zlr: sqlite3_open failed (rc=%d): %s", rc, sqlite3_errmsg(db))
		return false
	}

	// Apply the schema. CREATE IF NOT EXISTS makes this idempotent.
	schema_c := cstring(SCHEMA)
	errmsg: cstring
	if rc := sqlite3_exec(db, schema_c, nil, nil, &errmsg); rc != SQLITE_OK {
		fmt.eprintfln("zlr: schema exec failed (rc=%d): %s", rc, errmsg)
		return false
	}

	return true
}

store_close :: proc() {
	if db != nil {
		sqlite3_close(db)
		db = nil
	}
}

// Uses a prepared statement: we compile the SQL once (cheap) and bind
// fresh values for each insert. SQLite's standard pattern.
store_insert_call :: proc(
	ts: i64,
	model: string,
	endpoint: string,
	usage: Usage,
	bytes_streamed: int,
) -> bool {
	sql :: "INSERT INTO calls (ts, model, endpoint, input_tokens, output_tokens, cache_create, cache_read, bytes_streamed) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"

	stmt: ^sqlite3_stmt
	if rc := sqlite3_prepare_v2(db, sql, -1, &stmt, nil); rc != SQLITE_OK {
		fmt.eprintfln("zlr: prepare failed: %s", sqlite3_errmsg(db))
		return false
	}
	defer sqlite3_finalize(stmt)

	model_c := strings.clone_to_cstring(model, context.temp_allocator)
	endpoint_c := strings.clone_to_cstring(endpoint, context.temp_allocator)

	sqlite3_bind_int64(stmt, 1, ts)
	sqlite3_bind_text(stmt, 2, model_c, -1, SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, endpoint_c, -1, SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 4, i64(usage.input_tokens))
	sqlite3_bind_int64(stmt, 5, i64(usage.output_tokens))
	sqlite3_bind_int64(stmt, 6, i64(usage.cache_creation_input_tokens))
	sqlite3_bind_int64(stmt, 7, i64(usage.cache_read_input_tokens))
	sqlite3_bind_int64(stmt, 8, i64(bytes_streamed))

	if rc := sqlite3_step(stmt); rc != SQLITE_DONE {
		fmt.eprintfln("zlr: insert step failed (rc=%d): %s", rc, sqlite3_errmsg(db))
		return false
	}
	return true
}

// ----- helpers --------------------------------------------------------------

// zaehler_dir returns ~/.zaehler/, expanding $HOME ourselves because Odin's
// os package doesn't do tilde expansion.
zaehler_dir :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return "", false
	}
	return fmt.tprintf("%s/.zaehler", home), true
}

// SCHEMA is applied at startup. CREATE IF NOT EXISTS makes it idempotent.
// No commits/attribution tables — we scoped those out.
SCHEMA :: `
CREATE TABLE IF NOT EXISTS calls (
    id             INTEGER PRIMARY KEY,
    ts             INTEGER NOT NULL,
    model          TEXT,
    endpoint       TEXT    NOT NULL,
    input_tokens   INTEGER NOT NULL DEFAULT 0,
    output_tokens  INTEGER NOT NULL DEFAULT 0,
    cache_create   INTEGER NOT NULL DEFAULT 0,
    cache_read     INTEGER NOT NULL DEFAULT 0,
    bytes_streamed INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS calls_ts ON calls(ts);
`
