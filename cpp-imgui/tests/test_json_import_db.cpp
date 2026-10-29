// Unit test for URL JSON import through the DB layer (cpp-imgui).
//
// Fetches a wrapped collection from a one-shot local server,
// inserts each recipe with the stack's own insert_recipe, and
// reloads from the database to prove the imported recipes (with
// ingredients and steps in order) really landed. A failed import
// (invalid JSON here) inserts nothing.
//
// The tests use a throwaway database file under the system temp
// directory, never the real recipes.db, and delete it on success.
//
// Plain asserts only; no test framework. Requires SQLite3
// (see README "Tests").

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <sqlite3.h>

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include "db.h"
#include "json_import.h"

namespace {

std::string temp_db_path() {
    return (std::filesystem::temp_directory_path() /
            ("cpp-imgui-test-import-db-" + std::to_string(getpid()) + ".db"))
        .string();
}

// Serves exactly one response, then closes. Returns the port.
int serve_once(const std::string& response) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    assert(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t len = sizeof(address);
    assert(getsockname(listener, reinterpret_cast<sockaddr*>(&address), &len) == 0);
    int port = ntohs(address.sin_port);
    std::thread([listener, response]() {
        int stream = accept(listener, nullptr, nullptr);
        if (stream >= 0) {
            char request[4096];
            recv(stream, request, sizeof(request), 0);
            size_t sent = 0;
            while (sent < response.size()) {
                ssize_t n = send(stream, response.data() + sent, response.size() - sent, 0);
                if (n <= 0) {
                    break;
                }
                sent += static_cast<size_t>(n);
            }
            close(stream);
        }
        close(listener);
    }).detach();
    return port;
}

std::string response_200(const std::string& body) {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
           std::to_string(body.size()) + "\r\n\r\n" + body;
}

const Recipe* find_by_title(const std::vector<Recipe>& recipes,
                            const std::string& title) {
    for (const Recipe& recipe : recipes) {
        if (recipe.title == title) {
            return &recipe;
        }
    }
    return nullptr;
}

}  // namespace

int main() {
    int checks = 0;
    const std::string path = temp_db_path();
    std::filesystem::remove(path);

    std::string error;
    sqlite3* db = nullptr;
    assert(open_database(path, &db, error));
    assert(db != nullptr);
    assert(init_and_seed(db, error));

    // Fetch a 2-recipe collection and insert it, as main.cpp's
    // import poll does (insert each, keep the first new id).
    std::string body =
        "{\"recipes\": ["
        "{\"title\": \"Pancakes\", \"servings\": 4, "
        "\"ingredients\": [{\"amount\": \"2\", \"unit\": \"cups\", \"name\": \"flour\"}], "
        "\"steps\": [\"Mix.\", \"Fry.\"]}, "
        "{\"title\": \"Toast\"}]}";
    int port = serve_once(response_200(body));
    std::vector<Recipe> imported;
    assert(fetch_and_parse("http://127.0.0.1:" + std::to_string(port) + "/recipes.json",
                           imported, error));
    ++checks;
    assert(imported.size() == 2);
    ++checks;
    long long first_id = 0;
    for (const Recipe& recipe : imported) {
        long long new_id = 0;
        assert(insert_recipe(db, recipe, new_id, error));
        ++checks;
        if (first_id == 0) {
            first_id = new_id;
        }
    }
    assert(first_id != 0);
    ++checks;

    std::vector<Recipe> recipes;
    assert(load_recipes(db, recipes, error));
    ++checks;
    // 3 seeds + 2 imported.
    assert(recipes.size() == 5);
    ++checks;
    const Recipe* pancakes = find_by_title(recipes, "Pancakes");
    assert(pancakes != nullptr);
    ++checks;
    assert(pancakes->id == first_id);
    ++checks;
    assert(pancakes->servings == 4);
    ++checks;
    assert(pancakes->ingredients.size() == 1);
    ++checks;
    assert(pancakes->ingredients[0].name == "flour");
    ++checks;
    assert(pancakes->steps.size() == 2 && pancakes->steps[1] == "Fry.");
    ++checks;
    assert(find_by_title(recipes, "Toast") != nullptr);
    ++checks;

    // A failed import inserts nothing: invalid JSON never reaches
    // insert_recipe, so the count stays at 5.
    int bad_port = serve_once(response_200("{ this is not json"));
    std::vector<Recipe> bad;
    assert(!fetch_and_parse("http://127.0.0.1:" + std::to_string(bad_port) + "/bad.json",
                            bad, error));
    ++checks;
    assert(bad.empty());
    ++checks;
    assert(load_recipes(db, recipes, error));
    ++checks;
    assert(recipes.size() == 5);
    ++checks;

    sqlite3_close(db);
    std::filesystem::remove(path);
    std::printf("test_json_import_db: all %d checks passed\n", checks);
    return 0;
}
