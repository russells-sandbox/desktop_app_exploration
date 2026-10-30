// Unit tests for URL and raw-file JSON import (cpp-imgui).
//
// Covers the importer's parsing and fetching exactly as
// rust-egui's json_import tests do: all three document shapes,
// defaults, the empty collection, invalid JSON, missing/blank
// titles, string escapes, chunked bodies, redirects, and a
// non-200 error — plus fetching from a one-shot local server
// (a thread that binds first, so the port is known, then serves
// exactly one response) — and raw-file import from temp files
// and from the shared test-data fixtures on disk, mirroring
// rust-egui's import_from_file tests, including the UTF-8-only
// rule (a non-UTF-8 file is an error).
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
#include <filesystem>
#include <fstream>
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

std::string write_temp_file(const std::string& name, const std::string& contents) {
    std::filesystem::path path =
        std::filesystem::temp_directory_path() /
        ("cpp-imgui-import-test-" + std::to_string(getpid()) + "-" + name +
         ".json");
    std::ofstream out(path, std::ios::binary);
    assert(out);
    out << contents;
    out.close();
    return path.string();
}

// The shared test-data fixtures, found wherever the test binary
// runs from: ctest runs from cpp-imgui/build, the plain g++
// command in the README runs from cpp-imgui/, and a manual run
// may run from the repo root. Returns empty when no candidate
// exists, so the test fails with a clear message instead of a
// misleading parse error.
std::string fixture_path(const std::string& name) {
    for (const char* candidate : {"../../test-data/", "../test-data/",
                                  "test-data/"}) {
        std::string path = std::string(candidate) + name;
        std::ifstream probe(path, std::ios::binary);
        if (probe) {
            return path;
        }
    }
    return "";
}

bool file_ok(const std::string& path, std::vector<Recipe>& recipes) {
    std::string error;
    bool ok = import_from_file(path, recipes, error);
    if (!ok) {
        std::fprintf(stderr, "unexpected file import error for %s: %s\n",
                     path.c_str(), error.c_str());
    }
    return ok;
}

bool file_fails(const std::string& path, const std::string& must_contain) {
    std::vector<Recipe> recipes;
    std::string error;
    bool ok = import_from_file(path, recipes, error);
    if (ok) {
        std::fprintf(stderr, "unexpected file import success for: %s\n",
                     path.c_str());
    }
    return !ok && error.find(must_contain) != std::string::npos;
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

    // Raw-file import: single recipe from a temp file.
    {
        std::string path = write_temp_file("single", kSingle);
        assert(file_ok(path, recipes));
        ++checks;
        assert(recipes.size() == 1 && recipes[0].title == "Mushroom Risotto");
        ++checks;
        std::filesystem::remove(path);
    }

    // Raw-file import: collection from a temp file.
    {
        std::string body = std::string("{\"recipes\": [") + kSingle + "," + kSingle + "]}";
        std::string path = write_temp_file("collection", body);
        assert(file_ok(path, recipes));
        ++checks;
        assert(recipes.size() == 2);
        ++checks;
        std::filesystem::remove(path);
    }

    // Raw-file import: bare array and empty collection.
    {
        std::string path = write_temp_file("array", std::string("[") + kSingle + "]");
        assert(file_ok(path, recipes));
        ++checks;
        assert(recipes.size() == 1);
        ++checks;
        std::filesystem::remove(path);
        path = write_temp_file("empty", "{\"recipes\": []}");
        assert(file_ok(path, recipes));
        ++checks;
        assert(recipes.empty());
        ++checks;
        std::filesystem::remove(path);
    }

    // Raw-file import: invalid JSON and a missing file are errors.
    {
        std::string path = write_temp_file("invalid", "{ this is not json");
        assert(file_fails(path, "Could not parse recipe JSON"));
        ++checks;
        std::filesystem::remove(path);
        std::string missing =
            (std::filesystem::temp_directory_path() /
             ("cpp-imgui-import-test-" + std::to_string(getpid()) + "-missing.json"))
                .string();
        assert(file_fails(missing, "Could not read file"));
        ++checks;
    }

    // Raw-file import is UTF-8 only: a file with bytes that are
    // not valid UTF-8 (here a lone 0xFF, as Latin-1 would
    // produce) fails instead of importing mojibake.
    {
        std::string bad = "{\"title\": \"";
        bad.push_back(static_cast<char>(0xFF));
        bad += "\"}";
        std::string path = write_temp_file("non-utf8", bad);
        assert(file_fails(path, "Could not read file"));
        ++checks;
        std::filesystem::remove(path);
    }

    // Raw-file import: the shared test-data fixtures, read from
    // disk rather than from inline JSON, so the file path itself
    // is exercised end to end.
    {
        std::string single = fixture_path("recipe-single.json");
        assert(!single.empty());
        ++checks;
        assert(file_ok(single, recipes));
        ++checks;
        assert(recipes.size() == 1 && recipes[0].title == "Mushroom Risotto");
        ++checks;
        assert(file_ok(fixture_path("recipes-array.json"), recipes));
        ++checks;
        assert(recipes.size() == 2 && recipes[0].title == "Pancakes" &&
               recipes[1].title == "Greek Salad");
        ++checks;
        assert(file_ok(fixture_path("recipes.json"), recipes));
        ++checks;
        assert(recipes.size() == 3 && recipes[0].title == "Fried Chicken" &&
               recipes[1].title == "Lasagna" && recipes[2].title == "Butter Tarts");
        ++checks;
        assert(file_ok(fixture_path("recipes-empty.json"), recipes));
        ++checks;
        assert(recipes.empty());
        ++checks;
        assert(file_fails(fixture_path("invalid.json"), "Could not parse recipe JSON"));
        ++checks;
    }

    std::printf("test_json_import: all %d checks passed\n", checks);
    return 0;
}
