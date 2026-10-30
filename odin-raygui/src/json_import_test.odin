package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

// Unit tests for network JSON import (src/json_import.odin),
// mirroring the Rust version's json_import tests: all three
// document shapes, defaults, error cases, chunked bodies,
// URL parsing, and fetching from a local one-shot server
// (including a non-200 error and a fetch-then-insert round
// trip through the existing DB layer). The one-shot server
// binds port 0 first, so its port is known before the
// fetch, and serves exactly one response in a thread —
// like the Rust serve_once helper. The server thread is
// not joined: it returns on its own after serving once,
// and every test below connects to it, so it can never be
// left blocked in accept by a passing test.

JSON_SINGLE :: `{
	"title": "Mushroom Risotto",
	"description": "Creamy rice.",
	"servings": 4,
	"image_path": null,
	"notes": "Stir often.",
	"ingredients": [{"amount": "1", "unit": "lb", "name": "mushrooms"}],
	"steps": ["Cook it."]
}`

@(test)
test_json_parse_single_recipe_object :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(JSON_SINGLE)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	testing.expect_value(t, recipes[0].description, "Creamy rice.")
	testing.expect_value(t, recipes[0].servings, 4)
	testing.expect_value(t, recipes[0].notes, "Stir often.")
	testing.expect_value(t, len(recipes[0].ingredients), 1)
	testing.expect_value(t, recipes[0].ingredients[0].name, "mushrooms")
	testing.expect_value(t, recipes[0].ingredients[0].amount, "1")
	testing.expect_value(t, recipes[0].ingredients[0].unit, "lb")
	testing.expect_value(t, len(recipes[0].steps), 1)
	testing.expect_value(t, recipes[0].steps[0], "Cook it.")
}

@(test)
test_json_parse_bare_array :: proc(t: ^testing.T) {
	text := fmt.tprintf("[%s, %s]", JSON_SINGLE, JSON_SINGLE)
	recipes, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 2)
}

@(test)
test_json_parse_wrapped_collection :: proc(t: ^testing.T) {
	// No tprintf here: Odin fmt treats a literal { in the
	// format string as a verb opener and mangles it.
	text := strings.concatenate({`{"recipes": [`, JSON_SINGLE, `]}`}, context.temp_allocator)
	recipes, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
}

@(test)
test_json_parse_minimal_recipe_uses_defaults :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"title": "Toast"}`)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Toast")
	testing.expect_value(t, recipes[0].description, "")
	testing.expect_value(t, recipes[0].servings, 0)
	testing.expect_value(t, recipes[0].image_path, "")
	testing.expect_value(t, len(recipes[0].ingredients), 0)
	testing.expect_value(t, len(recipes[0].steps), 0)
	testing.expect_value(t, recipes[0].notes, "")
}

@(test)
test_json_parse_empty_collection :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"recipes": []}`)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 0)
}

@(test)
test_json_parse_invalid_json_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes("{ this is not json")
	testing.expect(t, err != "", "invalid JSON should be an error")
}

@(test)
test_json_parse_object_without_recipes_or_title_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"nope": 1}`)
	testing.expect(t, err != "", "object with neither recipes nor title should be an error")
}

@(test)
test_json_parse_recipe_without_title_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"description": "No title here."}`)
	testing.expect(t, err != "", "recipe without a title should be an error")
	_, err = parse_recipes(`{"title": "   "}`)
	testing.expect(t, err != "", "recipe with a blank title should be an error")
}

@(test)
test_json_parse_recipes_field_must_be_an_array :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"recipes": {"title": "Toast"}}`)
	testing.expect(t, err != "", "a non-array recipes field should be an error")
}

@(test)
test_json_parse_servings_must_be_a_whole_number :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"title": "Toast", "servings": 4.5}`)
	testing.expect(t, err != "", "fractional servings should be an error")
	_, err = parse_recipes(`{"title": "Toast", "servings": "four"}`)
	testing.expect(t, err != "", "string servings should be an error")
}

@(test)
test_json_url_parsing_defaults_and_https_rejection :: proc(t: ^testing.T) {
	url, err := parse_http_url("http://localhost:8000/recipes.json")
	testing.expectf(t, err == "", "parse_http_url: %s", err)
	testing.expect_value(t, url.host, "localhost")
	testing.expect_value(t, url.port, 8000)
	testing.expect_value(t, url.path, "/recipes.json")
	url, err = parse_http_url("http://example.com")
	testing.expectf(t, err == "", "parse_http_url: %s", err)
	testing.expect_value(t, url.port, 80)
	testing.expect_value(t, url.path, "/")
	_, err = parse_http_url("https://example.com/recipes.json")
	testing.expect(t, err != "", "https:// should be rejected")
	_, err = parse_http_url("http:///recipes.json")
	testing.expect(t, err != "", "a URL without a host should be an error")
	_, err = parse_http_url("http://example.com:abc/recipes.json")
	testing.expect(t, err != "", "a non-numeric port should be an error")
}

