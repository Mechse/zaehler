package main

import "core:c"

when ODIN_OS == .Darwin {
	foreign import sqlite "system:sqlite3"
} else when ODIN_OS == .Linux {
	foreign import sqlite "system:sqlite3"
}

// Return codes. Only the ones we care about; SQLite defines many more.
SQLITE_OK :: 0
SQLITE_ROW :: 100 // step() returned a row
SQLITE_DONE :: 101 // step() finished, no more rows

SQLITE_TRANSIENT :: rawptr(~uintptr(0)) // (sqlite3_destructor_type)(-1)

sqlite3 :: struct {}
sqlite3_stmt :: struct {}

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open :: proc(filename: cstring, db: ^^sqlite3) -> c.int ---
	sqlite3_close :: proc(db: ^sqlite3) -> c.int ---
	sqlite3_exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	sqlite3_errmsg :: proc(db: ^sqlite3) -> cstring ---

	sqlite3_prepare_v2 :: proc(db: ^sqlite3, sql: cstring, n_byte: c.int, stmt: ^^sqlite3_stmt, tail: ^cstring) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^sqlite3_stmt) -> c.int ---

	sqlite3_bind_int64 :: proc(stmt: ^sqlite3_stmt, idx: c.int, val: i64) -> c.int ---
	sqlite3_bind_text :: proc(stmt: ^sqlite3_stmt, idx: c.int, val: cstring, n: c.int, destructor: rawptr) -> c.int ---

	sqlite3_column_int64 :: proc(stmt: ^sqlite3_stmt, col: c.int) -> i64 ---
	sqlite3_column_text :: proc(stmt: ^sqlite3_stmt, col: c.int) -> cstring ---
}
