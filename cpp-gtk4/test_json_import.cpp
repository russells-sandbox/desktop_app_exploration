// Unit tests for network JSON import (json_import.h/.cpp):
// parsing (all shapes, defaults, empty collection, invalid JSON,
// missing title) and fetching from a local one-shot server
// (including a non-200 error, a chunked body, and a redirect).
//
// Plain checks only: no test framework, no GTK, no SQLite, so
// this builds with plain g++ anywhere the app sources are
// present:
//   g++ -std=c++17 -Wall -Wextra -pthread test_json_import.cpp json_import.cpp -o /tmp/test_json_import
//   /tmp/test_json_import
// Exit code is 0 only when every check passes; each failure is
// printed and the run continues so all failures are visible.

#include "json_import.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const std::string& what) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << what << "\n";
    }
}

const char* kSingle = R"({
    "title": "Mushroom Risotto",
    "description": "Creamy rice.",
    "servings": 4,
    "ingredients": [{"amount": "1", "unit": "lb", "name": "mushrooms"}],
    "steps": ["Cook it."]
})";

bool parse_ok(const std::string& text,
              std::vector<ImportedRecipe>& recipes) {
    std::string error;
    bool ok = parse_recipes(text, recipes, error);
    if (!ok) {
        std::cerr << "  (parse error was: " << error << ")\n";
    }
    return ok;
}

bool parse_fails(const std::string& text) {
    std::vector<ImportedRecipe> recipes;
    std::string error;
    return !parse_recipes(text, recipes, error);
}

// A one-shot local HTTP server: binds first (so the port is
// known), then serves exactly one response in a thread.
struct OneShotServer {
    int port = 0;
    std::thread thread;

