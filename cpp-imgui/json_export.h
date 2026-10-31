#pragma once

// JSON export for the recipe manager.
//
// This is the mirror of json_import.h: it serializes the same
// per-recipe fields, in the same order, so an exported file can
// be imported again unchanged (through parse_recipes). The two
// document shapes are:
//   - a single recipe, as a pretty-printed bare object:
//     {"title": ..., ...}
//   - a collection, as a pretty-printed {"recipes": [...]} object.
// The collection shape is the one test-data/recipes.json uses,
// so "Export all" writes that shape, not a bare array.
//
// This stack has its own JSON parser, not serde, so it gets its
// own serializer too, with no new dependency: strings are
// escaped the way the parser expects (", \, and the control
// characters \b \f \n \r \t, other control characters as
// \u00XX), and non-ASCII bytes pass through as UTF-8, as
// serde_json does. Numbers are plain integers. Pretty-printing
// uses two-space indentation, as serde_json::to_string_pretty
// does in rust-egui.
//
// The file picker (filepicker.h, save mode) is what chooses the
// file name and location; this module only turns recipes into
// text and writes that text to the chosen path. Serializing
// runs on the UI thread: the data is already in memory, and
// writing a recipe file is small, so there is no worker thread
// here the way import has one for fetching and parsing.

#include <string>
#include <vector>

#include "db.h"

// Serialize one recipe as a pretty-printed bare JSON object.
// Always succeeds for a Recipe (every field is a string, an
// integer, or a list of those), so there is no error out-param.
std::string export_single(const Recipe& recipe);

// Serialize a slice of recipes as a pretty-printed
// {"recipes": [...]} collection object.
std::string export_collection(const std::vector<Recipe>& recipes);

// Write already-serialized JSON text to the given path,
// creating or overwriting it. On failure returns false and
// sets error to "Could not write file <path>: <reason>.",
// matching this stack's import error style ("Could not read
// file <path>: <reason>.").
bool write_export(const std::string& path, const std::string& text,
                  std::string& error);

// A file name derived from a recipe title, safe to offer as the
// save dialog's default: characters that are not letters,
// digits, spaces, hyphens, or underscores become underscores,
// so a title like "Fish & Chips" does not become a strange file
// name, and a title containing "/" cannot escape the chosen
// directory. A title that sanitizes to nothing (empty, or only
// whitespace) falls back to "recipe.json".
//
// One difference from rust-egui: this is byte-wise ASCII, so a
// non-ASCII byte becomes an underscore (a UTF-8 letter is
// several bytes, so it becomes several underscores), where
// rust-egui's Unicode-aware check keeps it. The ASCII cases
// the save dialog defaults actually exercise — plain titles,
// "&" and "/" — match exactly.
std::string default_file_name(const std::string& title);
