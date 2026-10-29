package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Network JSON import from a URL, mirroring
// rust-egui/src/json_import.rs: the same accepted document
// shapes, the same defaults, the same http://-only fetching
// (no TLS, no new dependency), and the same error cases.
//
// Fetching and parsing run on a worker thread (see the
// import job in main.odin, which follows the image-loading
// thread pattern in src/images.odin: the worker fills a
// mutex-guarded result, the main thread polls it once per
// frame and does the database inserts itself), so a slow
// server or a large document never blocks the UI.
//
// Dependencies: only Odin's standard library —
// core:encoding/json for parsing and core:net TCP for
// fetching. core:net has no TLS, so https:// is rejected
// with a clear message, exactly like the Rust version.
//
// Strings: parse_recipes clones every string it keeps into
// the returned recipes (the parsed json.Value is destroyed
// before returning), so a recipe never aliases the fetched
// body or the parse scratch. Callers own the returned
// recipes and their strings.

// ---- Document parsing ----

json_string_field :: proc(obj: json.Object, key: string) -> (string, bool, string) {
	value, ok := obj[key]
	if !ok {
		return "", false, ""
	}
	#partial switch s in value {
	case json.String:
		return s, true, ""
	case json.Null:
		return "", false, ""
	case:
		return "", false, fmt.tprintf("Could not parse recipe JSON: field %q must be a string.", key)
	}
}

json_servings_field :: proc(obj: json.Object) -> (int, string) {
	value, ok := obj["servings"]
	if !ok {
		return 0, ""
	}
	#partial switch n in value {
	case json.Integer:
		return int(n), ""
	case json.Float:
		if n != f64(int(n)) {
			return 0, "Could not parse recipe JSON: servings must be a whole number."
		}
		return int(n), ""
	case json.Null:
		return 0, ""
	case:
		return 0, "Could not parse recipe JSON: servings must be a whole number."
	}
}

// Parse one recipe object. title is required and must not
// be blank; everything else defaults, like the Rust
// version's serde defaults: description, notes, ingredients
// and steps empty, image_path null ("" here, stored as NULL
// by db.odin's insert_recipe), servings 0.
parse_one_recipe :: proc(value: json.Value) -> (Recipe, string) {
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, "Could not parse recipe JSON: each recipe must be an object."
	}
	title, present, terr := json_string_field(obj, "title")
	if terr != "" {
		return {}, terr
	}
	if !present || strings.trim_space(title) == "" {
		return {}, "Imported recipe is missing a title."
	}
	recipe: Recipe
	recipe.title = strings.clone(title)

	description, _, derr := json_string_field(obj, "description")
	if derr != "" {
		return {}, derr
	}
	recipe.description = strings.clone(description)

	servings, serr := json_servings_field(obj)
	if serr != "" {
		return {}, serr
	}
	recipe.servings = servings

	image_path, _, ierr := json_string_field(obj, "image_path")
	if ierr != "" {
		return {}, ierr
	}
	recipe.image_path = strings.clone(image_path)

	notes, _, nerr := json_string_field(obj, "notes")
	if nerr != "" {
		return {}, nerr
	}
	recipe.notes = strings.clone(notes)

	if ingredients_value, ok := obj["ingredients"]; ok {
		if _, is_null := ingredients_value.(json.Null); is_null {
			// Null reads as missing: empty, like the Rust default.
		} else if arr, is_arr := ingredients_value.(json.Array); is_arr {
			ingredients := make([dynamic]Ingredient)
			for item in arr {
				ingredient_obj, is_iobj := item.(json.Object)
				if !is_iobj {
					return {}, "Could not parse recipe JSON: each ingredient must be an object."
				}
				amount, _, aerr := json_string_field(ingredient_obj, "amount")
				if aerr != "" {
					return {}, aerr
				}
				unit, _, uerr := json_string_field(ingredient_obj, "unit")
				if uerr != "" {
					return {}, uerr
				}
				name, _, nerr := json_string_field(ingredient_obj, "name")
				if nerr != "" {
					return {}, nerr
				}
				append(&ingredients, Ingredient{
					amount = strings.clone(amount),
					unit   = strings.clone(unit),
					name   = strings.clone(name),
				})
			}
			recipe.ingredients = ingredients[:]
		} else {
			return {}, "Could not parse recipe JSON: ingredients must be an array."
		}
	}

	if steps_value, ok := obj["steps"]; ok {
		if _, is_null := steps_value.(json.Null); is_null {
			// Null reads as missing: empty, like the Rust default.
		} else if arr, is_arr := steps_value.(json.Array); is_arr {
			steps := make([dynamic]string)
			for item in arr {
				step, is_str := item.(json.String)
				if !is_str {
					return {}, "Could not parse recipe JSON: each step must be a string."
				}
				append(&steps, strings.clone(step))
			}
			recipe.steps = steps[:]
		} else {
			return {}, "Could not parse recipe JSON: steps must be an array."
		}
	}
	return recipe, ""
}

