package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"

// Network JSON import tests (src/json_import.odin): parsing in
// all accepted shapes, defaults, and error cases, plus fetching
// from a local one-shot server. Parsing mirrors the Rust
// version's json_import tests, including its fixture-shaped
// single recipe below. Successful parses are freed with
// free_imported_recipes; error strings are heap allocations
// that these tests leave (like the DB layer's cstring leaks
// the existing tests already log — leaks are logged, not
// failures).

TEST_SINGLE :: `{
	"title": "Mushroom Risotto",
	"description": "Creamy rice.",
	"servings": 4,
	"ingredients": [{"amount": "1", "unit": "lb", "name": "mushrooms"}],
	"steps": ["Cook it."]
}`

@(test)
test_json_import_parse_single_recipe_object :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(TEST_SINGLE)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) != 1 {
		return
	}
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	testing.expect_value(t, recipes[0].description, "Creamy rice.")
	testing.expect_value(t, recipes[0].servings, 4)
	testing.expect_value(t, len(recipes[0].ingredients), 1)
	if len(recipes[0].ingredients) == 1 {
		testing.expect_value(t, recipes[0].ingredients[0].name, "mushrooms")
		testing.expect_value(t, recipes[0].ingredients[0].amount, "1")
		testing.expect_value(t, recipes[0].ingredients[0].unit, "lb")
	}
	testing.expect_value(t, len(recipes[0].steps), 1)
	if len(recipes[0].steps) == 1 {
		testing.expect_value(t, recipes[0].steps[0], "Cook it.")
	}
}

@(test)
test_json_import_parse_bare_array :: proc(t: ^testing.T) {
	doc := fmt.aprintf("[%s, %s]", TEST_SINGLE, TEST_SINGLE)
	defer delete(doc)
	recipes, err := parse_recipes(doc)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 2)
}

// NOTE: JSON documents in these tests are built with
// strings.concatenate, never fmt.aprintf with a format string
// containing braces: Odin's fmt interprets `{` in a format
// string as the start of a directive, so aprintf(`{"recipes":
// [%s]}`, ...) silently produces garbage (the opening brace
// eats into `%!(MISSING CLOSE BRACE)`) and the parse then
// fails with Unexpected_Token. Concatenation has no such trap.
@(test)
test_json_import_parse_wrapped_collection :: proc(t: ^testing.T) {
	doc := strings.concatenate({`{"recipes": [`, TEST_SINGLE, `]}`})
	defer delete(doc)
	recipes, err := parse_recipes(doc)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	}
}

@(test)
test_json_import_parse_minimal_recipe_uses_defaults :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"title": "Toast"}`)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) != 1 {
		return
	}
	testing.expect_value(t, recipes[0].title, "Toast")
	testing.expect_value(t, recipes[0].description, "")
	testing.expect_value(t, recipes[0].servings, 0)
	testing.expect_value(t, recipes[0].image_path, "")
	testing.expect_value(t, len(recipes[0].ingredients), 0)
	testing.expect_value(t, len(recipes[0].steps), 0)
	testing.expect_value(t, recipes[0].notes, "")
}

@(test)
test_json_import_parse_null_image_path_is_empty :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"title": "Toast", "image_path": null}`)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].image_path, "")
	}
}

@(test)
test_json_import_parse_empty_collection :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"recipes": []}`)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 0)
}

@(test)
test_json_import_parse_invalid_json_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes("{ this is not json")
	testing.expect(t, err != "", "invalid JSON must be an error")
}

@(test)
test_json_import_parse_object_without_recipes_or_title_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"nope": 1}`)
	testing.expect(t, err != "", "an object with neither recipes nor title must be an error")
}

