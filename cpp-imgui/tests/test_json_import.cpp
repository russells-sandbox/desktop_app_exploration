// Unit tests for URL JSON import (cpp-imgui).
//
// Covers the importer's parsing and fetching exactly as
// rust-egui's json_import tests do: all three document shapes,
// defaults, the empty collection, invalid JSON, missing/blank
// titles, string escapes, chunked bodies, redirects, and a
// non-200 error — plus fetching from a one-shot local server
// (a thread that binds first, so the port is known, then serves
// exactly one response).
//
// Plain asserts only; no test framework. No SQLite, SDL, or Dear
// ImGui dependency: json_import.cpp uses db.h only for the
// Recipe struct, and links no SQLite symbols, so this builds
// with plain g++ (see README "Tests").

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "json_import.h"

namespace {

const char* kSingle =
    "{"
    "  \"title\": \"Mushroom Risotto\","
    "  \"description\": \"Creamy rice.\","
    "  \"servings\": 4,"
    "  \"ingredients\": [{\"amount\": \"1\", \"unit\": \"lb\", \"name\": \"mushrooms\"}],"
    "  \"steps\": [\"Cook it.\"]"
    "}";

// A one-shot local HTTP server: binds first (so the port is
// known), then serves exactly one response in a thread.
struct OneShotServer {
    int port = 0;
    std::thread worker;

    explicit OneShotServer(const std::string& response) {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = 0;
        assert(bind(listener, reinterpret_cast<sockaddr*>(&address),
                    sizeof(address)) == 0);
        assert(listen(listener, 1) == 0);
        socklen_t len = sizeof(address);
        assert(getsockname(listener, reinterpret_cast<sockaddr*>(&address), &len) == 0);
        port = ntohs(address.sin_port);
        worker = std::thread([listener, response]() {
            int stream = accept(listener, nullptr, nullptr);
            if (stream >= 0) {
                char request[4096];
                // Read (and ignore) the request before replying.
                recv(stream, request, sizeof(request), 0);
                size_t sent = 0;
                while (sent < response.size()) {
                    ssize_t n = send(stream, response.data() + sent,
                                     response.size() - sent, 0);
                    if (n <= 0) {
                        break;
                    }
                    sent += static_cast<size_t>(n);
                }
                close(stream);
            }
            close(listener);
        });
    }

    std::string url(const std::string& path) const {
        return "http://127.0.0.1:" + std::to_string(port) + path;
    }

    ~OneShotServer() {
        if (worker.joinable()) {
            worker.join();
        }
    }
};

std::string response_200(const std::string& body) {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
           std::to_string(body.size()) + "\r\n\r\n" + body;
}

bool parse_ok(const std::string& text, std::vector<Recipe>& recipes) {
    std::string error;
    bool ok = parse_recipes(text, recipes, error);
    if (!ok) {
        std::fprintf(stderr, "unexpected parse error: %s\n", error.c_str());
    }
    return ok;
}

bool parse_fails(const std::string& text) {
    std::vector<Recipe> recipes;
    std::string error;
    bool ok = parse_recipes(text, recipes, error);
    if (ok) {
        std::fprintf(stderr, "unexpected parse success for: %s\n", text.c_str());
    }
    return !ok && !error.empty();
}

}  // namespace

