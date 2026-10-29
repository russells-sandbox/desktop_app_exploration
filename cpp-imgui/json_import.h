#pragma once

// JSON import from a URL for the recipe manager.
//
// This mirrors rust-egui's json_import module in behaviour, with
// the same accepted shapes, defaults, and error cases:
//
// Accepted document shapes (see test-data/README.md for fixtures
// for each one):
//   - a single recipe object: {"title": ..., ...}
//   - a bare array of recipe objects: [{...}, {...}]
//   - a collection object: {"recipes": [...]}
// A recipe's fields follow test-data/recipes.json: title,
// description, servings, image_path, notes, ingredients (amount,
// unit, name objects, in order), and steps (strings, in order).
// Missing description, notes, ingredients, or steps default to
// empty; missing image_path defaults to null (empty string here,
// since this stack stores image_path as a plain string, not an
// Option); missing servings defaults to 0. A recipe with no
// usable title is an error, not a recipe with an empty title in
// the list.
//
// Fetching is deliberately dependency-light, like rust-egui: a
// plain POSIX-socket HTTP client, no HTTP library, no TLS, and
// no new package. Only http:// is supported; an https:// URL
// fails with a clear message saying so. The QA route for this
// test app is the local test-data server, which serves plain
// http:// on localhost.
//
// The JSON parser here is a small focused one for exactly these
// recipe shapes: objects, arrays, strings (with escapes,
// including \u), numbers, true/false, and null. It is not a
// general-purpose JSON library, and it is not used for anything
// else. If a later feature needs full JSON (nested values of
// arbitrary shape, or strict spec compliance beyond what the
// recipe shapes exercise), replacing this parser with a real
// library is the right move; the parse_recipes/fetch_and_parse
// interface would not need to change.
//
// The fetch runs on a worker thread (see main.cpp, which spawns
// it the same way image decoding runs on a worker thread) and
// the database inserts happen on the UI thread afterwards,
// using the same insert_recipe the Add form uses.

#include <string>
#include <vector>

#include "db.h"

// Parses a whole document in any of the three accepted shapes.
// On failure returns false and sets error; recipes is left
// untouched on failure (parsing is all-or-nothing: a document
// with one bad recipe imports nothing, it does not import a
// partial list).
bool parse_recipes(const std::string& text, std::vector<Recipe>& recipes,
                   std::string& error);

// Fetches the document at url (http:// only, up to 3 redirects)
// and returns its body as text. On failure returns false and
// sets error.
bool fetch_url(const std::string& url, std::string& body, std::string& error);

// Fetch a document and parse it. This is what the worker thread
// runs, so a slow server or a large document never blocks the UI.
bool fetch_and_parse(const std::string& url, std::vector<Recipe>& recipes,
                     std::string& error);
