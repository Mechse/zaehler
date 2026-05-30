package main

// Pricing.
//
// Source of truth: BerriAI/litellm's model_prices_and_context_window.json,
// fetched once a day to ~/.zaehler/prices.json.
//
// Cost storage:
//   - When the daemon writes a row to `calls`, it looks up the current price
//     for the model and stores the four per-token costs ALONGSIDE the tokens.
//   - When the CLI reads, cost is computed from those stored per-row prices.
//     Anthropic changing their prices later does NOT alter historical totals.
//
// price_for_model is used at WRITE time (daemon).
// aggregate_costs is used at READ time (CLI).

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

PRICES_HOST :: "raw.githubusercontent.com"
PRICES_PATH :: "/BerriAI/litellm/main/model_prices_and_context_window.json"
PRICES_PORT :: 443
CACHE_TTL_SECONDS :: 86400

Model_Price :: struct {
	input_per_token:        f64,
	output_per_token:       f64,
	cache_read_per_token:   f64,
	cache_create_per_token: f64,
}

@(private = "file")
prices: map[string]Model_Price
@(private = "file")
prices_loaded := false

// ---------------------------------------------------------------------------
// write path: look up price for a model right now
// ---------------------------------------------------------------------------

price_for_model :: proc(model: string) -> (Model_Price, bool) {
	load_prices_if_needed()
	if p, ok := prices[model]; ok {
		return p, true
	}
	// Fallback: strip a "[...]" suffix (e.g. "claude-opus-4-8[1m]") and retry.
	if i := strings.index_byte(model, '['); i != -1 {
		if p, ok := prices[model[:i]]; ok {
			return p, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// read path: compute totals from per-row stored prices
// ---------------------------------------------------------------------------

// aggregate_costs runs one SQL query that uses each row's STORED per-token
// prices. Rows without prices (NULLs from before pricing landed, or rows
// where the model was unknown) contribute 0 to cost but still count in totals.
//
// "saved_usd" reflects what cache_read tokens would have cost as fresh input
// vs what they actually cost.
aggregate_costs :: proc(start_ts, end_ts: i64) -> (cost_usd, saved_usd: f64) {
	sql :: `
SELECT
    COALESCE(SUM(input_tokens  * input_cost_per_token),  0) +
    COALESCE(SUM(output_tokens * output_cost_per_token), 0) +
    COALESCE(SUM(cache_read    * cache_read_per_token),  0) +
    COALESCE(SUM(cache_create  * cache_create_per_token),0) AS total_cost,

    COALESCE(SUM(cache_read    * input_cost_per_token),  0) -
    COALESCE(SUM(cache_read    * cache_read_per_token),  0) AS saved
FROM calls
WHERE ts >= ? AND ts <= ?
`

	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {return}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, start_ts)
	sqlite3_bind_int64(stmt, 2, end_ts)

	if sqlite3_step(stmt) != SQLITE_ROW {return}

	cost_usd = sqlite3_column_double(stmt, 0)
	saved_usd = sqlite3_column_double(stmt, 1)
	return
}

// ---------------------------------------------------------------------------
// fetch + cache the JSON
// ---------------------------------------------------------------------------

load_prices_if_needed :: proc() {
	if prices_loaded {return}
	prices_loaded = true
	prices = make(map[string]Model_Price)

	data, ok := load_or_fetch_prices_json()
	if !ok {return}

	parse_anthropic_prices(string(data), &prices)
}

load_or_fetch_prices_json :: proc() -> ([]u8, bool) {
	dir, dir_ok := zaehler_dir()
	if !dir_ok {return nil, false}

	cache_path := fmt.tprintf("%s/prices.json", dir)

	if stat, err := os.stat(cache_path, context.temp_allocator); err == nil {
		age := time.time_to_unix(time.now()) - time.time_to_unix(stat.modification_time)
		if age < CACHE_TTL_SECONDS {
			data, read_err := os.read_entire_file_from_path(cache_path, context.temp_allocator)
			if read_err == nil {return data, true}
		}
	}

	body, fetch_ok := https_get_body(PRICES_HOST, PRICES_PATH)
	if !fetch_ok {
		// Network down? Fall back to ANY cached copy, even if stale.
		if data, read_err := os.read_entire_file_from_path(cache_path, context.temp_allocator);
		   read_err == nil {
			return data, true
		}
		return nil, false
	}

	_ = os.write_entire_file(cache_path, body)
	return body, true
}

https_get_body :: proc(host: string, path: string) -> ([]u8, bool) {
	endpoint, dns_err := net.resolve_ip4(host)
	if dns_err != nil {return nil, false}
	endpoint.port = PRICES_PORT

	tcp_socket, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {return nil, false}
	defer net.close(tcp_socket)

	ctx := SSL_CTX_new(TLS_client_method())
	if ctx == nil {return nil, false}
	defer SSL_CTX_free(ctx)

	ssl := SSL_new(ctx)
	if ssl == nil {return nil, false}
	defer SSL_free(ssl)

	SSL_set_fd(ssl, c.int(tcp_socket))

	host_c := strings.clone_to_cstring(host, context.temp_allocator)
	SSL_set_tlsext_host_name(ssl, host_c)

	if SSL_connect(ssl) != 1 {return nil, false}

	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\n" +
		"Host: %s\r\n" +
		"User-Agent: zaehler/0.1\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n" +
		"\r\n",
		path,
		host,
	)
	req_bytes := transmute([]u8)req

	to_write := len(req_bytes)
	written := 0
	for written < to_write {
		ret := SSL_write(ssl, raw_data(req_bytes[written:]), c.int(to_write - written))
		if ret <= 0 {return nil, false}
		written += int(ret)
	}

	buf: [dynamic]u8
	tmp: [16384]u8
	for {
		ret := SSL_read(ssl, raw_data(tmp[:]), c.int(len(tmp)))
		if ret <= 0 {break}
		append(&buf, ..tmp[:int(ret)])
	}
	SSL_shutdown(ssl)

	if len(buf) == 0 {return nil, false}

	all := buf[:]
	sep_idx := -1
	for i in 0 ..= len(all) - 4 {
		if all[i] == '\r' && all[i + 1] == '\n' && all[i + 2] == '\r' && all[i + 3] == '\n' {
			sep_idx = i
			break
		}
	}
	if sep_idx == -1 {return nil, false}

	headers_str := string(all[:sep_idx])
	if first_eol := strings.index(headers_str, "\r\n"); first_eol != -1 {
		status_line := headers_str[:first_eol]
		if !strings.contains(status_line, " 200 ") {return nil, false}
	}

	body := all[sep_idx + 4:]

	if strings.contains(headers_str, "Transfer-Encoding: chunked") {
		return dechunk(body), true
	}

	result := make([]u8, len(body))
	copy(result, body)
	return result, true
}

dechunk :: proc(body: []u8) -> []u8 {
	out: [dynamic]u8
	i := 0
	for i < len(body) {
		j := i
		for j < len(body) && body[j] != '\r' {j += 1}
		if j >= len(body) - 1 {break}

		length, _ := strconv.parse_int(string(body[i:j]), 16)
		if length == 0 {break}

		i = j + 2
		if i + length > len(body) {break}

		append(&out, ..body[i:i + length])
		i += length

		if i + 2 > len(body) {break}
		i += 2
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// JSON mini-parser
// ---------------------------------------------------------------------------

parse_anthropic_prices :: proc(text: string, out: ^map[string]Model_Price) {
	pos := 0
	count := 0
	for {
		next := strings.index(text[pos:], "\"claude-")
		if next == -1 {break}

		start := pos + next + 1
		end := start
		for end < len(text) && text[end] != '"' {end += 1}
		if end >= len(text) {break}

		name := text[start:end]

		obj_start := end
		for obj_start < len(text) && text[obj_start] != '{' {obj_start += 1}
		if obj_start >= len(text) {
			pos = end + 1
			continue
		}

		depth := 1
		obj_end := obj_start + 1
		for obj_end < len(text) && depth > 0 {
			switch text[obj_end] {
			case '{':
				depth += 1
			case '}':
				depth -= 1
			}
			obj_end += 1
		}
		if depth != 0 {break}

		obj := text[obj_start:obj_end]

		p: Model_Price
		p.input_per_token = find_float_field(obj, "\"input_cost_per_token\":")
		p.output_per_token = find_float_field(obj, "\"output_cost_per_token\":")
		p.cache_read_per_token = find_float_field(obj, "\"cache_read_input_token_cost\":")
		p.cache_create_per_token = find_float_field(obj, "\"cache_creation_input_token_cost\":")

		// DEBUG
		count += 1
		if count <= 5 || name == "claude-opus-4-8" {
			fmt.eprintfln(
				"zlr: parsed %s in=%v out=%v (obj_len=%d)",
				name,
				p.input_per_token,
				p.output_per_token,
				obj_end - obj_start,
			)
		}

		if p.input_per_token > 0 && p.output_per_token > 0 {
			out[strings.clone(name)] = p
		}

		pos = obj_end
	}
	fmt.eprintfln("zlr: total parse iterations: %d, map size: %d", count, len(out))
}

find_float_field :: proc(text: string, key: string) -> f64 {
	idx := strings.index(text, key)
	if idx == -1 {return 0}

	i := idx + len(key)
	for i < len(text) && (text[i] == ' ' || text[i] == '\t') {i += 1}

	j := i
	for j < len(text) {
		ch := text[j]
		if (ch >= '0' && ch <= '9') ||
		   ch == '.' ||
		   ch == '-' ||
		   ch == '+' ||
		   ch == 'e' ||
		   ch == 'E' {
			j += 1
			continue
		}
		break
	}
	if j == i {return 0}

	n, _ := strconv.parse_f64(text[i:j])
	return n
}
