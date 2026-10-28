// Unit tests for recipe data via the stack's own DB layer
// (db.cpp/db.h + seed.cpp/seed.h). Plain checks only: no test
// framework and no GTK.
//
// The database lives ONLY in a throwaway directory created with
// mkdtemp under /tmp and removed at the end of the run; the real
// recipes.db in the working directory is never opened. Build and
// run (needs SQLite3 headers + lib, no GTK):
//   cmake -S . -B build && cmake --build build --target cpp-gtk4-test-db
//   ./build/cpp-gtk4-test-db
// Exit code is 0 only when every check passes; each failure is
// printed and the run continues so all failures are visible.

#include "db.h"
#include "seed.h"

#include <sqlite3.h>

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <unistd.h>
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

bool same_ingredient(const Ingredient& a, const Ingredient& b) {
    return a.amount == b.amount && a.unit == b.unit && a.name == b.name;
}

// Loaded recipe must equal the expected one in every field except
// id (seed recipes carry id 0; stored rows get real ids).
bool same_recipe_ignoring_id(const Recipe& got, const Recipe& want) {
    if (got.title != want.title || got.description != want.description ||
        got.servings != want.servings || got.image_path != want.image_path ||
        got.notes != want.notes ||
        got.ingredients.size() != want.ingredients.size() ||
        got.steps.size() != want.steps.size()) {
        return false;
    }
    for (size_t i = 0; i < want.ingredients.size(); ++i) {
        if (!same_ingredient(got.ingredients[i], want.ingredients[i])) {
            return false;
        }
    }
    return got.steps == want.steps;
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

// Row count in a child table for one recipe id, read directly so
// a delete test proves the children are gone, not just unloaded.
int child_count(sqlite3* db, const char* table, long long recipe_id) {
    std::string sql = std::string("SELECT COUNT(*) FROM ") + table +
                      " WHERE recipe_id = ?;";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        return -1;
    }
    sqlite3_bind_int64(stmt, 1, recipe_id);
    int count = -1;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

}  // namespace

