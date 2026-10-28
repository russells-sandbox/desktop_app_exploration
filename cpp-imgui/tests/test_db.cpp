// Unit tests for recipe data (cpp-imgui), through the stack's
// existing DB layer (db.h / db.cpp).
//
// Covered: seed load (3 recipes, ingredients and steps
// preserved and in order), insert / update / delete round-trip
// (update replaces ingredients/steps, delete removes children
// too), and seeding twice does not duplicate recipes.
//
// The tests use a throwaway database file under the system temp
// directory, never the real recipes.db, and delete it on
// success. Encoding, UI, network, and end-to-end tests are
// explicitly out of scope here.
//
// Plain asserts only; no test framework. Requires SQLite3
// (see README "Tests"); it cannot build in a VM without
// sqlite3 headers, which is why this file is written but
// unverified there.

#include <sqlite3.h>

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include <unistd.h>

#include "db.h"

namespace {

std::string temp_db_path() {
    return (std::filesystem::temp_directory_path() /
            ("cpp-imgui-test-db-" + std::to_string(getpid()) + ".db"))
        .string();
}

// Direct row count for a child table, to prove delete really
// removed children (load_recipes alone would only show that
// the parent recipe is gone).
int child_count(sqlite3* db, const char* table, long long recipe_id) {
    std::string sql = std::string("SELECT COUNT(*) FROM ") + table +
                      " WHERE recipe_id = ?;";
    sqlite3_stmt* stmt = nullptr;
    assert(sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) == SQLITE_OK);
    sqlite3_bind_int64(stmt, 1, recipe_id);
    int count = -1;
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    count = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return count;
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
    const std::string path = temp_db_path();
    std::filesystem::remove(path);

    std::string error;
    sqlite3* db = nullptr;
    assert(open_database(path, &db, error));
    assert(db != nullptr);

    // Seed loads 3 recipes, ingredients and steps in order.
    assert(init_and_seed(db, error));
    std::vector<Recipe> recipes;
    assert(load_recipes(db, recipes, error));
    assert(recipes.size() == 3);
    assert(recipes[0].title == "Banana Bread");
    assert(recipes[1].title == "Tomato Basil Pasta");
    assert(recipes[2].title == "Chicken Stir Fry");
    assert(recipes[0].servings == 8);
    assert(recipes[1].servings == 4);
    assert(recipes[2].servings == 4);
    // Banana Bread: 7 ingredients, 5 steps, order preserved.
    assert(recipes[0].ingredients.size() == 7);
    assert(recipes[0].ingredients[0].amount == "3");
    assert(recipes[0].ingredients[0].unit == "");
    assert(recipes[0].ingredients[0].name == "ripe bananas, mashed");
    assert(recipes[0].ingredients[6].name == "flour");
    assert(recipes[0].steps.size() == 5);
    assert(recipes[0].steps[0] ==
           "Preheat the oven to 350°F and grease a 9x5 loaf pan.");
    assert(recipes[0].steps[4] ==
           "Cool in the pan for 10 minutes, then turn out onto a rack.");
    // Tomato Basil Pasta: 6 ingredients, 4 steps, order preserved.
    assert(recipes[1].ingredients.size() == 6);
    assert(recipes[1].ingredients[0].name == "pasta");
    assert(recipes[1].ingredients[5].name == "parmesan, grated");
    assert(recipes[1].steps.size() == 4);
    assert(recipes[1].steps[0] ==
           "Cook the pasta in salted water until al dente, reserving a cup of pasta water.");
    // Chicken Stir Fry: 6 ingredients, 4 steps, order preserved.
    assert(recipes[2].ingredients.size() == 6);
    assert(recipes[2].ingredients[0].name == "chicken breast, sliced");
    assert(recipes[2].steps.size() == 4);
    assert(recipes[2].steps[3] ==
           "Cook for 2 more minutes, stirring, until the sauce coats everything.");

    // Seeding twice does not duplicate recipes.
    assert(init_and_seed(db, error));
    assert(load_recipes(db, recipes, error));
    assert(recipes.size() == 3);

    // Insert round-trip.
    Recipe inserted;
    inserted.title = "Test Soup";
    inserted.description = "A throwaway test recipe.";
    inserted.servings = 2;
    inserted.ingredients = {{"2", "cups", "stock"}, {"1", "", "carrot, diced"}};
    inserted.steps = {"Heat the stock.", "Add the carrot and simmer."};
    inserted.notes = "Test only.";
    long long new_id = 0;
    assert(insert_recipe(db, inserted, new_id, error));
    assert(new_id != 0);
    assert(load_recipes(db, recipes, error));
    assert(recipes.size() == 4);
    const Recipe* found = find_by_title(recipes, "Test Soup");
    assert(found != nullptr);
    assert(found->id == new_id);
    assert(found->description == "A throwaway test recipe.");
    assert(found->servings == 2);
    assert(found->notes == "Test only.");
    assert(found->ingredients.size() == 2);
    assert(found->ingredients[0].name == "stock");
    assert(found->ingredients[1].name == "carrot, diced");
    assert(found->steps.size() == 2);
    assert(found->steps[0] == "Heat the stock.");
    assert(found->steps[1] == "Add the carrot and simmer.");
    assert(child_count(db, "ingredients", new_id) == 2);
    assert(child_count(db, "steps", new_id) == 2);

    // Update round-trip: replaces title, servings, and the
    // whole ingredient/step lists (old children must be gone).
    Recipe updated = *found;
    updated.title = "Test Soup Updated";
    updated.servings = 3;
    updated.ingredients = {{"1", "tsp", "salt"}};
    updated.steps = {"Season and serve."};
    assert(update_recipe(db, updated, error));
    assert(load_recipes(db, recipes, error));
    assert(recipes.size() == 4);
    assert(find_by_title(recipes, "Test Soup") == nullptr);
    found = find_by_title(recipes, "Test Soup Updated");
    assert(found != nullptr);
    assert(found->id == new_id);
    assert(found->servings == 3);
    assert(found->ingredients.size() == 1);
    assert(found->ingredients[0].name == "salt");
    assert(found->steps.size() == 1);
    assert(found->steps[0] == "Season and serve.");
    assert(child_count(db, "ingredients", new_id) == 1);
    assert(child_count(db, "steps", new_id) == 1);

    // Delete round-trip: recipe and its children are gone.
    assert(delete_recipe(db, new_id, error));
    assert(load_recipes(db, recipes, error));
    assert(recipes.size() == 3);
    assert(find_by_title(recipes, "Test Soup Updated") == nullptr);
    assert(child_count(db, "ingredients", new_id) == 0);
    assert(child_count(db, "steps", new_id) == 0);

    sqlite3_close(db);
    std::filesystem::remove(path);
    assert(!std::filesystem::exists(path));

    std::printf("test_db: all checks passed\n");
    return 0;
}