@(test)
test_json_chunked_body_decodes :: proc(t: ^testing.T) {
	chunked_input := "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
	decoded, err := decode_chunked(transmute([]byte)chunked_input)
	testing.expectf(t, err == "", "decode_chunked: %s", err)
	testing.expect_value(t, string(decoded), "hello world")
}

// ---- One-shot local server ----

Serve_Once_Args :: struct {
	listener: net.TCP_Socket,
	response: string,
}

serve_once_thread :: proc(args: ^Serve_Once_Args) {
	client, _, aerr := net.accept_tcp(args.listener)
	if aerr != .None {
		return
	}
	defer net.close(client)
	defer net.close(args.listener)
	buf := make([]byte, 4096)
	// Read (and discard) the request before responding, so
	// the client is not still writing when we close.
	_, _ = net.recv_tcp(client, buf)
	remaining := transmute([]byte)args.response
	for len(remaining) > 0 {
		n, serr := net.send_tcp(client, remaining)
		if serr != .None || n <= 0 {
			return
		}
		remaining = remaining[n:]
	}
}

// Bind a listener on an ephemeral loopback port and start
// a thread that serves response once. Returns the port and
// the thread; the caller fetches from that port.
serve_once :: proc(t: ^testing.T, response: string) -> int {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, lerr := net.listen_tcp(endpoint)
	testing.expectf(t, lerr == nil, "listen_tcp: %v", lerr)
	bound, berr := net.bound_endpoint(listener)
	testing.expectf(t, berr == .None, "bound_endpoint: %v", berr)
	args := new(Serve_Once_Args)
	args.listener = listener
	// Heap-cloned, not temp: the server thread reads this
	// after the test thread has made other temp allocations.
	args.response = strings.clone(response)
	thread.create_and_start_with_poly_data(args, serve_once_thread)
	return bound.port
}