// Parse a whole document in any of the three accepted
// shapes: a single recipe object, a bare array of recipe
// objects, or an object with a "recipes" array. An empty
// collection parses to zero recipes, not an error.
parse_recipes :: proc(text: string) -> ([]Recipe, string) {
	// parse_integers keeps whole numbers as integers, so a
	// fractional servings value stays a float and is rejected
	// by json_servings_field, like the Rust serde check.
	value, err := json.parse(text, parse_integers = true)
	if err != .None {
		return nil, fmt.tprintf("Could not parse recipe JSON: %v.", err)
	}
	defer json.destroy_value(value)

	#partial switch doc in value {
	case json.Array:
		recipes := make([dynamic]Recipe)
		for item in doc {
			recipe, perr := parse_one_recipe(item)
			if perr != "" {
				return nil, perr
			}
			append(&recipes, recipe)
		}
		return recipes[:], ""
	case json.Object:
		if recipes_value, ok := doc["recipes"]; ok {
			arr, is_arr := recipes_value.(json.Array)
			if !is_arr {
				return nil, "The \"recipes\" field must be an array of recipes."
			}
			recipes := make([dynamic]Recipe)
			for item in arr {
				recipe, perr := parse_one_recipe(item)
				if perr != "" {
					return nil, perr
				}
				append(&recipes, recipe)
			}
			return recipes[:], ""
		}
		if _, has_title := doc["title"]; has_title {
			recipe, perr := parse_one_recipe(value)
			if perr != "" {
				return nil, perr
			}
			// Not a slice literal: a literal returned here
			// would be backed by this stack frame (the same
			// lesson as the seed data in src/recipes.odin).
			recipes := make([dynamic]Recipe)
			append(&recipes, recipe)
			return recipes[:], ""
		}
		return nil, "JSON must be a single recipe, an array of recipes, or an object with a \"recipes\" array."
	case:
		return nil, "JSON must be a single recipe, an array of recipes, or an object with a \"recipes\" array."
	}
}

// ---- HTTP fetching (http:// only) ----

Http_Url :: struct {
	host: string,
	port: int,
	path: string,
}

parse_http_url :: proc(url: string) -> (Http_Url, string) {
	if strings.has_prefix(url, "https://") {
		return {}, "HTTPS URLs are not supported by this importer; use an http:// URL (for example, the local test server)."
	}
	if !strings.has_prefix(url, "http://") {
		return {}, "URL must start with http://."
	}
	rest := strings.trim_prefix(url, "http://")
	host_port, path := rest, "/"
	if idx := strings.index_byte(rest, '/'); idx >= 0 {
		host_port = rest[:idx]
		path = rest[idx:]
	}
	if host_port == "" {
		return {}, "URL is missing a host."
	}
	host, port := host_port, 80
	if idx := strings.last_index_byte(host_port, ':'); idx >= 0 {
		port_text := host_port[idx+1:]
		if port_text != "" {
			parsed, parse_ok := strconv.parse_int(port_text)
			if !parse_ok || parsed < 0 || parsed > 65535 {
				return {}, fmt.tprintf("Invalid port in URL: %s.", port_text)
			}
			host = host_port[:idx]
			port = int(parsed)
		}
	}
	if host == "" {
		return {}, "URL is missing a host."
	}
	return Http_Url{host = host, port = port, path = path}, ""
}

Fetch_Outcome :: union {
	string, // body
	Fetch_Redirect,
}

Fetch_Redirect :: struct {
	location: string,
}

// Decode a chunked transfer-encoding body: hex size lines
// (with optional ";extension" suffixes), data, CRLF,
// repeated, ending with a zero-size chunk and trailing
// headers up to a blank line. Mirrors the Rust decoder.
decode_chunked :: proc(body: []byte) -> ([]byte, string) {
	out := make([dynamic]byte)
	rest := body
	for {
		line_end := -1
		for i := 0; i + 1 < len(rest); i += 1 {
			if rest[i] == '\r' && rest[i+1] == '\n' {
				line_end = i
				break
			}
		}
		if line_end < 0 {
			return nil, "Malformed chunked response."
		}
		size_text := string(rest[:line_end])
		if semi := strings.index_byte(size_text, ';'); semi >= 0 {
			size_text = size_text[:semi]
		}
		size_text = strings.trim_space(size_text)
		size_u, ok := strconv.parse_uint(size_text, 16)
		if !ok {
			return nil, "Malformed chunked response."
		}
		size := int(size_u)
		rest = rest[line_end+2:]
		if size == 0 {
			break
		}
		if len(rest) < size + 2 {
			return nil, "Truncated chunked response."
		}
		append(&out, ..rest[:size])
		rest = rest[size+2:]
	}
	return out[:], ""
}

