// Unit tests for the recipe-list search predicate (search.h).
//
// Plain checks only: no test framework, no GTK, no SQLite, so
// this builds with plain g++ anywhere the app sources are present:
//   g++ -std=c++17 -Wall -Wextra test_search.cpp -o /tmp/test_search
//   /tmp/test_search
// Exit code is 0 only when every check passes; each failure is
// printed and the run continues so all failures are visible.

#include "search.h"

#include <iostream>
#include <string>
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

const std::vector<std::string> kSeedTitles = {
    "Banana Bread",
    "Tomato Basil Pasta",
    "Chicken Stir Fry",
};

std::vector<std::string> matching(const std::string& query) {
    std::vector<std::string> out;
    for (const std::string& title : kSeedTitles) {
        if (title_matches_search(title, query)) {
            out.push_back(title);
        }
    }
    return out;
}

void check_matches(const std::string& query,
                   const std::vector<std::string>& expected,
                   const std::string& what) {
    check(matching(query) == expected,
          what + " (query: \"" + query + "\")");
}

}  // namespace

int main() {
    // Empty query matches everything.
    check_matches("", kSeedTitles, "empty query matches all titles");
    for (const std::string& title : kSeedTitles) {
        check(title_matches_search(title, ""),
              "empty query matches \"" + title + "\"");
    }

    // Exact title.
    check_matches("Banana Bread", {"Banana Bread"},
                  "exact title matches only that recipe");
    check_matches("Tomato Basil Pasta", {"Tomato Basil Pasta"},
                  "exact title matches only that recipe");
    check_matches("Chicken Stir Fry", {"Chicken Stir Fry"},
                  "exact title matches only that recipe");

    // Mixed-case query: matching is case-insensitive.
    check_matches("BANANA", {"Banana Bread"},
                  "mixed-case query matches");
    check_matches("bAnAnA bReAd", {"Banana Bread"},
                  "mixed-case exact title matches");
    check_matches("CHICKEN", {"Chicken Stir Fry"},
                  "upper-case query matches");

    // Partial substring.
    check_matches("tom", {"Tomato Basil Pasta"},
                  "partial substring matches");
    check_matches("bread", {"Banana Bread"},
                  "partial substring matches");
    check_matches("ASIL", {"Tomato Basil Pasta"},
                  "mixed-case partial substring matches");
    check_matches("Stir", {"Chicken Stir Fry"},
                  "partial substring matches");

    // A query matching nothing.
    check_matches("zzz", {}, "query matching nothing matches none");
    check_matches("muffin", {}, "query matching nothing matches none");

    // A query longer than a title matches nothing.
    check_matches("Banana Bread Extra Long Query That Matches Nothing", {},
                  "query longer than a title matches nothing");
    check_matches("Banana Breads", {},
                  "query longer than the title matches nothing");
    check_matches("Chicken Stir Fry!", {},
                  "query longer than the title matches nothing");

    // Description/ingredient words must NOT match: title only.
    // ("ripe" is in Banana Bread's description/ingredients and
    // "soy" is in Chicken Stir Fry's, but neither is in a title.)
    check(!title_matches_search("Banana Bread", "ripe"),
          "ingredient word does not match title");
    check(!title_matches_search("Chicken Stir Fry", "soy"),
          "ingredient word does not match title");

    if (failures == 0) {
        std::cout << "test_search: all " << checks << " checks passed\n";
        return 0;
    }
    std::cerr << "test_search: " << failures << " of " << checks
              << " checks FAILED\n";
    return 1;
}