@(test)
test_json_fetch_from_a_local_server :: proc(t: ^testing.T) {
	body := strings.concatenate({`{"recipes": [`, JSON_SINGLE, `]}`}, context.temp_allocator)
	response := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
	port := serve_once(t, response)
	recipes, err := fetch_and_parse(fmt.tprintf("http://127.0.0.1:%d/recipes.json", port))
	testing.expectf(t, err == "", "fetch_and_parse: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
}

@(test)
test_json_fetch_non_200_is_an_error :: proc(t: ^testing.T) {
	port := serve_once(t, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot found")
	_, err := fetch_url(fmt.tprintf("http://127.0.0.1:%d/missing.json", port))
	testing.expect(t, err != "", "a 404 should be an error")
	// The message names the status, like the Rust version's.
	found_404 := false
	for i := 0; i + 3 <= len(err); i += 1 {
		if err[i:i+3] == "404" {
			found_404 = true
		}
	}
	testing.expect(t, found_404, "404 error should name the status")
}

@(test)
test_json_fetch_then_insert_round_trip :: proc(t: ^testing.T) {
	db, path := open_seeded_test_db(t, "json-import")
	defer os.remove(path)
	defer close_database(db)

	body := strings.concatenate({`{"recipes": [`, JSON_SINGLE, `]}`}, context.temp_allocator)
	response := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
	port := serve_once(t, response)
	recipes, err := fetch_and_parse(fmt.tprintf("http://127.0.0.1:%d/recipes.json", port))
	testing.expectf(t, err == "", "fetch_and_parse: %s", err)
	testing.expect_value(t, len(recipes), 1)
	for recipe in recipes {
		id, ierr := insert_recipe(db, recipe)
		testing.expectf(t, ierr == "", "insert_recipe: %s", ierr)
		testing.expect(t, id > 0)
	}
	loaded, lerr := load_recipes(db)
	testing.expectf(t, lerr == "", "load_recipes: %s", lerr)
	// 3 seed recipes plus the 1 imported one.
	testing.expect_value(t, len(loaded), 4)
	testing.expect_value(t, loaded[3].title, "Mushroom Risotto")
	testing.expect_value(t, len(loaded[3].ingredients), 1)
	testing.expect_value(t, len(loaded[3].steps), 1)
}

// ---- Raw-file JSON import (src/json_import.odin's
// import_from_file), mirroring rust-egui's 5 new tests:
// single recipe and collection from temp files, bare array
// plus the empty collection, invalid-JSON and missing-file
// errors, and the shared fixtures in test-data/ read from
// disk end to end. The fixture directory is found by
// probing candidates because `odin test src` may run with
// the stack directory or the repo root as its working
// directory.

write_temp_import_file :: proc(t: ^testing.T, name: string, content: string) -> string {
	path := fmt.tprintf("/tmp/odin-raygui-import-test-%s.json", name)
	werr := os.write_entire_file(path, content)
	testing.expectf(t, werr == nil, "write_entire_file %s: %v", path, werr)
	return path
}

@(test)
test_file_import_single_recipe :: proc(t: ^testing.T) {
	path := write_temp_import_file(t, "single", JSON_SINGLE)
	defer os.remove(path)
	recipes, err := import_from_file(path)
	testing.expectf(t, err == "", "import_from_file: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
}

@(test)
test_file_import_collection :: proc(t: ^testing.T) {
	body := strings.concatenate({`{"recipes": [`, JSON_SINGLE, `, `, JSON_SINGLE, `]}`}, context.temp_allocator)
	path := write_temp_import_file(t, "collection", body)
	defer os.remove(path)
	recipes, err := import_from_file(path)
	testing.expectf(t, err == "", "import_from_file: %s", err)
	testing.expect_value(t, len(recipes), 2)
}

@(test)
test_file_import_bare_array_and_empty_collection :: proc(t: ^testing.T) {
	array_body := strings.concatenate({`[`, JSON_SINGLE, `]`}, context.temp_allocator)
	path := write_temp_import_file(t, "array", array_body)
	defer os.remove(path)
	recipes, err := import_from_file(path)
	testing.expectf(t, err == "", "import_from_file: %s", err)
	testing.expect_value(t, len(recipes), 1)

	empty_path := write_temp_import_file(t, "empty", `{"recipes": []}`)
	defer os.remove(empty_path)
	recipes, err = import_from_file(empty_path)
	testing.expectf(t, err == "", "import_from_file: %s", err)
	testing.expect_value(t, len(recipes), 0)
}

@(test)
test_file_import_invalid_and_missing :: proc(t: ^testing.T) {
	path := write_temp_import_file(t, "invalid", "{ this is not json")
	defer os.remove(path)
	_, err := import_from_file(path)
	testing.expect(t, err != "", "invalid JSON should be an error")
	testing.expect(t, strings.contains(err, "Could not parse recipe JSON"), "invalid-JSON error should use the parse path, got: %s", err)

	// A path that was never written: the missing-file error
	// names the file, like the Rust version's.
	missing := "/tmp/odin-raygui-import-test-missing.json"
	os.remove(missing)
	_, err = import_from_file(missing)
	testing.expect(t, err != "", "a missing file should be an error")
	testing.expect(t, strings.contains(err, "Could not read file"), "missing-file error should name the read failure, got: %s", err)
}

find_test_data_dir :: proc(t: ^testing.T) -> string {
	// The probe file is recipe-single.json, present in
	// every copy of test-data/.
	candidates := []string{"../test-data", "test-data", "../../test-data"}
	for candidate in candidates {
		if os.exists(fmt.tprintf("%s/recipe-single.json", candidate)) {
			return candidate
		}
	}
	testing.expect(t, false, "test-data/ not found under ../test-data, test-data, or ../../test-data")
	return ""
}

@(test)
test_file_import_shared_fixtures_from_disk :: proc(t: ^testing.T) {
	dir := find_test_data_dir(t)

	recipes, err := import_from_file(fmt.tprintf("%s/recipe-single.json", dir))
	testing.expectf(t, err == "", "recipe-single.json: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	testing.expect_value(t, len(recipes[0].ingredients), 6)
	testing.expect_value(t, len(recipes[0].steps), 5)

	recipes, err = import_from_file(fmt.tprintf("%s/recipes-array.json", dir))
	testing.expectf(t, err == "", "recipes-array.json: %s", err)
	testing.expect_value(t, len(recipes), 2)
	testing.expect_value(t, recipes[0].title, "Pancakes")
	testing.expect_value(t, recipes[1].title, "Greek Salad")

	recipes, err = import_from_file(fmt.tprintf("%s/recipes.json", dir))
	testing.expectf(t, err == "", "recipes.json: %s", err)
	testing.expect_value(t, len(recipes), 3)
	testing.expect_value(t, recipes[0].title, "Fried Chicken")
	testing.expect_value(t, recipes[1].title, "Lasagna")
	testing.expect_value(t, recipes[2].title, "Butter Tarts")

	recipes, err = import_from_file(fmt.tprintf("%s/recipes-empty.json", dir))
	testing.expectf(t, err == "", "recipes-empty.json: %s", err)
	testing.expect_value(t, len(recipes), 0)

	_, err = import_from_file(fmt.tprintf("%s/invalid.json", dir))
	testing.expect(t, err != "", "invalid.json should be an error")
	testing.expect(t, strings.contains(err, "Could not parse recipe JSON"), "invalid.json error should use the parse path, got: %s", err)
}