fetch_once :: proc(url: Http_Url) -> (Fetch_Outcome, string) {
	socket, err := net.dial_tcp(url.host, url.port)
	if err != nil {
		return nil, fmt.tprintf("Could not connect to %s: %v.", url.host, err)
	}
	defer net.close(socket)

	host_header := url.host
	if url.port != 80 {
		host_header = fmt.tprintf("%s:%d", url.host, url.port)
	}
	request := fmt.tprintf("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nUser-Agent: recipe-manager-test\r\nAccept: application/json\r\n\r\n", url.path, host_header)
	if _, werr := net.send_tcp(socket, transmute([]byte)request); werr != .None {
		return nil, fmt.tprintf("Could not send request: %v.", werr)
	}
	raw := make([dynamic]byte)
	buf := make([]byte, 4096)
	for {
		n, rerr := net.recv_tcp(socket, buf)
		if n > 0 {
			append(&raw, ..buf[:n])
		}
		// A graceful close is 0 bytes with no error; any
		// error also ends the read (the response is checked
		// for completeness below, via Content-Length).
		if rerr != .None || n == 0 {
			break
		}
	}
	raw_bytes := raw[:]

	header_end := -1
	for i := 0; i + 3 < len(raw_bytes); i += 1 {
		if raw_bytes[i] == '\r' && raw_bytes[i+1] == '\n' && raw_bytes[i+2] == '\r' && raw_bytes[i+3] == '\n' {
			header_end = i
			break
		}
	}
	if header_end < 0 {
		return nil, "Response was not valid HTTP."
	}
	headers_text := string(raw_bytes[:header_end])
	lines := strings.split_lines(headers_text, context.temp_allocator)
	if len(lines) == 0 {
		return nil, "Response was not valid HTTP."
	}
	status_fields := strings.fields(lines[0], context.temp_allocator)
	if len(status_fields) < 2 {
		return nil, "Response was not valid HTTP."
	}
	status, sok := strconv.parse_int(status_fields[1])
	if !sok {
		return nil, "Response was not valid HTTP."
	}
	location := ""
	chunked := false
	content_length := -1
	for line in lines[1:] {
		if idx := strings.index_byte(line, ':'); idx >= 0 {
			name := strings.to_lower(strings.trim_space(line[:idx]), context.temp_allocator)
			value := strings.trim_space(line[idx+1:])
			switch name {
			case "location":
				location = value
			case "transfer-encoding":
				if strings.contains(strings.to_lower(value, context.temp_allocator), "chunked") {
					chunked = true
				}
			case "content-length":
				if parsed, ok := strconv.parse_int(value); ok {
					content_length = int(parsed)
				}
			}
		}
	}
	switch status {
	case 301, 302, 303, 307, 308:
		if location != "" {
			return Fetch_Redirect{location = strings.clone(location)}, ""
		}
	}
	if status != 200 {
		return nil, fmt.tprintf("Server returned HTTP %d for %s:%d.", status, url.host, url.port)
	}
	body_bytes := raw_bytes[header_end+4:]
	body: []byte
	if chunked {
		decoded, derr := decode_chunked(body_bytes)
		if derr != "" {
			return nil, derr
		}
		body = decoded
	} else if content_length >= 0 {
		if len(body_bytes) < content_length {
			return nil, "Response ended before the full body arrived."
		}
		body = body_bytes[:content_length]
	} else {
		body = body_bytes
	}
	if !utf8.valid_string(string(body)) {
		return nil, "Response was not valid UTF-8."
	}
	return strings.clone(string(body)), ""
}

resolve_redirect :: proc(current: Http_Url, location: string) -> (string, string) {
	if strings.has_prefix(location, "http://") || strings.has_prefix(location, "https://") {
		return location, ""
	}
	host := current.host
	if current.port != 80 {
		host = fmt.tprintf("%s:%d", current.host, current.port)
	}
	if strings.has_prefix(location, "/") {
		path := strings.trim_prefix(location, "/")
		return fmt.tprintf("http://%s/%s", host, path), ""
	}
	// A relative path resolves against the current path's directory.
	base := "/"
	if idx := strings.last_index_byte(current.path, '/'); idx >= 0 {
		base = current.path[:idx+1]
	}
	return fmt.tprintf("http://%s%s%s", host, base, location), ""
}

fetch_url :: proc(url: string) -> (string, string) {
	current := url
	for _ in 0..<4 {
		parsed, perr := parse_http_url(current)
		if perr != "" {
			return "", perr
		}
		outcome, ferr := fetch_once(parsed)
		if ferr != "" {
			return "", ferr
		}
		switch result in outcome {
		case string:
			return result, ""
		case Fetch_Redirect:
			resolved, rerr := resolve_redirect(parsed, result.location)
			if rerr != "" {
				return "", rerr
			}
			current = resolved
		}
	}
	return "", "Too many redirects."
}

// Fetch a document and parse it. This is what the worker
// thread runs, so a slow server or a large document never
// blocks the UI.
fetch_and_parse :: proc(url: string) -> ([]Recipe, string) {
	body, err := fetch_url(url)
	if err != "" {
		return nil, err
	}
	defer delete(body)
	return parse_recipes(body)
}