int main() {
    int checks = 0;
    std::vector<Recipe> recipes;
    std::string error;

    // Single recipe object.
    assert(parse_ok(kSingle, recipes));
    ++checks;
    assert(recipes.size() == 1);
    ++checks;
    assert(recipes[0].title == "Mushroom Risotto");
    ++checks;
    assert(recipes[0].description == "Creamy rice.");
    ++checks;
    assert(recipes[0].servings == 4);
    ++checks;
    assert(recipes[0].ingredients.size() == 1);
    ++checks;
    assert(recipes[0].ingredients[0].amount == "1");
    ++checks;
    assert(recipes[0].ingredients[0].unit == "lb");
    ++checks;
    assert(recipes[0].ingredients[0].name == "mushrooms");
    ++checks;
    assert(recipes[0].steps.size() == 1 && recipes[0].steps[0] == "Cook it.");
    ++checks;
    assert(recipes[0].image_path.empty());
    ++checks;

    // Bare array of recipes.
    assert(parse_ok(std::string("[") + kSingle + "," + kSingle + "]", recipes));
    ++checks;
    assert(recipes.size() == 2);
    ++checks;

    // Wrapped collection object.
    assert(parse_ok(std::string("{\"recipes\": [") + kSingle + "]}", recipes));
    ++checks;
    assert(recipes.size() == 1 && recipes[0].title == "Mushroom Risotto");
    ++checks;

    // Minimal recipe uses defaults.
    assert(parse_ok("{\"title\": \"Toast\"}", recipes));
    ++checks;
    assert(recipes.size() == 1);
    ++checks;
    assert(recipes[0].title == "Toast");
    ++checks;
    assert(recipes[0].description.empty());
    ++checks;
    assert(recipes[0].notes.empty());
    ++checks;
    assert(recipes[0].servings == 0);
    ++checks;
    assert(recipes[0].image_path.empty());
    ++checks;
    assert(recipes[0].ingredients.empty());
    ++checks;
    assert(recipes[0].steps.empty());
    ++checks;

    // Explicit null image_path is the same as missing.
    assert(parse_ok("{\"title\": \"Toast\", \"image_path\": null}", recipes));
    ++checks;
    assert(recipes[0].image_path.empty());
    ++checks;

    // Ingredient fields default individually.
    assert(parse_ok("{\"title\": \"Toast\", \"ingredients\": [{\"name\": \"bread\"}]}",
                    recipes));
    ++checks;
    assert(recipes[0].ingredients.size() == 1);
    ++checks;
    assert(recipes[0].ingredients[0].amount.empty());
    ++checks;
    assert(recipes[0].ingredients[0].unit.empty());
    ++checks;
    assert(recipes[0].ingredients[0].name == "bread");
    ++checks;

    // Empty collection imports zero recipes, successfully.
    assert(parse_ok("{\"recipes\": []}", recipes));
    ++checks;
    assert(recipes.empty());
    ++checks;

    // String escapes, including \u and a surrogate pair (emoji).
    assert(parse_ok("{\"title\": \"A\\u00e9 B\\ud83c\\udf55\"}", recipes));
    ++checks;
    assert(recipes[0].title == "A\xc3\xa9 B\xf0\x9f\x8d\x95");
    ++checks;

    // Invalid JSON, wrong shapes, and missing titles are errors.
    assert(parse_fails("{ this is not json"));
    ++checks;
    assert(parse_fails(""));
    ++checks;
    assert(parse_fails("42"));
    ++checks;
    assert(parse_fails("{\"nope\": 1}"));
    ++checks;
    assert(parse_fails("{\"description\": \"No title here.\"}"));
    ++checks;
    assert(parse_fails("{\"title\": \"   \"}"));
    ++checks;
    assert(parse_fails("{\"title\": \"\"}"));
    ++checks;
    assert(parse_fails("{\"recipes\": {\"title\": \"Toast\"}}"));
    ++checks;
    assert(parse_fails("{\"title\": 42}"));
    ++checks;
    assert(parse_fails("{\"title\": \"Toast\", \"servings\": \"four\"}"));
    ++checks;
    assert(parse_fails("{\"title\": \"Toast\", \"servings\": 4.5}"));
    ++checks;
    assert(parse_fails("{\"title\": \"Toast\", \"steps\": [1]}"));
    ++checks;
    assert(parse_fails("{\"title\": \"Toast\"} trailing"));
    ++checks;

    // HTTPS is rejected with a clear message, before any connect.
    std::string fetched_body;
    assert(!fetch_url("https://example.com/recipes.json", fetched_body, error));
    ++checks;
    assert(error.find("HTTPS") != std::string::npos);
    ++checks;
    assert(!fetch_url("ftp://example.com/recipes.json", fetched_body, error));
    ++checks;
    assert(!fetch_url("http:///recipes.json", fetched_body, error));
    ++checks;

    // Fetch from a one-shot local server.
    {
        std::string body = std::string("{\"recipes\": [") + kSingle + "]}";
        OneShotServer server(response_200(body));
        assert(fetch_and_parse(server.url("/recipes.json"), recipes, error));
        ++checks;
        assert(recipes.size() == 1 && recipes[0].title == "Mushroom Risotto");
        ++checks;
    }

    // A chunked response decodes.
    {
        std::string body = std::string("{\"recipes\": [") + kSingle + "]}";
        // Split the body into two chunks to exercise chunk boundaries.
        // Chunk sizes are hex, as the transfer encoding requires.
        auto to_hex = [](size_t value) {
            char buffer[32];
            std::snprintf(buffer, sizeof(buffer), "%zx", value);
            return std::string(buffer);
        };
        size_t half = body.size() / 2;
        std::string chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
                  to_hex(half) + "\r\n" + body.substr(0, half) + "\r\n" +
                  to_hex(body.size() - half) + "\r\n" +
                  body.substr(half) + "\r\n0\r\n\r\n";
        OneShotServer server(chunked);
        assert(fetch_and_parse(server.url("/recipes.json"), recipes, error));
        ++checks;
        assert(recipes.size() == 1 && recipes[0].title == "Mushroom Risotto");
        ++checks;
    }

    // A non-200 response is an error mentioning the status.
    {
        OneShotServer server("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot found");
        assert(!fetch_url(server.url("/missing.json"), fetched_body, error));
        ++checks;
        assert(error.find("404") != std::string::npos);
        ++checks;
    }

    std::printf("test_json_import: all %d checks passed\n", checks);
    return 0;
}
