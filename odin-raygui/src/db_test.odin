package main

import "core:fmt"
import "core:os"
import "core:testing"

// Unit tests for recipe data, through the stack's existing
// DB layer (src/db.odin) and seed data (src/recipes.odin).
// Every test opens a throwaway database file under the OS
// temp directory, never the app's real recipes.db, and
// removes it again when the test finishes. Encoding, UI,
// network, and end-to-end behaviour are out of scope here.

// Open a fresh temp database, seed it once, and return the
// open handle and its path. The caller owns both: close the
// handle first, then remove the file (defers run LIFO, so
// register the remove before the close).
open_seeded_test_db :: proc(t: ^testing.T, name: string) -> (^Sqlite_Db, string) {
	path := fmt.tprintf("/tmp/odin-raygui-test-%s.db", name)
	os.remove(path)
	db, err := open_database(path)
	testing.expectf(t, err == "", "open_database %q: %s", path, err)
	testing.expect(t, db != nil)
	seed_err := ensure_schema_and_seed(db, RECIPES[:])
	testing.expectf(t, seed_err == "", "ensure_schema_and_seed: %s", seed_err)
	return db, path
}

find_recipe :: proc(recipes: []Recipe, id: i64) -> ^Recipe {
	for &recipe in recipes {
		if recipe.id == id {
			return &recipe
		}
	}
	return nil
}

// Row count for one child table for one recipe, via the
// existing prepare/step helpers. Used to prove deletes
// remove children, not just the recipe row.
count_child_rows :: proc(t: ^testing.T, db: ^Sqlite_Db, table: string, recipe_id: i64) -> i64 {
	stmt, err := prepare(db, fmt.tprintf("SELECT COUNT(*) FROM %s WHERE recipe_id = ?1", table))
	testing.expectf(t, err == "", "prepare count %s: %s", table, err)
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, recipe_id)
	if rc := sqlite3_step(stmt); rc != SQLITE_ROW {
		testing.expect(t, false, "count query did not return a row")
		return -1
	}
	return sqlite3_column_int64(stmt, 0)
}

@(test)
test_seed_loads_recipes_with_ingredients_and_steps_in_order :: proc(t: ^testing.T) {
	db, path := open_seeded_test_db(t, "seed")
	defer os.remove(path)
	defer close_database(db)

	loaded, err := load_recipes(db)
	testing.expectf(t, err == "", "load_recipes: %s", err)
	testing.expect_value(t, len(loaded), 3)
	if len(loaded) != 3 {
		return
	}

	testing.expect_value(t, loaded[0].title, "Banana Bread")
	testing.expect_value(t, loaded[1].title, "Tomato Basil Pasta")
	testing.expect_value(t, loaded[2].title, "Chicken Stir Fry")
	testing.expect_value(t, loaded[0].servings, 8)
	testing.expect_value(t, loaded[1].servings, 4)
	testing.expect_value(t, loaded[2].servings, 4)

	// Ingredient and step counts: 19 ingredients, 13 steps.
	testing.expect_value(t, len(loaded[0].ingredients), 7)
	testing.expect_value(t, len(loaded[1].ingredients), 6)
	testing.expect_value(t, len(loaded[2].ingredients), 6)
	testing.expect_value(t, len(loaded[0].steps), 5)
	testing.expect_value(t, len(loaded[1].steps), 4)
	testing.expect_value(t, len(loaded[2].steps), 4)

	// Order and content preserved, not just counts.
	testing.expect_value(t, loaded[0].ingredients[0].name, "ripe bananas, mashed")
	testing.expect_value(t, loaded[0].ingredients[0].amount, "3")
	testing.expect_value(t, loaded[0].ingredients[6].name, "flour")
	testing.expect_value(t, loaded[1].ingredients[0].name, "pasta")
	testing.expect_value(t, loaded[2].ingredients[3].name, "soy sauce")
	testing.expect_value(t, loaded[0].steps[0], "Preheat the oven to 350°F and grease a 9x5 loaf pan.")
	testing.expect_value(t, loaded[0].steps[4], "Cool in the pan for 10 minutes, then turn out onto a rack.")
	testing.expect_value(t, loaded[2].steps[3], "Cook for 2 more minutes, stirring, until the sauce coats everything.")
	testing.expect_value(t, loaded[0].notes, "Optional: fold in walnuts or chocolate chips before baking.")
	testing.expect_value(t, loaded[0].image_path, "")
}

