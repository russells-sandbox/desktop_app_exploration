package main

import "core:os"
import "core:strings"
import "core:testing"

// JSON export tests (src/json_export.odin), mirroring
// rust-egui's json_export tests: the exported text must
// re-import through this stack's own parse_recipes with
// the same fields, in both shapes, plus the file-write and
// file-name behaviour. Exported strings are heap-owned
// (see json_export.odin) and are deleted by these tests;
// parsed recipes are freed with free_imported_recipes.
//
// The sample's ingredient and step arrays are package-level
// globals, like the seed data in recipes.odin: a slice
// literal returned from a procedure is backed by that
// procedure's stack frame, so building them in a helper
// would corrupt the data once it returned.

sample_ingredients := [1]Ingredient{
	{amount = "1", unit = "lb", name = "mushrooms"},
}

sample_steps := [1]string{
	"Cook it.",
}

sample_recipe :: proc() -> Recipe {
	return Recipe{
		id = 1,
		title = "Mushroom Risotto",
		description = "Creamy rice.",
		servings = 4,
		ingredients = sample_ingredients[:],
		steps = sample_steps[:],
		notes = "Stir often.",
	}
}

@(test)
test_json_export_single_is_a_bare_object_that_reimports :: proc(t: ^testing.T) {
	text := export_single(sample_recipe())
	defer delete(text)
	// Bare object, not wrapped in a "recipes" collection.
	testing.expect(t, strings.has_prefix(text, "{\n"), "single export must be a pretty-printed object")
	testing.expect(t, !strings.contains(text, "\"recipes\""), "single export must not be wrapped")
	recipes, err := parse_recipes(text)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 1)
	if len(recipes) != 1 {
		return
	}
	testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
	testing.expect_value(t, recipes[0].servings, 4)
	// This stack stores "no image" as "" (imported null).
	testing.expect_value(t, recipes[0].image_path, "")
	testing.expect_value(t, len(recipes[0].ingredients), 1)
	if len(recipes[0].ingredients) == 1 {
		testing.expect_value(t, recipes[0].ingredients[0].name, "mushrooms")
	}
	testing.expect_value(t, len(recipes[0].steps), 1)
	if len(recipes[0].steps) == 1 {
		testing.expect_value(t, recipes[0].steps[0], "Cook it.")
	}
}

@(test)
test_json_export_fields_are_in_import_order :: proc(t: ^testing.T) {
	text := export_single(sample_recipe())
	defer delete(text)
	// The import format's order, not map order: title,
	// description, servings, image_path, notes, ingredients,
	// steps. Each field name must appear after the previous.
	fields := []string{
		"\"title\"", "\"description\"", "\"servings\"",
		"\"image_path\"", "\"notes\"", "\"ingredients\"", "\"steps\"",
	}
	previous := -1
	for field in fields {
		index := strings.index(text, field)
		testing.expect(t, index > previous, field)
		previous = index
	}
}

@(test)
test_json_export_collection_is_a_recipes_object_that_reimports :: proc(t: ^testing.T) {
	recipes_in := []Recipe{sample_recipe(), sample_recipe()}
	text := export_collection(recipes_in)
	defer delete(text)
	testing.expect(t, strings.contains(text, "\"recipes\""), "collection export must be wrapped")
	recipes, err := parse_recipes(text)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 2)
	if len(recipes) == 2 {
		testing.expect_value(t, recipes[0].title, "Mushroom Risotto")
		testing.expect_value(t, recipes[1].title, "Mushroom Risotto")
	}
}

@(test)
test_json_export_collection_empty_is_an_empty_recipes_array :: proc(t: ^testing.T) {
	text := export_collection(nil)
	defer delete(text)
	testing.expect(t, strings.contains(text, "\"recipes\": []"), "empty collection must be an empty array")
	recipes, err := parse_recipes(text)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	testing.expect_value(t, len(recipes), 0)
}

@(test)
test_json_export_preserves_image_path_when_present :: proc(t: ^testing.T) {
	recipe := sample_recipe()
	recipe.image_path = "images/risotto.png"
	text := export_single(recipe)
	defer delete(text)
	testing.expect(t, strings.contains(text, "images/risotto.png"), "image_path must be in the export")
	recipes, err := parse_recipes(text)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].image_path, "images/risotto.png")
	} else {
		testing.expect_value(t, len(recipes), 1)
	}
}

@(test)
test_json_export_absent_image_path_is_null :: proc(t: ^testing.T) {
	text := export_single(sample_recipe())
	defer delete(text)
	testing.expect(t, strings.contains(text, "\"image_path\": null"), "absent image_path must be null, not \"\"")
}

@(test)
test_json_export_escapes_quotes_backslashes_and_controls :: proc(t: ^testing.T) {
	// Built with a builder, not a literal: the control
	// byte cannot be written portably in a string literal.
	title_builder := strings.builder_make()
	strings.write_string(&title_builder, "Quote \" and \\ and\nnewline\tand ctrl")
	strings.write_byte(&title_builder, 0x01)
	strings.write_string(&title_builder, " end")
	title := strings.clone(strings.to_string(title_builder))
	strings.builder_destroy(&title_builder)
	defer delete(title)
	recipe := sample_recipe()
	recipe.title = title
	text := export_single(recipe)
	defer delete(text)
	testing.expect(t, strings.contains(text, "\\\""), "quotes must be escaped")
	testing.expect(t, strings.contains(text, "\\\\"), "backslashes must be escaped")
	testing.expect(t, strings.contains(text, "\\n"), "newlines must be escaped")
	testing.expect(t, strings.contains(text, "\\t"), "tabs must be escaped")
	testing.expect(t, strings.contains(text, "\\u0001"), "other control characters must be \\u00xx")
	recipes, err := parse_recipes(text)
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	defer free_imported_recipes(recipes)
	if len(recipes) == 1 {
		testing.expect_value(t, recipes[0].title, title)
	} else {
		testing.expect_value(t, len(recipes), 1)
	}
}

@(test)
test_json_export_default_file_name_sanitizes_and_falls_back :: proc(t: ^testing.T) {
	name := default_file_name("Banana Bread")
	defer delete(name)
	testing.expect_value(t, name, "Banana Bread.json")

	name = default_file_name("Fish & Chips / Fries")
	defer delete(name)
	testing.expect_value(t, name, "Fish _ Chips _ Fries.json")

	name = default_file_name("   ")
	defer delete(name)
	testing.expect_value(t, name, "recipe.json")

	name = default_file_name("")
	defer delete(name)
	testing.expect_value(t, name, "recipe.json")
}

@(test)
test_json_export_write_writes_and_overwrites :: proc(t: ^testing.T) {
	path := "/tmp/odin-microui-test-export.json"
	defer os.remove(path)
	err := write_export(path, "{\"title\": \"Toast\"}")
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	contents, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil, "exported file must be readable")
	if read_err == nil {
		defer delete(contents)
		testing.expect_value(t, string(contents), "{\"title\": \"Toast\"}")
	}
	err = write_export(path, "replaced")
	testing.expect(t, err == "", err)
	if err != "" {
		return
	}
	contents, read_err = os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil, "overwritten file must be readable")
	if read_err == nil {
		defer delete(contents)
		testing.expect_value(t, string(contents), "replaced")
	}
}

@(test)
test_json_export_write_to_a_missing_directory_is_an_error :: proc(t: ^testing.T) {
	path := "/tmp/odin-microui-test-export-no-such-dir/out.json"
	os.remove(path)
	err := write_export(path, "x")
	testing.expect(t, err != "", "writing into a missing directory must be an error")
	testing.expect(t, strings.contains(err, "Could not write file"), err)
}
