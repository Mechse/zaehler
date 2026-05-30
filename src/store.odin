package main

import "core:fmt"
import "core:os"
import "core:strings"

// One global DB handle for the lifetime of the process.
db: ^sqlite3

// store_open creates ~/.zaehler/ if needed, opens (creating if needed)
// ~/.zaehler/zaehler.db, runs the schema, and pre-loads price data. Returns
// false on failure.
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

	schema_c := cstring(SCHEMA)
	errmsg: cstring
	if rc := sqlite3_exec(db, schema_c, nil, nil, &errmsg); rc != SQLITE_OK {
		fmt.eprintfln("zlr: schema exec failed (rc=%d): %s", rc, errmsg)
		return false
	}

	// Run any migrations to bring older databases up to date.
	migrate()

	// Eagerly load prices so the daemon (and CLI) is ready. If this fails
	// (no network on first start), cost columns will be NULL on new rows
	// but tokens still log.
	load_prices_if_needed()

	return true
}

store_close :: proc() {
	if db != nil {
		sqlite3_close(db)
		db = nil
	}
}

// store_insert_call writes one row to the calls table. The proxy looks up the
// model's current price and passes it in so the cost-per-token is stored
// alongside the tokens. Historical rows then reflect the prices in effect at
// the time of the call, not today's prices.
store_insert_call :: proc(
	ts: i64,
	model: string,
	endpoint: string,
	usage: Usage,
	bytes_streamed: int,
	price: Model_Price,
	has_price: bool,
) -> bool {
	sql :: "INSERT INTO calls (ts, model, endpoint, input_tokens, output_tokens, cache_create, cache_read, bytes_streamed, input_cost_per_token, output_cost_per_token, cache_read_per_token, cache_create_per_token) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

	stmt: ^sqlite3_stmt
	if rc := sqlite3_prepare_v2(db, sql, -1, &stmt, nil); rc != SQLITE_OK {
		fmt.eprintfln("zlr: prepare failed: %s", sqlite3_errmsg(db))
		return false
	}
	defer sqlite3_finalize(stmt)

	model_c    := strings.clone_to_cstring(model,    context.temp_allocator)
	endpoint_c := strings.clone_to_cstring(endpoint, context.temp_allocator)

	sqlite3_bind_int64(stmt, 1, ts)
	sqlite3_bind_text (stmt, 2, model_c,    -1, SQLITE_TRANSIENT)
	sqlite3_bind_text (stmt, 3, endpoint_c, -1, SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 4, i64(usage.input_tokens))
	sqlite3_bind_int64(stmt, 5, i64(usage.output_tokens))
	sqlite3_bind_int64(stmt, 6, i64(usage.cache_creation_input_tokens))
	sqlite3_bind_int64(stmt, 7, i64(usage.cache_read_input_tokens))
	sqlite3_bind_int64(stmt, 8, i64(bytes_streamed))

	if has_price {
		sqlite3_bind_double(stmt,  9, price.input_per_token)
		sqlite3_bind_double(stmt, 10, price.output_per_token)
		sqlite3_bind_double(stmt, 11, price.cache_read_per_token)
		sqlite3_bind_double(stmt, 12, price.cache_create_per_token)
	} else {
		sqlite3_bind_null(stmt,  9)
		sqlite3_bind_null(stmt, 10)
		sqlite3_bind_null(stmt, 11)
		sqlite3_bind_null(stmt, 12)
	}

	if rc := sqlite3_step(stmt); rc != SQLITE_DONE {
		fmt.eprintfln("zlr: insert step failed (rc=%d): %s", rc, sqlite3_errmsg(db))
		return false
	}
	return true
}

// migrate brings an older database up to the current schema. SQLite's
// "ALTER TABLE ... ADD COLUMN" is idempotent enough for our needs: we wrap
// each in a try-and-ignore-failure pattern. Failures here are silent on
// purpose because re-running ADD COLUMN on an already-migrated DB errors.
migrate :: proc() {
	exec_ignore :: proc(sql: cstring) {
		errmsg: cstring
		sqlite3_exec(db, sql, nil, nil, &errmsg)
	}

	exec_ignore("ALTER TABLE calls ADD COLUMN input_cost_per_token   REAL")
	exec_ignore("ALTER TABLE calls ADD COLUMN output_cost_per_token  REAL")
	exec_ignore("ALTER TABLE calls ADD COLUMN cache_read_per_token   REAL")
	exec_ignore("ALTER TABLE calls ADD COLUMN cache_create_per_token REAL")
}

zaehler_dir :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return "", false
	}
	return fmt.tprintf("%s/.zaehler", home), true
}

// SCHEMA is applied at startup. CREATE IF NOT EXISTS makes it idempotent
// for new databases; the migrate() proc handles older ones.
SCHEMA :: `
CREATE TABLE IF NOT EXISTS calls (
    id                       INTEGER PRIMARY KEY,
    ts                       INTEGER NOT NULL,
    model                    TEXT,
    endpoint                 TEXT    NOT NULL,
    input_tokens             INTEGER NOT NULL DEFAULT 0,
    output_tokens            INTEGER NOT NULL DEFAULT 0,
    cache_create             INTEGER NOT NULL DEFAULT 0,
    cache_read               INTEGER NOT NULL DEFAULT 0,
    bytes_streamed           INTEGER NOT NULL DEFAULT 0,
    input_cost_per_token     REAL,
    output_cost_per_token    REAL,
    cache_read_per_token     REAL,
    cache_create_per_token   REAL
);

CREATE INDEX IF NOT EXISTS calls_ts ON calls(ts);
`