@(test)
test_seeding_twice_does_not_duplicate_recipes :: proc(t: ^testing.T) {
	db, path := open_seeded_test_db(t, "seed-twice")
	defer os.remove(path)
	defer close_database(db)

	testing.expect(t, ensure_schema_and_seed(db, RECIPES[:]) == "", "second seeding should succeed")
	loaded, err := load_recipes(db)
	testing.expectf(t, err == "", "load_recipes: %s", err)
	testing.expect_value(t, len(loaded), 3)
	if len(loaded) == 3 {
		testing.expect_value(t, loaded[0].title, "Banana Bread")
		testing.expect_value(t, loaded[1].title, "Tomato Basil Pasta")
		testing.expect_value(t, loaded[2].title, "Chicken Stir Fry")
		testing.expect_value(t, len(loaded[0].ingredients), 7)
		testing.expect_value(t, len(loaded[0].steps), 5)
	}
}

@(test)
test_insert_update_delete_round_trip :: proc(t: ^testing.T) {
	db, path := open_seeded_test_db(t, "round-trip")
	defer os.remove(path)
	defer close_database(db)

	// Insert.
	ing := [2]Ingredient{
		{amount = "2", unit = "cups", name = "stock"},
		{amount = "1", unit = "", name = "onion, diced"},
	}
	stp := [2]string{"Simmer the stock.", "Add the onion and cook until soft."}
	id, ierr := insert_recipe(db, Recipe{
		title       = "Test Soup",
		description = "A throwaway test recipe.",
		servings    = 2,
		image_path  = "images/test.png",
		ingredients = ing[:],
		steps       = stp[:],
		notes       = "Test notes.",
	})
	testing.expectf(t, ierr == "", "insert_recipe: %s", ierr)
	testing.expect(t, id > 0)

	loaded, err := load_recipes(db)
	testing.expectf(t, err == "", "load_recipes after insert: %s", err)
	testing.expect_value(t, len(loaded), 4)
	inserted := find_recipe(loaded, id)
	testing.expect(t, inserted != nil)
	if inserted != nil {
		testing.expect_value(t, inserted.title, "Test Soup")
		testing.expect_value(t, inserted.servings, 2)
		testing.expect_value(t, inserted.image_path, "images/test.png")
		testing.expect_value(t, inserted.notes, "Test notes.")
		testing.expect_value(t, len(inserted.ingredients), 2)
		testing.expect_value(t, len(inserted.steps), 2)
		if len(inserted.ingredients) == 2 {
			testing.expect_value(t, inserted.ingredients[0].name, "stock")
			testing.expect_value(t, inserted.ingredients[1].name, "onion, diced")
		}
		if len(inserted.steps) == 2 {
			testing.expect_value(t, inserted.steps[0], "Simmer the stock.")
			testing.expect_value(t, inserted.steps[1], "Add the onion and cook until soft.")
		}
	}

	// Update: replace title, servings, and children wholesale.
	new_ing := [1]Ingredient{{amount = "3", unit = "cups", name = "water"}}
	new_stp := [1]string{"Boil the water."}
	testing.expect(t, update_recipe(db, Recipe{
		id          = id,
		title       = "Test Soup Revised",
		description = "Revised description.",
		servings    = 6,
		image_path  = "",
		ingredients = new_ing[:],
		steps       = new_stp[:],
		notes       = "Revised notes.",
	}) == "", "update_recipe should succeed")

	loaded, err = load_recipes(db)
	testing.expectf(t, err == "", "load_recipes after update: %s", err)
	testing.expect_value(t, len(loaded), 4)
	updated := find_recipe(loaded, id)
	testing.expect(t, updated != nil)
	if updated != nil {
		testing.expect_value(t, updated.title, "Test Soup Revised")
		testing.expect_value(t, updated.servings, 6)
		testing.expect_value(t, updated.image_path, "")
		testing.expect_value(t, len(updated.ingredients), 1)
		testing.expect_value(t, len(updated.steps), 1)
		if len(updated.ingredients) == 1 {
			testing.expect_value(t, updated.ingredients[0].name, "water")
		}
		if len(updated.steps) == 1 {
			testing.expect_value(t, updated.steps[0], "Boil the water.")
		}
	}

	// Delete: recipe row and children both go away, and the
	// three seeded recipes are untouched.
	testing.expect(t, delete_recipe(db, id) == "", "delete_recipe should succeed")
	testing.expect_value(t, count_child_rows(t, db, "ingredients", id), 0)
	testing.expect_value(t, count_child_rows(t, db, "steps", id), 0)
	loaded, err = load_recipes(db)
	testing.expectf(t, err == "", "load_recipes after delete: %s", err)
	testing.expect_value(t, len(loaded), 3)
	testing.expect(t, find_recipe(loaded, id) == nil)
	if len(loaded) == 3 {
		testing.expect_value(t, loaded[0].title, "Banana Bread")
		testing.expect_value(t, loaded[2].title, "Chicken Stir Fry")
	}
}
