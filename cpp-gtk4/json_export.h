#pragma once

// JSON export for the recipe manager.
//
// This is the mirror of json_import.h/.cpp: it serializes the
// same per-recipe fields, in the same order, so an exported file
// can be imported again unchanged. The two document shapes are:
//   - a single recipe, as a bare object: {"title": ..., ...}
//   - a collection, as {"recipes": [...]}
// The collection shape is the one test-data/recipes.json uses,
// so "Export all" writes that shape, not a bare array.
//
// Like json_import.h, this module is dependency-free: plain
// C++ only, no GTK, no SQLite, no JSON library, so the unit
// tests build with plain g++ (see test_json_import.cpp, which
// also covers export). It works on ImportedRecipe, the
// dependency-free recipe shape from json_import.h, rather than
// db.h's Recipe: main.cpp converts a db Recipe to an
// ImportedRecipe (servings int to long long; an empty
// image_path means no image) before exporting. That keeps the
// tests free of SQLite, exactly as the import tests are.
//
// Serializing runs on the UI thread: the data is already in
// memory, and writing a recipe file is small, so there is no
// worker thread here the way import has one for fetching and
// parsing. The OS/GTK save dialog (in main.cpp) is what chooses
// the file name and location; this module only turns recipes
// into text and writes that text to the chosen path.
//
// Escaping: quotes, backslashes, and control characters are
// escaped (\", \\, \b, \f, \n, \r, \t, and \u00XX for other
// control characters below 0x20), so a title, description,
// note, ingredient, or step containing any of them round-trips
// through the import parser. Other bytes, including multi-byte
// UTF-8, are written as-is, matching serde's output in
// rust-egui.

#include <string>
#include <vector>

#include "json_import.h"

// Serialize one recipe as a pretty-printed (2-space indent)
// bare JSON object, fields in import order: title,
// description, servings, image_path (null when empty), notes,
// ingredients (amount, unit, name objects, in order), steps
// (strings, in order).
std::string export_single(const ImportedRecipe& recipe);

// Serialize recipes as a pretty-printed {"recipes": [...]}
// collection object, each recipe in the same shape and field
// order as export_single.
std::string export_collection(const std::vector<ImportedRecipe>& recipes);

// Write already-serialized JSON text to the given path,
// creating or overwriting it. Returns false and sets error on
// failure, of the form "Could not write file {path}: {err}".
// The caller (main.cpp) has already asked the user where the
// file goes via the OS save dialog, so this does not pick a
// path itself.
bool write_export(const std::string& path, const std::string& text,
                  std::string& error);

// A file name derived from a recipe title, safe to offer as
// the save dialog's default: ASCII letters, digits, spaces,
// hyphens, and underscores are kept, other ASCII characters
// become underscores (so a title like "Fish & Chips" does not
// become a strange file name, and a title containing "/"
// cannot escape the chosen directory), and the result is
// trimmed. Non-ASCII characters are kept as-is: this module
// has no Unicode tables to classify them the way Rust's
// char::is_alphanumeric does, and keeping an accented or
// CJK letter is safer for a file name than mangling its
// UTF-8 bytes one by one. An empty result (blank title, or
// a title of nothing but spaces) falls back to "recipe.json".
std::string default_file_name(const std::string& title);
