// Unit tests for JSON import (json_import.h/.cpp): parsing
// (all shapes, defaults, empty collection, invalid JSON,
// missing title), fetching from a local one-shot server
// (including a non-200 error, a chunked body, and a redirect),
// and raw-file import from temp files and the shared test-data
// fixtures (single recipe, collection, bare array, empty
// collection, invalid JSON, missing file, non-UTF-8 file).
//
// Plain checks only: no test framework, no GTK, no SQLite, so
// this builds with plain g++ anywhere the app sources are
// present:
//   g++ -std=c++17 -Wall -Wextra -pthread test_json_import.cpp json_import.cpp -o /tmp/test_json_import
//   /tmp/test_json_import
// Exit code is 0 only when every check passes; each failure is
// printed and the run continues so all failures are visible.

#include "json_export.h"
#include "json_import.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <fstream>
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

// Write contents to a throwaway file under /tmp, named with
// this process's id so parallel runs do not collide. The caller
// removes it with std::remove.
std::string write_temp_file(const std::string& name,
                            const std::string& contents) {
    std::string path = "/tmp/cpp-gtk4-import-test-" +
                       std::to_string(getpid()) + "-" + name + ".json";
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) {
        return "";
    }
    std::fwrite(contents.data(), 1, contents.size(), file);
    std::fclose(file);
    return path;
}

bool file_ok(const std::string& path,
             std::vector<ImportedRecipe>& recipes) {
    std::string error;
    bool ok = import_from_file(path, recipes, error);
    if (!ok) {
        std::cerr << "  (file import error was: " << error << ")\n";
    }
    return ok;
}

// Find the repo's shared test-data directory: an argv[1]
// override wins, otherwise try the layouts for running from
// the cpp-gtk4 directory, from cpp-gtk4/build, or from the
// repo root. Empty when none of them holds recipe-single.json.
std::string find_test_data_dir(int argc, char** argv) {
    if (argc > 1) {
        std::string dir = argv[1];
        std::ifstream probe(dir + "/recipe-single.json");
        if (probe.good()) {
            return dir;
        }
    }
    for (const char* candidate :
         {"../test-data", "../../test-data", "test-data"}) {
        std::ifstream probe(std::string(candidate) +
                            "/recipe-single.json");
        if (probe.good()) {
            return candidate;
        }
    }
    return "";
}

}  // namespace

