package main

import "core:fmt"
import "core:os"
import "core:testing"

// Recipe-data tests, using the stack's existing DB layer
// (src/db.odin) against throwaway databases in /tmp — never
// the app's real recipes.db. Each test removes its file when
// it finishes, so no test artefact is left behind.

// Open a fresh throwaway database at path. The caller defers
// close_database followed by os.remove (defer runs LIFO, so
// register the remove first).
open_temp_db :: proc(t: ^testing.T, path: string) -> ^Sqlite_Db {
	os.remove(path)
	db, err := open_database(path)
	testing.expect(t, err == "", fmt.tprintf("open_database: %s", err))
	testing.expect(t, db != nil)
	return db
}

// Free a slice returned by load_recipes, including each
// recipe's ingredient and step arrays.
free_loaded_recipes :: proc(recipes: []Recipe) {
	for recipe in recipes {
		delete(recipe.ingredients)
		delete(recipe.steps)
	}
	delete(recipes)
}

find_recipe :: proc(recipes: []Recipe, id: i64) -> (Recipe, bool) {
	for recipe in recipes {
		if recipe.id == id {
			return recipe, true
		}
	}
	return {}, false
}

// Direct row count for a child table, used to prove delete
// really removes children (load_recipes alone would only show
// the parent row is gone). `table` is always one of the two
// fixed table names below, never user input.
count_child_rows :: proc(db: ^Sqlite_Db, table: string, recipe_id: i64) -> i64 {
	stmt, err := prepare(db, fmt.tprintf("SELECT COUNT(*) FROM %s WHERE recipe_id = ?1", table))
	if err != "" {
		return -1
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, recipe_id)
	if rc := sqlite3_step(stmt); rc == SQLITE_ROW {
		return sqlite3_column_int64(stmt, 0)
	}
	return -1
}

@(test)
test_db_seed_loads_three_recipes_with_children_in_order :: proc(t: ^testing.T) {
	path := "/tmp/odin-microui-test-seed.db"
	db := open_temp_db(t, path)
	defer os.remove(path)
	defer close_database(db)
	if db == nil {
		return
	}

	err := ensure_schema_and_seed(db, RECIPES[:])
	testing.expect(t, err == "", err)
	loaded, load_err := load_recipes(db)
	testing.expect(t, load_err == "", load_err)
	if load_err != "" {
		return
	}
	defer free_loaded_recipes(loaded)

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

	// Ingredient/step counts: 7/5, 6/4, 6/4 — 19 and 13 total.
	testing.expect_value(t, len(loaded[0].ingredients), 7)
	testing.expect_value(t, len(loaded[0].steps), 5)
	testing.expect_value(t, len(loaded[1].ingredients), 6)
	testing.expect_value(t, len(loaded[1].steps), 4)
	testing.expect_value(t, len(loaded[2].ingredients), 6)
	testing.expect_value(t, len(loaded[2].steps), 4)

	// Order and content preserved, first and last of each list.
	testing.expect_value(t, loaded[0].ingredients[0].name, "ripe bananas, mashed")
	testing.expect_value(t, loaded[0].ingredients[0].amount, "3")
	testing.expect_value(t, loaded[0].ingredients[0].unit, "")
	testing.expect_value(t, loaded[0].ingredients[6].name, "flour")
	testing.expect_value(t, loaded[0].ingredients[6].amount, "1 1/2")
	testing.expect_value(t, loaded[0].ingredients[6].unit, "cups")
	testing.expect_value(t, loaded[0].steps[0], "Preheat the oven to 350°F and grease a 9x5 loaf pan.")
	testing.expect_value(t, loaded[0].steps[4], "Cool in the pan for 10 minutes, then turn out onto a rack.")
	testing.expect_value(t, loaded[1].ingredients[0].name, "pasta")
	testing.expect_value(t, loaded[1].steps[3], "Toss the pasta with the sauce, basil, and parmesan, adding pasta water as needed.")
	testing.expect_value(t, loaded[2].ingredients[0].name, "chicken breast, sliced")
	testing.expect_value(t, loaded[2].steps[0], "Sear the chicken in a hot, oiled pan until cooked through, then set aside.")

	// Description, notes, and NULL image_path round-trip.
	testing.expect_value(t, loaded[0].description, "A classic loaf, best with very ripe bananas.")
	testing.expect_value(t, loaded[0].notes, "Optional: fold in walnuts or chocolate chips before baking.")
	testing.expect_value(t, loaded[0].image_path, "")
}

@(test)
test_db_seeding_twice_does_not_duplicate :: proc(t: ^testing.T) {
	path := "/tmp/odin-microui-test-reseed.db"
	db := open_temp_db(t, path)
	defer os.remove(path)
	defer close_database(db)
	if db == nil {
		return
	}

	err := ensure_schema_and_seed(db, RECIPES[:])
	testing.expect(t, err == "", err)
	err = ensure_schema_and_seed(db, RECIPES[:])
	testing.expect(t, err == "", err)

	loaded, load_err := load_recipes(db)
	testing.expect(t, load_err == "", load_err)
	if load_err != "" {
		return
	}
	defer free_loaded_recipes(loaded)
	testing.expect_value(t, len(loaded), 3)
}