@(test)
test_json_import_parse_recipe_without_title_is_an_error :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"description": "No title here."}`)
	testing.expect(t, err != "", "a recipe without a title must be an error")
	_, err = parse_recipes(`{"title": "   "}`)
	testing.expect(t, err != "", "a recipe with a blank title must be an error")
}

@(test)
test_json_import_parse_recipes_field_must_be_an_array :: proc(t: ^testing.T) {
	_, err := parse_recipes(`{"recipes": {"title": "Toast"}}`)
	testing.expect(t, err != "", "a non-array recipes field must be an error")
}

@(test)
test_json_import_parse_ingredient_defaults :: proc(t: ^testing.T) {
	recipes, err := parse_recipes(`{"title": "Toast", "ingredients": [{"name": "bread"}]}`)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) == 1 && len(recipes[0].ingredients) == 1 {
		testing.expect_value(t, recipes[0].ingredients[0].name, "bread")
		testing.expect_value(t, recipes[0].ingredients[0].amount, "")
		testing.expect_value(t, recipes[0].ingredients[0].unit, "")
	}
}

@(test)
test_json_import_url_parsing_defaults_and_https_rejection :: proc(t: ^testing.T) {
	url, err := parse_http_url("http://localhost:8000/recipes.json")
	testing.expect(t, err == "", err)
	testing.expect_value(t, url.host, "localhost")
	testing.expect_value(t, url.port, 8000)
	testing.expect_value(t, url.path, "/recipes.json")
	url, err = parse_http_url("http://example.com")
	testing.expect(t, err == "", err)
	testing.expect_value(t, url.port, 80)
	testing.expect_value(t, url.path, "/")
	_, err = parse_http_url("https://example.com/recipes.json")
	testing.expect(t, err != "", "https must be rejected")
	_, err = parse_http_url("http:///recipes.json")
	testing.expect(t, err != "", "a missing host must be an error")
}

@(test)
test_json_import_chunked_body_decodes :: proc(t: ^testing.T) {
	chunked_input := "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
	decoded, err := decode_chunked(transmute([]byte)chunked_input)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer delete(decoded)
	testing.expect_value(t, string(decoded), "hello world")
}

// --- One-shot local server for the fetch tests -----------------------
// The listener is bound by the test thread on the loopback
// interface with port 0, and bound_endpoint reports the port
// the OS picked; the listener is then handed to a server
// thread that accepts exactly one connection (two, for the
// redirect test), reads the request, and writes the response.
// The test thread fetches, then joins the server thread, so no
// server thread outlives its test.

Serve_Job :: struct {
	listener:        net.TCP_Socket,
	response:        []byte,
	second_response: []byte,
	serve_second:    bool,
}

serve_one :: proc(listener: net.TCP_Socket, response: []byte) {
	client, _, accept_err := net.accept_tcp(listener)
	if accept_err != .None {
		return
	}
	defer net.close(client)
	// Read (and ignore) the request: the client sends one
	// small request, so a single recv is enough here.
	request_buf: [4096]byte
	net.recv_tcp(client, request_buf[:])
	// Send the whole response, in case one send does not take it.
	sent := 0
	for sent < len(response) {
		n, send_err := net.send_tcp(client, response[sent:])
		if send_err != .None || n <= 0 {
			return
		}
		sent += n
	}
}

serve_once_job :: proc(job: ^Serve_Job) {
	serve_one(job.listener, job.response)
	if job.serve_second {
		serve_one(job.listener, job.second_response)
	}
}

listen_on_test_port :: proc(t: ^testing.T) -> (net.TCP_Socket, int) {
	// listen_tcp returns a Network_Error union, so failure is
	// a non-nil union, not a .None enum value.
	socket, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		testing.fail(t)
		return {}, 0
	}
	bound, berr := net.bound_endpoint(socket)
	if berr != .None {
		net.close(socket)
		testing.fail(t)
		return {}, 0
	}
	return socket, bound.port
}

@(test)
test_json_import_fetch_from_a_local_server :: proc(t: ^testing.T) {
	listener, port := listen_on_test_port(t)
	if port == 0 {
		return
	}
	defer net.close(listener)
	body := strings.concatenate({`{"recipes": [`, TEST_SINGLE, `]}`})
	defer delete(body)
	response := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
		len(body), body,
	)
	defer delete(response)
	job := new(Serve_Job)
	job.listener = listener
	job.response = transmute([]byte)response
	server := thread.create_and_start_with_poly_data(job, serve_once_job)
	recipes, err := fetch_and_parse(fmt.tprintf("http://127.0.0.1:%d/recipes.json", port))
	thread.join(server)
	thread.destroy(server)
	free(job)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	}
}

@(test)
test_json_import_fetch_follows_a_redirect :: proc(t: ^testing.T) {
	listener, port := listen_on_test_port(t)
	if port == 0 {
		return
	}
	defer net.close(listener)
	body := strings.concatenate({`{"recipes": [`, TEST_SINGLE, `]}`})
	defer delete(body)
	second := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
		len(body), body,
	)
	defer delete(second)
	first := "HTTP/1.1 302 Found\r\nLocation: /recipes.json\r\nContent-Length: 0\r\n\r\n"
	job := new(Serve_Job)
	job.listener = listener
	job.response = transmute([]byte)first
	job.second_response = transmute([]byte)second
	job.serve_second = true
	server := thread.create_and_start_with_poly_data(job, serve_once_job)
	recipes, err := fetch_and_parse(fmt.tprintf("http://127.0.0.1:%d/old.json", port))
	thread.join(server)
	thread.destroy(server)
	free(job)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	}
}

@(test)
test_json_import_fetch_non_200_is_an_error :: proc(t: ^testing.T) {
	listener, port := listen_on_test_port(t)
	if port == 0 {
		return
	}
	defer net.close(listener)
	response := "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot found"
	job := new(Serve_Job)
	job.listener = listener
	job.response = transmute([]byte)response
	server := thread.create_and_start_with_poly_data(job, serve_once_job)
	_, err := fetch_url(fmt.tprintf("http://127.0.0.1:%d/missing.json", port))
	thread.join(server)
	thread.destroy(server)
	free(job)
	testing.expect(t, err != "", "a 404 must be an error")
	// The error names the status, like the Rust version's.
	testing.expect(t, strings.contains(err, "404"), fmt.tprintf("error was: %s", err))
}
