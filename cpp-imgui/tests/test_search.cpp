// Unit tests for recipe title search (cpp-imgui).
//
// Covers the app's search semantics exactly: case-insensitive
// substring match on the recipe TITLE only; an empty query
// matches everything. No SQLite, SDL, or Dear ImGui dependency:
// build with plain g++ (see README "Tests").
//
// Plain asserts only; no test framework. Each assert is one
// check; main prints the total on success and aborts on the
// first failure, with the failing line reported by assert.

#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

#include "search.h"

namespace {

const std::vector<std::string> kSeedTitles = {
    "Banana Bread",
    "Tomato Basil Pasta",
    "Chicken Stir Fry",
};

// How many seed titles match the query.
int match_count(const std::string& query) {
    int count = 0;
    for (const std::string& title : kSeedTitles) {
        if (recipe_title_matches_search(title, query)) {
            ++count;
        }
    }
    return count;
}

}  // namespace

int main() {
    int checks = 0;

    // Empty query matches everything.
    for (const std::string& title : kSeedTitles) {
        assert(recipe_title_matches_search(title, ""));
        ++checks;
    }
    assert(match_count("") == 3);
    ++checks;

    // Exact title matches only that recipe.
    assert(recipe_title_matches_search("Banana Bread", "Banana Bread"));
    ++checks;
    assert(!recipe_title_matches_search("Tomato Basil Pasta", "Banana Bread"));
    ++checks;
    assert(!recipe_title_matches_search("Chicken Stir Fry", "Banana Bread"));
    ++checks;
    assert(match_count("Tomato Basil Pasta") == 1);
    ++checks;
    assert(match_count("Chicken Stir Fry") == 1);
    ++checks;

    // Mixed-case query matches (case-insensitive).
    assert(recipe_title_matches_search("Banana Bread", "BANANA"));
    ++checks;
    assert(recipe_title_matches_search("Banana Bread", "bAnAnA"));
    ++checks;
    assert(match_count("BANANA") == 1);
    ++checks;
    assert(match_count("CHICKEN") == 1);
    ++checks;

    // Partial substring matches.
    assert(match_count("tom") == 1);
    ++checks;
    assert(recipe_title_matches_search("Tomato Basil Pasta", "tom"));
    ++checks;
    assert(recipe_title_matches_search("Banana Bread", "Bread"));
    ++checks;
    assert(match_count("Bread") == 1);
    ++checks;
    assert(match_count("pasta") == 1);
    ++checks;
    assert(match_count("stir") == 1);
    ++checks;

    // Title only: words from a description do not match.
    // ("ripe bananas" is in Banana Bread's description, not its
    // title; "weeknight" is in Tomato Basil Pasta's description.)
    assert(!recipe_title_matches_search("Banana Bread", "ripe bananas"));
    ++checks;
    assert(!recipe_title_matches_search("Tomato Basil Pasta", "weeknight"));
    ++checks;
    assert(match_count("ripe bananas") == 0);
    ++checks;

    // A query matching nothing.
    assert(match_count("zzz") == 0);
    ++checks;
    assert(match_count("pizza") == 0);
    ++checks;

    // A query longer than a title matches nothing.
    assert(!recipe_title_matches_search("Banana Bread", "Banana Breads"));
    ++checks;
    assert(match_count("Banana Bread Extra Long Query That Matches Nothing") == 0);
    ++checks;
    assert(match_count("Tomato Basil Pasta and more") == 0);
    ++checks;

    std::printf("test_search: all %d checks passed\n", checks);
    return 0;
}