@(test)
test_db_insert_update_delete_round_trip :: proc(t: ^testing.T) {
	path := "/tmp/odin-microui-test-roundtrip.db"
	db := open_temp_db(t, path)
	defer os.remove(path)
	defer close_database(db)
	if db == nil {
		return
	}

	err := ensure_schema_and_seed(db, RECIPES[:])
	testing.expect(t, err == "", err)

	// Insert.
	new_ingredients := [2]Ingredient{
		{amount = "2", unit = "", name = "carrots, chopped"},
		{amount = "1", unit = "litre", name = "vegetable stock"},
	}
	new_steps := [2]string{
		"Simmer the carrots in the stock for 20 minutes.",
		"Blend until smooth.",
	}
	new_recipe := Recipe{
		title       = "Test Soup",
		description = "A soup for testing.",
		servings    = 2,
		ingredients = new_ingredients[:],
		steps       = new_steps[:],
		notes       = "Test only.",
	}
	id, insert_err := insert_recipe(db, new_recipe)
	testing.expect(t, insert_err == "", insert_err)
	testing.expect(t, id != 0)

	loaded, load_err := load_recipes(db)
	testing.expect(t, load_err == "", load_err)
	if load_err != "" {
		return
	}
	testing.expect_value(t, len(loaded), 4)
	inserted, inserted_found := find_recipe(loaded, id)
	testing.expect(t, inserted_found)
	if inserted_found {
		testing.expect_value(t, inserted.title, "Test Soup")
		testing.expect_value(t, inserted.servings, 2)
		testing.expect_value(t, len(inserted.ingredients), 2)
		testing.expect_value(t, inserted.ingredients[0].name, "carrots, chopped")
		testing.expect_value(t, inserted.ingredients[1].name, "vegetable stock")
		testing.expect_value(t, len(inserted.steps), 2)
		testing.expect_value(t, inserted.steps[0], "Simmer the carrots in the stock for 20 minutes.")
		testing.expect_value(t, inserted.steps[1], "Blend until smooth.")
	}
	free_loaded_recipes(loaded)

	// Update: replace title, servings, and ALL children — the
	// old ingredients/steps must be gone, not appended to.
	upd_ingredients := [1]Ingredient{
		{amount = "3", unit = "", name = "potatoes, diced"},
	}
	upd_steps := [3]string{
		"Boil the potatoes.",
		"Mash them.",
		"Season and serve.",
	}
	updated := Recipe{
		id          = id,
		title       = "Test Soup Revised",
		description = "Revised description.",
		servings    = 6,
		ingredients = upd_ingredients[:],
		steps       = upd_steps[:],
		notes       = "Revised notes.",
	}
	update_err := update_recipe(db, updated)
	testing.expect(t, update_err == "", update_err)

	loaded, load_err = load_recipes(db)
	testing.expect(t, load_err == "", load_err)
	if load_err != "" {
		return
	}
	testing.expect_value(t, len(loaded), 4)
	after_update, updated_found := find_recipe(loaded, id)
	testing.expect(t, updated_found)
	if updated_found {
		testing.expect_value(t, after_update.title, "Test Soup Revised")
		testing.expect_value(t, after_update.servings, 6)
		testing.expect_value(t, after_update.description, "Revised description.")
		testing.expect_value(t, after_update.notes, "Revised notes.")
		testing.expect_value(t, len(after_update.ingredients), 1)
		if len(after_update.ingredients) == 1 {
			testing.expect_value(t, after_update.ingredients[0].name, "potatoes, diced")
		}
		testing.expect_value(t, len(after_update.steps), 3)
		if len(after_update.steps) == 3 {
			testing.expect_value(t, after_update.steps[2], "Season and serve.")
		}
	}
	free_loaded_recipes(loaded)

	// Delete: parent and children both go.
	testing.expect_value(t, count_child_rows(db, "ingredients", id), 1)
	testing.expect_value(t, count_child_rows(db, "steps", id), 3)
	delete_err := delete_recipe(db, id)
	testing.expect(t, delete_err == "", delete_err)
	testing.expect_value(t, count_child_rows(db, "ingredients", id), 0)
	testing.expect_value(t, count_child_rows(db, "steps", id), 0)

	loaded, load_err = load_recipes(db)
	testing.expect(t, load_err == "", load_err)
	if load_err != "" {
		return
	}
	defer free_loaded_recipes(loaded)
	testing.expect_value(t, len(loaded), 3)
	_, deleted_found := find_recipe(loaded, id)
	testing.expect(t, !deleted_found)
}