int main() {
    // Throwaway database only: never "recipes.db" in the cwd.
    char dir_template[] = "/tmp/cpp-gtk4-test-db-XXXXXX";
    char* dir = mkdtemp(dir_template);
    if (dir == nullptr) {
        std::cerr << "FAIL: could not create temp directory\n";
        return 1;
    }
    std::string path = std::string(dir) + "/test.db";

    sqlite3* db = nullptr;
    std::string error;
    check(open_database(path, &db, error), "open temp database: " + error);
    if (db == nullptr) {
        std::cerr << "test_db: cannot continue without a database\n";
        return 1;
    }

    // --- Seed: 3 recipes, ingredients and steps preserved, in order.
    check(init_and_seed(db, error), "seed temp database: " + error);
    std::vector<Recipe> recipes;
    check(load_recipes(db, recipes, error), "load seeded recipes: " + error);
    check(recipes.size() == 3, "seed loads exactly 3 recipes");
    {
        std::vector<Recipe> expected = seed_recipes();
        check(recipes.size() == expected.size(),
              "seed count matches seed_recipes()");
        size_t total_ingredients = 0;
        size_t total_steps = 0;
        for (size_t i = 0; i < recipes.size() && i < expected.size(); ++i) {
            check(recipes[i].title == expected[i].title,
                  "seed title order: " + expected[i].title);
            check(same_recipe_ignoring_id(recipes[i], expected[i]),
                  "seed recipe preserved in order: " + expected[i].title);
            total_ingredients += recipes[i].ingredients.size();
            total_steps += recipes[i].steps.size();
        }
        check(total_ingredients == 19, "seed has 19 ingredients total");
        check(total_steps == 13, "seed has 13 steps total");
        if (recipes.size() == 3) {
            check(recipes[0].ingredients.size() == 7 &&
                      recipes[1].ingredients.size() == 6 &&
                      recipes[2].ingredients.size() == 6,
                  "seed ingredient counts are 7/6/6");
            check(recipes[0].steps.size() == 5 &&
                      recipes[1].steps.size() == 4 &&
                      recipes[2].steps.size() == 4,
                  "seed step counts are 5/4/4");
            check(recipes[0].servings == 8 && recipes[1].servings == 4 &&
                      recipes[2].servings == 4,
                  "seed servings are 8/4/4");
        }
    }

    // --- Seeding twice does not duplicate recipes.
    check(init_and_seed(db, error), "second seed call: " + error);
    check(load_recipes(db, recipes, error), "reload after second seed: " + error);
    check(recipes.size() == 3, "second seed still leaves exactly 3 recipes");
    check(recipes.size() == 3 &&
              recipes[0].title == "Banana Bread" &&
              recipes[1].title == "Tomato Basil Pasta" &&
              recipes[2].title == "Chicken Stir Fry",
          "second seed leaves the same 3 titles, no duplicates");

    // --- Insert round-trip.
    Recipe inserted;
    inserted.title = "Test Soup";
    inserted.description = "A soup made only for testing.";
    inserted.servings = 2;
    inserted.ingredients = {{"1", "cup", "water"}, {"2", "", "carrots, diced"}};
    inserted.steps = {"Boil the water.", "Add the carrots."};
    inserted.notes = "Test note.";
    check(insert_recipe(db, inserted, error), "insert recipe: " + error);
    check(inserted.id != 0, "insert sets a non-zero id");
    long long inserted_id = inserted.id;
    check(load_recipes(db, recipes, error), "reload after insert: " + error);
    check(recipes.size() == 4, "insert grows the list to 4 recipes");
    {
        const Recipe* got = find_by_title(recipes, "Test Soup");
        check(got != nullptr, "inserted recipe is loadable by title");
        if (got != nullptr) {
            check(same_recipe_ignoring_id(*got, inserted),
                  "inserted recipe fields, ingredients, steps preserved in order");
        }
    }

    // --- Update round-trip: replaces ingredients and steps.
    Recipe updated = inserted;
    updated.id = inserted_id;
    updated.title = "Test Soup Revised";
    updated.servings = 6;
    updated.ingredients = {{"3", "cups", "stock"}};
    updated.steps = {"Heat the stock.", "Serve.", "Clean up."};
    check(update_recipe(db, updated, error), "update recipe: " + error);
    check(load_recipes(db, recipes, error), "reload after update: " + error);
    check(recipes.size() == 4, "update keeps the list at 4 recipes");
    check(find_by_title(recipes, "Test Soup") == nullptr,
          "update removes the old title");
    {
        const Recipe* got = find_by_title(recipes, "Test Soup Revised");
        check(got != nullptr, "updated recipe is loadable by new title");
        if (got != nullptr) {
            check(got->id == inserted_id, "update keeps the same id");
            check(same_recipe_ignoring_id(*got, updated),
                  "update replaces ingredients/steps with the new ones, in order");
        }
    }

    // --- Delete round-trip: removes the recipe and its children.
    check(delete_recipe(db, inserted_id, error), "delete recipe: " + error);
    check(load_recipes(db, recipes, error), "reload after delete: " + error);
    check(recipes.size() == 3, "delete shrinks the list back to 3 recipes");
    check(find_by_title(recipes, "Test Soup Revised") == nullptr,
          "deleted recipe is gone");
    check(child_count(db, "ingredients", inserted_id) == 0,
          "delete removes the recipe's ingredients");
    check(child_count(db, "steps", inserted_id) == 0,
          "delete removes the recipe's steps");

    sqlite3_close(db);
    std::remove(path.c_str());
    rmdir(dir);

    if (failures == 0) {
        std::cout << "test_db: all " << checks << " checks passed\n";
        return 0;
    }
    std::cerr << "test_db: " << failures << " of " << checks
              << " checks FAILED\n";
    return 1;
}
