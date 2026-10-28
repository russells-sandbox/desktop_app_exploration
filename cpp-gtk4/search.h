#pragma once

// The recipe-list search predicate, shared by the app and the
// unit tests. Extracted verbatim from main.cpp's apply_filter so
// the app and the tests cannot drift apart.
//
// Semantics (do not change without changing the app behaviour):
//  - Case-insensitive substring match on the recipe TITLE only.
//  - An empty query matches everything.
//  - The query is NOT trimmed: leading/trailing spaces are part
//    of the match, exactly as the app's search entry passes them.
//  - No dependency on GTK or SQLite, so the search tests build
//    with plain g++ even where those headers are unavailable.

#include <cctype>
#include <string>

inline std::string search_lowercased(const std::string& text) {
    std::string out = text;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

inline bool title_matches_search(const std::string& title,
                                 const std::string& query) {
    if (query.empty()) {
        return true;
    }
    return search_lowercased(title).find(search_lowercased(query)) !=
           std::string::npos;
}