    explicit OneShotServer(const std::string& response) {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = 0;
        bind(listener, reinterpret_cast<sockaddr*>(&address),
             sizeof(address));
        listen(listener, 1);
        sockaddr_in bound{};
        socklen_t len = sizeof(bound);
        getsockname(listener, reinterpret_cast<sockaddr*>(&bound), &len);
        port = ntohs(bound.sin_port);
        thread = std::thread([listener, response]() {
            int stream = accept(listener, nullptr, nullptr);
            if (stream >= 0) {
                char request[4096];
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

    ~OneShotServer() {
        if (thread.joinable()) {
            thread.join();
        }
    }

    std::string url(const std::string& path) const {
        return "http://127.0.0.1:" + std::to_string(port) + path;
    }
};

std::string http_response(const std::string& body,
                          const std::string& status = "200 OK") {
    return "HTTP/1.1 " + status +
           "\r\nContent-Type: application/json\r\nContent-Length: " +
           std::to_string(body.size()) + "\r\n\r\n" + body;
}

}  // namespace

int main() {
    std::vector<ImportedRecipe> recipes;
    std::string error;

    // Single recipe object.
    check(parse_ok(kSingle, recipes), "single object parses");
    check(recipes.size() == 1, "single object gives one recipe");
    check(recipes[0].title == "Mushroom Risotto",
          "single object title");
    check(recipes[0].description == "Creamy rice.",
          "single object description");
    check(recipes[0].servings == 4, "single object servings");
    check(recipes[0].ingredients.size() == 1,
          "single object ingredient count");
    check(recipes[0].ingredients[0].name == "mushrooms",
          "single object ingredient name");
    check(recipes[0].ingredients[0].amount == "1",
          "single object ingredient amount");
    check(recipes[0].ingredients[0].unit == "lb",
          "single object ingredient unit");
    check(recipes[0].steps == std::vector<std::string>{"Cook it."},
          "single object steps");

    // Bare array.
    check(parse_ok(std::string("[") + kSingle + ", " + kSingle + "]",
                   recipes),
          "bare array parses");
    check(recipes.size() == 2, "bare array gives two recipes");

    // Wrapped collection.
    check(parse_ok(std::string("{\"recipes\": [") + kSingle + "]}",
                   recipes),
          "wrapped collection parses");
    check(recipes.size() == 1, "wrapped collection gives one recipe");

    // Minimal recipe: only a title, everything else defaults.
    check(parse_ok("{\"title\": \"Toast\"}", recipes),
          "minimal recipe parses");
    check(recipes.size() == 1, "minimal recipe gives one recipe");
    check(recipes[0].title == "Toast", "minimal recipe title");
    check(recipes[0].description.empty(),
          "minimal recipe description defaults to empty");
    check(recipes[0].servings == 0,
          "minimal recipe servings defaults to 0");
    check(recipes[0].image_path.empty(),
          "minimal recipe image_path defaults to null");
    check(recipes[0].ingredients.empty(),
          "minimal recipe ingredients default to empty");
    check(recipes[0].steps.empty(),
          "minimal recipe steps default to empty");
    check(recipes[0].notes.empty(),
          "minimal recipe notes default to empty");

    // image_path: null and a real path.
    check(parse_ok("{\"title\": \"A\", \"image_path\": null}", recipes),
          "null image_path parses");
    check(recipes[0].image_path.empty(), "null image_path is empty");
    check(parse_ok("{\"title\": \"A\", \"image_path\": \"images/a.jpg\"}",
                   recipes),
          "string image_path parses");
    check(recipes[0].image_path == "images/a.jpg",
          "string image_path kept");

    // Ingredient field defaults.
    check(parse_ok(
              "{\"title\": \"A\", \"ingredients\": [{\"name\": \"salt\"}]}",
              recipes),
          "ingredient with only a name parses");
    check(recipes[0].ingredients[0].amount.empty(),
          "ingredient amount defaults to empty");
    check(recipes[0].ingredients[0].unit.empty(),
          "ingredient unit defaults to empty");

    // String escapes, including a \u surrogate pair (emoji).
    check(parse_ok(
              "{\"title\": \"Fish \\u0026 Chips \\uD83D\\uDC1F\"}",
              recipes),
          "escaped string parses");
    check(recipes[0].title == "Fish & Chips \xF0\x9F\x90\x9F",
          "escaped string decodes \\u and surrogate pairs");

    // Empty collection: success with zero recipes, not an error.
    check(parse_ok("{\"recipes\": []}", recipes),
          "empty collection parses");
    check(recipes.empty(), "empty collection gives zero recipes");

    // Invalid JSON and wrong shapes are errors, not partial imports.
    check(parse_fails("{ this is not json"),
          "invalid JSON is an error");
    check(parse_fails("{\"nope\": 1}"),
          "object without recipes or title is an error");
    check(parse_fails("{\"description\": \"No title here.\"}"),
          "recipe without a title is an error");
    check(parse_fails("{\"title\": \"   \"}"),
          "recipe with a blank title is an error");
    check(parse_fails("{\"title\": 42}"),
          "recipe with a non-string title is an error");
    check(parse_fails("{\"recipes\": {\"title\": \"Toast\"}}"),
          "recipes field must be an array");
    check(parse_fails("[{\"title\": \"Toast\"}, 42]"),
          "array element must be a recipe object");
    check(parse_fails("{\"title\": \"A\", \"servings\": 4.5}"),
          "float servings is an error");
    check(parse_fails("{\"title\": \"A\", \"servings\": \"four\"}"),
          "string servings is an error");
    check(parse_fails("{\"title\": \"A\", \"steps\": [\"ok\", 3]}"),
          "non-string step is an error");
    check(parse_fails("{\"title\": \"A\",}"),
          "trailing comma is an error");
    check(parse_fails("{\"title\": \"A\"} extra"),
          "trailing characters are an error");
    check(parse_fails(""),
          "empty document is an error");

    // URL handling: https rejected, other schemes rejected.
    {
        std::string body;
        check(!fetch_url("https://example.com/recipes.json", body,
                         error),
              "https URL is rejected");
        check(error.find("HTTPS") != std::string::npos,
              "https rejection says HTTPS");
        check(!fetch_url("ftp://example.com/recipes.json", body,
                         error),
              "non-http URL is rejected");
        check(!fetch_url("http:///recipes.json", body, error),
              "URL without a host is rejected");
        check(!fetch_url("http://localhost:99999/recipes.json", body,
                         error),
              "URL with an invalid port is rejected");
    }

    // Fetch from a local one-shot server.
    {
        std::string body = std::string("{\"recipes\": [") + kSingle +
                           "]}";
        OneShotServer server(http_response(body));
        std::vector<ImportedRecipe> fetched;
        check(fetch_and_parse(server.url("/recipes.json"), fetched,
                              error),
              "fetch from a local server succeeds");
        check(fetched.size() == 1, "fetched recipe count");
        check(!fetched.empty() &&
                  fetched[0].title == "Mushroom Risotto",
              "fetched recipe title");
    }

    // Non-200 is an error, and the status is in the message.
    {
        OneShotServer server(
            http_response("Not found", "404 Not Found"));
        std::string body;
        check(!fetch_url(server.url("/missing.json"), body, error),
              "404 fetch is an error");
        check(error.find("404") != std::string::npos,
              "404 error mentions the status");
    }

    // Chunked body decodes.
    {
        std::string body = std::string("{\"recipes\": [") + kSingle +
                           "]}";
        // Chunk sizes are hexadecimal, not decimal.
        std::ostringstream hex_size;
        hex_size << std::hex << body.size();
        std::string chunked =
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            hex_size.str() + "\r\n" + body + "\r\n0\r\n\r\n";
        OneShotServer server(chunked);
        std::vector<ImportedRecipe> fetched;
        check(fetch_and_parse(server.url("/recipes.json"), fetched,
                              error),
              "chunked fetch succeeds");
        check(fetched.size() == 1, "chunked fetch recipe count");
    }

    // Redirect is followed (absolute path on the same server is
    // served by a second one-shot server on the same port only
    // if the port is reused, so instead test a redirect to a
    // full URL: spin up the target first, then the redirector).
    {
        std::string body = std::string("{\"recipes\": [") + kSingle +
                           "]}";
        OneShotServer target(http_response(body));
        std::string redirect = "HTTP/1.1 302 Found\r\nLocation: " +
                               target.url("/recipes.json") +
                               "\r\nContent-Length: 0\r\n\r\n";
        OneShotServer redirector(redirect);
        std::vector<ImportedRecipe> fetched;
        check(fetch_and_parse(redirector.url("/old.json"), fetched,
                              error),
              "redirect is followed");
        check(fetched.size() == 1, "redirect fetch recipe count");
    }

    if (failures == 0) {
        std::cout << "test_json_import: all " << checks
                  << " checks passed\n";
        return 0;
    }
    std::cerr << "test_json_import: " << failures << " of " << checks
              << " checks FAILED\n";
    return 1;
}
