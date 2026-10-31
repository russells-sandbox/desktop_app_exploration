package main

import "core:os"
import "core:strings"
import "core:testing"

// Unit tests for JSON export (src/json_export.odin),
// mirroring rust-egui's json_export tests: single and
// collection shapes re-importing through this stack's
// own parse_recipes, the empty collection, image_path
// preserved, file-name sanitization, write-and-overwrite,
// and a write-to-a-missing-directory error. Two extra
// tests cover what a hand-written serializer can get
// wrong where serde cannot: escaping, and field order.
//
// The sample data lives in package-level globals, like
// src/recipes.odin's seed arrays: a slice literal built
// inside a helper proc would be backed by that proc's
// stack frame and corrupted once it returned.

export_sample_ingredients := [1]Ingredient{
	{amount = "1", unit = "lb", name = "mushrooms"},
}

export_sample_steps := [1]string{"Cook it."}

export_sample_recipe := Recipe{
	title       = "Mushroom Risotto",
	description = "Creamy rice.",
	servings    = 4,
	notes       = "Stir often.",
	ingredients = export_sample_ingredients[:],
	steps       = export_sample_steps[:],
}

@(test)
test_export_single_is_a_bare_object_that_reimports :: proc(t: ^testing.T) {
	text := export_single(export_sample_recipe)
	// Bare object, not wrapped in a "recipes" collection.
	testing.expect(t, strings.has_prefix(strings.trim_space(text), "{"), "single export should start with {")
	testing.expect(t, !strings.contains(text, "\"recipes\""), "single export should not contain a recipes field")
	recipes, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(recipes), 1)
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	testing.expect_value(t, recipes[0].servings, 4)
	testing.expect_value(t, recipes[0].image_path, "")
	testing.expect_value(t, len(recipes[0].ingredients), 1)
	testing.expect_value(t, recipes[0].ingredients[0].name, "mushrooms")
	testing.expect_value(t, len(recipes[0].steps), 1)
	testing.expect_value(t, recipes[0].steps[0], "Cook it.")
}

@(test)
test_export_single_field_order :: proc(t: ^testing.T) {
	text := export_single(export_sample_recipe)
	keys := []string{"\"title\"", "\"description\"", "\"servings\"", "\"image_path\"", "\"notes\"", "\"ingredients\"", "\"steps\""}
	previous := -1
	for key in keys {
		pos := strings.index(text, key)
		testing.expectf(t, pos >= 0, "single export should contain %s", key)
		testing.expectf(t, pos > previous, "%s should come after the previous field", key)
		previous = pos
	}
}

@(test)
test_export_collection_is_a_recipes_object_that_reimports :: proc(t: ^testing.T) {
	recipes := []Recipe{export_sample_recipe, export_sample_recipe}
	text := export_collection(recipes)
	testing.expect(t, strings.contains(text, "\"recipes\""), "collection export should contain a recipes field")
	parsed, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(parsed), 2)
	testing.expect_value(t, parsed[0].title, "Mushroom Risotto")
	testing.expect_value(t, parsed[1].title, "Mushroom Risotto")
}

@(test)
test_export_collection_empty_is_an_empty_recipes_array :: proc(t: ^testing.T) {
	empty: []Recipe = nil
	text := export_collection(empty)
	testing.expect(t, strings.contains(text, "\"recipes\": []"), "empty collection should be \"recipes\": [], got: %s", text)
	parsed, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, len(parsed), 0)
}

@(test)
test_export_preserves_image_path_when_present :: proc(t: ^testing.T) {
	recipe := export_sample_recipe
	recipe.image_path = "images/risotto.png"
	text := export_single(recipe)
	testing.expect(t, strings.contains(text, "images/risotto.png"), "export should contain the image path")
	parsed, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, parsed[0].image_path, "images/risotto.png")
}

@(test)
test_export_escapes_quotes_backslash_and_control_characters :: proc(t: ^testing.T) {
	recipe := export_sample_recipe
	recipe.title = "Fish \"Special\" \\ Menu\nNext\tTab"
	text := export_single(recipe)
	// The raw title must not appear unescaped, and the
	// escaped form must re-import to the original title.
	testing.expect(t, !strings.contains(text, "Fish \"Special\""), "quotes must be escaped")
	testing.expect(t, strings.contains(text, "Fish \\\"Special\\\" \\\\ Menu\\nNext\\tTab"), "escaped title not found, got: %s", text)
	parsed, err := parse_recipes(text)
	testing.expectf(t, err == "", "parse_recipes: %s", err)
	testing.expect_value(t, parsed[0].title, "Fish \"Special\" \\ Menu\nNext\tTab")
}

@(test)
test_export_default_file_name_sanitizes_and_falls_back :: proc(t: ^testing.T) {
	testing.expect_value(t, default_file_name("Banana Bread"), "Banana Bread.json")
	testing.expect_value(t, default_file_name("Fish & Chips / Fries"), "Fish _ Chips _ Fries.json")
	testing.expect_value(t, default_file_name("   "), "recipe.json")
	testing.expect_value(t, default_file_name(""), "recipe.json")
}

@(test)
test_export_write_writes_and_overwrites :: proc(t: ^testing.T) {
	path := "/tmp/odin-raygui-export-test-write.json"
	os.remove(path)
	defer os.remove(path)
	err := write_export(path, `{"title": "Toast"}`)
	testing.expectf(t, err == "", "write_export: %s", err)
	data, rerr := os.read_entire_file(path, context.allocator)
	testing.expectf(t, rerr == nil, "read back: %v", rerr)
	testing.expect_value(t, string(data), `{"title": "Toast"}`)
	err = write_export(path, "replaced")
	testing.expectf(t, err == "", "write_export overwrite: %s", err)
	data, rerr = os.read_entire_file(path, context.allocator)
	testing.expectf(t, rerr == nil, "read back overwrite: %v", rerr)
	testing.expect_value(t, string(data), "replaced")
}

@(test)
test_export_write_to_a_missing_directory_is_an_error :: proc(t: ^testing.T) {
	path := "/tmp/odin-raygui-export-test-no-such-dir/out.json"
	err := write_export(path, "x")
	testing.expect(t, err != "", "writing to a missing directory should be an error")
	testing.expect(t, strings.contains(err, "Could not write file"), "error should name the write failure, got: %s", err)
}
