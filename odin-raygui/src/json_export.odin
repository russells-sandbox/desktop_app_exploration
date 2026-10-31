package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"

// JSON export for the recipe manager, mirroring
// rust-egui/src/json_export.rs: the same two document
// shapes, the same per-recipe fields in the same order,
// and the same pretty-printed layout, so an exported file
// can be imported again unchanged by parse_recipes in
// src/json_import.odin.
//   - a single recipe, as a bare object: {"title": ..., ...}
//   - a collection, as {"recipes": [...]}
// The collection shape is the one test-data/recipes.json
// uses, so "Export all" writes that shape, not a bare
// array.
//
// Serialization is hand-written here, not
// core:encoding/json's marshal: marshal produces compact
// JSON, and this export must be pretty-printed with
// two-space indents like serde_json's to_string_pretty,
// with empty arrays as [] on one line. No new
// dependency: only Odin's standard library.
//
// Strings: non-ASCII text passes through as UTF-8, like
// serde_json. Only the characters JSON requires escaped
// are escaped: " and \, and control characters below
// 0x20 (\b, \f, \n, \r, \t, and \u00XX for the rest).
// Iterating the string as bytes is safe for this: a
// multi-byte UTF-8 sequence never contains a byte below
// 0x20, a quote, or a backslash, so it is copied whole.
//
// The Recipe's image_path is "" for "no image" in this
// stack (db.odin stores "" as NULL), so "" exports as
// JSON null, and a null on import reads back as "" —
// the round trip in the tests covers both directions.
//
// Memory: the exported text is a heap string built by a
// strings.Builder, owned by the caller. Export runs on
// the UI thread (see main.odin): the data is already in
// memory and writing a recipe file is small, so there is
// no worker thread here the way import has one for
// fetching and parsing. The caller (main.odin) supplies
// the path from a typed text field, since raylib has no
// file picker dialog; this module only turns recipes
// into text and writes that text to the chosen path.

write_indent :: proc(b: ^strings.Builder, level: int) {
	for _ in 0..<level {
		strings.write_string(b, "  ")
	}
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for byte in transmute([]byte)s {
		switch byte {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case 0x08:
			strings.write_string(b, "\\b")
		case 0x0c:
			strings.write_string(b, "\\f")
		case:
			if byte < 0x20 {
				// Any other control character: \u00XX.
				// tprintf is a temp string, but it is
				// copied into the builder immediately.
				strings.write_string(b, fmt.tprintf("\\u%04x", byte))
			} else {
				strings.write_byte(b, byte)
			}
		}
	}
	strings.write_byte(b, '"')
}