int main(int argc, char** argv) {
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

    // Raw-file import: the same parser, driven from disk.
    // Mirrors rust-egui's five import_from_file tests.
    {
        std::string path = write_temp_file("single", kSingle);
        check(!path.empty(), "temp file written for single recipe");
        check(file_ok(path, recipes), "file single recipe imports");
        check(recipes.size() == 1, "file single recipe count");
        check(!recipes.empty() &&
                  recipes[0].title == "Mushroom Risotto",
              "file single recipe title");
        std::remove(path.c_str());
    }
    {
        std::string body =
            std::string("{\"recipes\": [") + kSingle + ", " + kSingle +
            "]}";
        std::string path = write_temp_file("collection", body);
        check(file_ok(path, recipes), "file collection imports");
        check(recipes.size() == 2, "file collection count");
        std::remove(path.c_str());
    }
    {
        std::string path = write_temp_file(
            "array", std::string("[") + kSingle + "]");
        check(file_ok(path, recipes), "file bare array imports");
        check(recipes.size() == 1, "file bare array count");
        std::remove(path.c_str());
        path = write_temp_file("empty", "{\"recipes\": []}");
        check(file_ok(path, recipes), "file empty collection imports");
        check(recipes.empty(), "file empty collection count");
        std::remove(path.c_str());
    }
    {
        std::string path =
            write_temp_file("invalid", "{ this is not json");
        std::vector<ImportedRecipe> bad;
        std::string error;
        check(!import_from_file(path, bad, error),
              "file invalid JSON is an error");
        check(error.find("Could not parse recipe JSON") !=
                  std::string::npos,
              "file invalid JSON error mentions parsing");
        std::remove(path.c_str());
        std::string missing = "/tmp/cpp-gtk4-import-test-" +
                              std::to_string(getpid()) +
                              "-missing.json";
        check(!import_from_file(missing, bad, error),
              "missing file is an error");
        check(error.find("Could not read file") != std::string::npos,
              "missing file error mentions reading");
    }
    {
        // Non-UTF-8 bytes are a parse error, not a silent
        // reinterpretation: encoding detection is a separate
        // todo item, so the file route stays UTF-8 only.
        std::string path = write_temp_file(
            "nonutf8", std::string("{\"title\": \"A\xFF\"}"));
        std::vector<ImportedRecipe> bad;
        std::string error;
        check(!import_from_file(path, bad, error),
              "non-UTF-8 file is an error");
        check(error.find("Could not parse recipe JSON") !=
                  std::string::npos,
              "non-UTF-8 file error mentions parsing");
        std::remove(path.c_str());
    }
    {
        // The repo's shared test-data fixtures, read from disk
        // rather than from inline JSON, so the file path itself
        // is exercised end to end.
        std::string dir = find_test_data_dir(argc, argv);
        check(!dir.empty(), "shared test-data directory found");
        if (!dir.empty()) {
            check(file_ok(dir + "/recipe-single.json", recipes),
                  "fixture recipe-single.json imports");
            check(recipes.size() == 1 &&
                      recipes[0].title == "Mushroom Risotto",
                  "fixture recipe-single.json content");
            check(file_ok(dir + "/recipes-array.json", recipes),
                  "fixture recipes-array.json imports");
            check(recipes.size() == 2 &&
                      recipes[0].title == "Pancakes" &&
                      recipes[1].title == "Greek Salad",
                  "fixture recipes-array.json content");
            check(file_ok(dir + "/recipes.json", recipes),
                  "fixture recipes.json imports");
            check(recipes.size() == 3 &&
                      recipes[0].title == "Fried Chicken" &&
                      recipes[1].title == "Lasagna" &&
                      recipes[2].title == "Butter Tarts",
                  "fixture recipes.json content");
            check(file_ok(dir + "/recipes-empty.json", recipes),
                  "fixture recipes-empty.json imports");
            check(recipes.empty(),
                  "fixture recipes-empty.json is empty");
            std::vector<ImportedRecipe> bad;
            std::string error;
            check(!import_from_file(dir + "/invalid.json", bad, error),
                  "fixture invalid.json is an error");
            check(error.find("Could not parse recipe JSON") !=
                      std::string::npos,
                  "fixture invalid.json error mentions parsing");
        }
    }

    // JSON export (json_export.h/.cpp), mirroring rust-egui's
    // seven export tests: single and collection round-trip
    // through parse_recipes, empty collection, image_path
    // preserved, file-name sanitization, write-and-overwrite,
    // and write-to-a-missing-directory errors, plus an
    // escaping round-trip for the hand-written serializer.
    {
        ImportedRecipe sample;
        sample.title = "Mushroom Risotto";
        sample.description = "Creamy rice.";
        sample.servings = 4;
        sample.image_path = "";
        sample.notes = "Stir often.";
        sample.ingredients = {ImportedIngredient{"1", "lb", "mushrooms"}};
        sample.steps = {"Cook it."};

        // Single recipe: a bare object that re-imports.
        std::string text = export_single(sample);
        check(!text.empty() && text[0] == '{',
              "export single starts with an object");
        check(text.find("\"recipes\"") == std::string::npos,
              "export single is not wrapped in a recipes object");
        check(parse_ok(text, recipes), "export single re-imports");
        check(recipes.size() == 1, "export single re-import count");
        if (!recipes.empty()) {
            check(recipes[0].title == "Mushroom Risotto",
                  "export single re-import title");
            check(recipes[0].description == "Creamy rice.",
                  "export single re-import description");
            check(recipes[0].servings == 4,
                  "export single re-import servings");
            check(recipes[0].image_path.empty(),
                  "export single re-import null image_path");
            check(recipes[0].notes == "Stir often.",
                  "export single re-import notes");
            check(recipes[0].ingredients.size() == 1 &&
                      recipes[0].ingredients[0].name == "mushrooms",
                  "export single re-import ingredient");
            check(recipes[0].steps ==
                      std::vector<std::string>{"Cook it."},
                  "export single re-import steps");
        }
        // Field order, per the import format.
        size_t title_at = text.find("\"title\"");
        size_t desc_at = text.find("\"description\"");
        size_t servings_at = text.find("\"servings\"");
        size_t image_at = text.find("\"image_path\"");
        size_t notes_at = text.find("\"notes\"");
        size_t ingredients_at = text.find("\"ingredients\"");
        size_t steps_at = text.find("\"steps\"");
        check(title_at < desc_at && desc_at < servings_at &&
                  servings_at < image_at && image_at < notes_at &&
                  notes_at < ingredients_at && ingredients_at < steps_at,
              "export single field order");

        // Collection: a {"recipes": [...]} object that re-imports.
        std::string collection =
            export_collection({sample, sample});
        check(collection.find("\"recipes\"") != std::string::npos,
              "export collection is a recipes object");
        check(parse_ok(collection, recipes),
              "export collection re-imports");
        check(recipes.size() == 2, "export collection re-import count");
        check(recipes.size() == 2 &&
                  recipes[0].title == "Mushroom Risotto" &&
                  recipes[1].title == "Mushroom Risotto",
              "export collection re-import titles");

        // Empty collection: success with zero recipes.
        check(parse_ok(export_collection({}), recipes),
              "export empty collection re-imports");
        check(recipes.empty(), "export empty collection count");
        check(export_collection({}).find("\"recipes\": []") !=
                  std::string::npos,
              "export empty collection is an empty recipes array");

        // image_path preserved when present.
        ImportedRecipe with_image = sample;
        with_image.image_path = "images/risotto.png";
        std::string image_text = export_single(with_image);
        check(image_text.find("images/risotto.png") !=
                  std::string::npos,
              "export keeps image_path text");
        check(parse_ok(image_text, recipes),
              "export with image_path re-imports");
        check(!recipes.empty() &&
                  recipes[0].image_path == "images/risotto.png",
              "export with image_path re-import value");

        // Escaping round-trip: quotes, backslashes, and control
        // characters must survive the serializer and parser.
        ImportedRecipe tricky;
        tricky.title = "Fish \"Chips\" \\ \n\t\x01 end";
        tricky.description = "Line one\nLine two";
        std::string tricky_text = export_single(tricky);
        check(parse_ok(tricky_text, recipes),
              "export escaped text re-imports");
        check(!recipes.empty() && recipes[0].title == tricky.title,
              "export escaped title round-trips");
        check(!recipes.empty() &&
                  recipes[0].description == tricky.description,
              "export escaped description round-trips");

        // File-name sanitization.
        check(default_file_name("Banana Bread") == "Banana Bread.json",
              "default file name keeps a plain title");
        check(default_file_name("Fish & Chips / Fries") ==
                  "Fish _ Chips _ Fries.json",
              "default file name sanitizes punctuation");
        check(default_file_name("   ") == "recipe.json",
              "default file name falls back for a blank title");
        check(default_file_name("") == "recipe.json",
              "default file name falls back for an empty title");
        check(default_file_name("Cr\xC3\xA8me") == "Cr\xC3\xA8me.json",
              "default file name keeps a non-ASCII letter");

        // Write and overwrite.
        std::string out_path = "/tmp/cpp-gtk4-export-test-" +
                               std::to_string(getpid()) + "-out.json";
        std::remove(out_path.c_str());
        check(write_export(out_path, "{\"title\": \"Toast\"}", error),
              "write_export writes");
        {
            std::ifstream in(out_path);
            std::ostringstream contents;
            contents << in.rdbuf();
            check(contents.str() == "{\"title\": \"Toast\"}",
                  "write_export content");
        }
        check(write_export(out_path, "replaced", error),
              "write_export overwrites");
        {
            std::ifstream in(out_path);
            std::ostringstream contents;
            contents << in.rdbuf();
            check(contents.str() == "replaced",
                  "write_export overwritten content");
        }
        std::remove(out_path.c_str());

        // Writing into a missing directory is an error.
        std::string missing_dir = "/tmp/cpp-gtk4-export-test-" +
                                  std::to_string(getpid()) +
                                  "-no-such-dir/out.json";
        check(!write_export(missing_dir, "x", error),
              "write_export to a missing directory is an error");
        check(error.find("Could not write file") != std::string::npos,
              "write_export missing-directory error mentions writing");
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
