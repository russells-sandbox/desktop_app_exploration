package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// JSON export for the recipe manager.
//
// This is the mirror of json_import.odin: it serializes the
// same per-recipe fields, in the same order, so an exported
// file can be imported again unchanged. The two document
// shapes are:
//   - a single recipe, as a pretty-printed bare object:
//     {"title": ..., ...}
//   - a collection, as a pretty-printed {"recipes": [...]}
//     object, the shape test-data/recipes.json uses, so
//     "Export all" writes that shape, not a bare array.
//
// SERIALIZATION: written by hand, not with
// core:encoding/json's marshaller. The marshaller takes a
// json.Value tree, whose Object is a map, so it cannot
// preserve the import format's field order (title,
// description, servings, image_path, notes, ingredients,
// steps); it would emit keys in map order instead. Hand
// building also gives the exact pretty-printing the Rust
// version's serde_json::to_string_pretty produces: two-space
// indent, and empty arrays on one line ("ingredients": []).
// Escaping matches serde_json: ", \, and the control
// characters \b \f \n \r \t, with any other byte below
// 0x20 as \u00xx; bytes at or above 0x20 pass through
// unchanged, so UTF-8 text (like "350°F") stays UTF-8.
//
// OWNERSHIP: export_single and export_collection return a
// heap string the caller owns (cloned out of the builder,
// whose buffer is then destroyed); the caller deletes it
// when done. write_export's error string, when non-empty,
// is likewise heap-allocated and caller-owned. In main.odin
// the export status strings follow the same ownership rule
// as the import messages: heap-owned when non-empty, freed
// before they are replaced.
//
// The export runs on the UI thread, like the Rust version:
// the data is already in memory and writing a recipe file
// is small, so there is no worker thread here the way
// import has one for fetching and parsing. The path is
// typed in main.odin (raylib has no file picker), not
// picked from a dialog.

write_indent :: proc(b: ^strings.Builder, level: int) {
	for _ in 0 ..< level {
		strings.write_string(b, "  ")
	}
}

// One JSON string, with the escaping described above. Bytes
// are walked, not runes: a multi-byte UTF-8 character's
// bytes are all at or above 0x20 except for the quote and
// backslash bytes, which never appear inside a multi-byte
// sequence, so passing them through is safe.
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
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
			if c < 0x20 {
				hex := "0123456789abcdef"
				strings.write_string(b, "\\u00")
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 0x0f])
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

write_json_int :: proc(b: ^strings.Builder, value: int) {
	strings.write_int(b, value)
}