// Write one recipe object. level is the indent level of
// its opening brace; fields sit one level deeper.
write_recipe_json :: proc(b: ^strings.Builder, recipe: Recipe, level: int) {
	field := level + 1
	strings.write_string(b, "{\n")

	write_indent(b, field)
	strings.write_string(b, "\"title\": ")
	write_json_string(b, recipe.title)
	strings.write_string(b, ",\n")

	write_indent(b, field)
	strings.write_string(b, "\"description\": ")
	write_json_string(b, recipe.description)
	strings.write_string(b, ",\n")

	write_indent(b, field)
	// tprintf is a temp string, copied into the builder
	// immediately, so it is safe here.
	strings.write_string(b, fmt.tprintf("\"servings\": %d,\n", recipe.servings))

	write_indent(b, field)
	strings.write_string(b, "\"image_path\": ")
	if recipe.image_path == "" {
		strings.write_string(b, "null")
	} else {
		write_json_string(b, recipe.image_path)
	}
	strings.write_string(b, ",\n")

	write_indent(b, field)
	strings.write_string(b, "\"notes\": ")
	write_json_string(b, recipe.notes)
	strings.write_string(b, ",\n")

	write_indent(b, field)
	strings.write_string(b, "\"ingredients\": ")
	if len(recipe.ingredients) == 0 {
		strings.write_string(b, "[]")
	} else {
		strings.write_string(b, "[\n")
		for ingredient, i in recipe.ingredients {
			write_indent(b, field+1)
			strings.write_string(b, "{\n")
			write_indent(b, field+2)
			strings.write_string(b, "\"amount\": ")
			write_json_string(b, ingredient.amount)
			strings.write_string(b, ",\n")
			write_indent(b, field+2)
			strings.write_string(b, "\"unit\": ")
			write_json_string(b, ingredient.unit)
			strings.write_string(b, ",\n")
			write_indent(b, field+2)
			strings.write_string(b, "\"name\": ")
			write_json_string(b, ingredient.name)
			strings.write_string(b, "\n")
			write_indent(b, field+1)
			strings.write_string(b, "}")
			if i < len(recipe.ingredients) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		write_indent(b, field)
		strings.write_string(b, "]")
	}
	strings.write_string(b, ",\n")

	write_indent(b, field)
	strings.write_string(b, "\"steps\": ")
	if len(recipe.steps) == 0 {
		strings.write_string(b, "[]")
	} else {
		strings.write_string(b, "[\n")
		for step, i in recipe.steps {
			write_indent(b, field+1)
			write_json_string(b, step)
			if i < len(recipe.steps) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		write_indent(b, field)
		strings.write_string(b, "]")
	}
	strings.write_string(b, "\n")

	write_indent(b, level)
	strings.write_string(b, "}")
}

// Serialize one recipe as a pretty-printed bare JSON
// object.
export_single :: proc(recipe: Recipe) -> string {
	b := strings.builder_make()
	write_recipe_json(&b, recipe, 0)
	return strings.to_string(b)
}

// Serialize a slice of recipes as a pretty-printed
// {"recipes": [...]} collection object.
export_collection :: proc(recipes: []Recipe) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	strings.write_string(&b, "  \"recipes\": ")
	if len(recipes) == 0 {
		strings.write_string(&b, "[]")
	} else {
		strings.write_string(&b, "[\n")
		for recipe, i in recipes {
			write_indent(&b, 2)
			write_recipe_json(&b, recipe, 2)
			if i < len(recipes) - 1 {
				strings.write_string(&b, ",")
			}
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "  ]")
	}
	strings.write_string(&b, "\n}")
	return strings.to_string(b)
}

// Write already-serialized JSON text to the given path,
// creating or overwriting it. The caller (main.odin) has
// already taken the path from a typed field, so this
// does not pick a path itself. The error is heap-cloned
// (not a temp string), so the caller can store it in a
// status variable that outlives the frame — the same
// reason import errors are cloned in main.odin.
write_export :: proc(path: string, text: string) -> string {
	if werr := os.write_entire_file(path, transmute([]byte)text); werr != nil {
		return strings.clone(fmt.tprintf("Could not write file %s: %v.", path, werr))
	}
	return ""
}

// A file name derived from a recipe title, safe to offer
// as a typed path field's default: characters that are
// not letters, digits, spaces, hyphens, or underscores
// become underscores, so a title like "Fish & Chips"
// does not become a strange file name, and a title
// containing "/" cannot escape the chosen directory.
// Mirrors rust-egui's default_file_name, including its
// recipe.json fallback for a blank title. unicode.is_letter
// and is_digit cover non-ASCII letters and digits, like
// Rust's is_alphanumeric.
default_file_name :: proc(title: string) -> string {
	b := strings.builder_make()
	for r in title {
		if unicode.is_letter(r) || unicode.is_digit(r) || r == ' ' || r == '-' || r == '_' {
			strings.write_rune(&b, r)
		} else {
			strings.write_rune(&b, '_')
		}
	}
	sanitized := strings.trim_space(strings.to_string(b))
	if sanitized == "" {
		return "recipe.json"
	}
	return strings.concatenate({sanitized, ".json"})
}