// One recipe object, its opening brace at `level` indent,
// its fields at `level + 1`. An ingredient object sits at
// `level + 2`, its fields at `level + 3`; step strings sit
// at `level + 2`.
write_recipe :: proc(b: ^strings.Builder, recipe: Recipe, level: int) {
	strings.write_string(b, "{\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"title\": ")
	write_json_string(b, recipe.title)
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"description\": ")
	write_json_string(b, recipe.description)
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"servings\": ")
	write_json_int(b, recipe.servings)
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"image_path\": ")
	// This stack stores "no image" as "" (see recipes.odin);
	// the import format writes that as null, not "".
	if recipe.image_path == "" {
		strings.write_string(b, "null")
	} else {
		write_json_string(b, recipe.image_path)
	}
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"notes\": ")
	write_json_string(b, recipe.notes)
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"ingredients\": ")
	if len(recipe.ingredients) == 0 {
		strings.write_string(b, "[]")
	} else {
		strings.write_string(b, "[\n")
		for ingredient, i in recipe.ingredients {
			write_indent(b, level + 2)
			strings.write_string(b, "{\n")
			write_indent(b, level + 3)
			strings.write_string(b, "\"amount\": ")
			write_json_string(b, ingredient.amount)
			strings.write_string(b, ",\n")
			write_indent(b, level + 3)
			strings.write_string(b, "\"unit\": ")
			write_json_string(b, ingredient.unit)
			strings.write_string(b, ",\n")
			write_indent(b, level + 3)
			strings.write_string(b, "\"name\": ")
			write_json_string(b, ingredient.name)
			strings.write_string(b, "\n")
			write_indent(b, level + 2)
			strings.write_string(b, "}")
			if i < len(recipe.ingredients) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		write_indent(b, level + 1)
		strings.write_string(b, "]")
	}
	strings.write_string(b, ",\n")
	write_indent(b, level + 1)
	strings.write_string(b, "\"steps\": ")
	if len(recipe.steps) == 0 {
		strings.write_string(b, "[]")
	} else {
		strings.write_string(b, "[\n")
		for step, i in recipe.steps {
			write_indent(b, level + 2)
			write_json_string(b, step)
			if i < len(recipe.steps) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		write_indent(b, level + 1)
		strings.write_string(b, "]")
	}
	strings.write_string(b, "\n")
	write_indent(b, level)
	strings.write_string(b, "}")
}

// Serialize one recipe as a pretty-printed bare JSON object.
// The caller owns the returned string and deletes it.
export_single :: proc(recipe: Recipe, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	write_recipe(&builder, recipe, 0)
	text := strings.clone(strings.to_string(builder), allocator)
	strings.builder_destroy(&builder)
	return text
}

// Serialize a slice of recipes as a pretty-printed
// {"recipes": [...]} collection object. The caller owns the
// returned string and deletes it.
export_collection :: proc(recipes: []Recipe, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, "{\n")
	write_indent(&builder, 1)
	strings.write_string(&builder, "\"recipes\": ")
	if len(recipes) == 0 {
		strings.write_string(&builder, "[]")
	} else {
		strings.write_string(&builder, "[\n")
		for recipe, i in recipes {
			write_indent(&builder, 1)
			write_recipe(&builder, recipe, 1)
			if i < len(recipes) - 1 {
				strings.write_string(&builder, ",")
			}
			strings.write_string(&builder, "\n")
		}
		write_indent(&builder, 1)
		strings.write_string(&builder, "]")
	}
	strings.write_string(&builder, "\n}")
	text := strings.clone(strings.to_string(builder), allocator)
	strings.builder_destroy(&builder)
	return text
}

// Write already-serialized JSON text to the given path,
// creating or overwriting it. Returns "" on success, or a
// heap error string (caller-owned) on failure, in the
// importer's "Could not read file ..." style.
write_export :: proc(path: string, text: string) -> string {
	if err := os.write_entire_file(path, transmute([]byte)text); err != nil {
		return fmt.aprintf("Could not write file %s: %v.", path, err)
	}
	return ""
}

// A file name derived from a recipe title, safe to offer as
// the single-recipe export field's default: characters that
// are not letters, digits, spaces, hyphens, or underscores
// become underscores, so a title like "Fish & Chips" does
// not become a strange file name, and a title containing
// "/" cannot escape the chosen directory. Runes, not bytes:
// a multi-byte letter stays a letter, it is not split into
// replacement underscores. The result is trimmed, and an
// empty result falls back to "recipe.json", like the Rust
// version's default_file_name.
default_file_name :: proc(title: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	rest := title
	for len(rest) > 0 {
		r, size := utf8.decode_rune_in_string(rest)
		rest = rest[size:]
		if unicode.is_letter(r) || unicode.is_number(r) || r == ' ' || r == '-' || r == '_' {
			strings.write_rune(&builder, r)
		} else {
			strings.write_byte(&builder, '_')
		}
	}
	sanitized := strings.clone(strings.to_string(builder), allocator)
	strings.builder_destroy(&builder)
	trimmed := strings.trim_space(sanitized)
	if trimmed == "" {
		delete(sanitized, allocator)
		return strings.clone("recipe.json", allocator)
	}
	// Trimming only removes spaces, which are single bytes,
	// so the trimmed string still aliases the sanitized
	// allocation; clone it and free the original.
	name := strings.concatenate({trimmed, ".json"}, allocator)
	delete(sanitized, allocator)
	return name
}

// Finish an export in main.odin's status display: free the
// previous message/error (heap-owned when non-empty, like
// the import messages), write the file, and on success set
// a message naming what was exported and the path written,
// or on failure set the write error. `summary` is only
// used to build the message, never kept.
finish_export :: proc(
	message: ^string,
	err_out: ^string,
	path: string,
	serialized: string,
	summary: string,
) {
	if message^ != "" {
		delete(message^)
	}
	if err_out^ != "" {
		delete(err_out^)
	}
	message^ = ""
	err_out^ = ""
	if err := write_export(path, serialized); err != "" {
		err_out^ = err
		return
	}
	message^ = fmt.aprintf("%s to %s.", summary, path)
}
