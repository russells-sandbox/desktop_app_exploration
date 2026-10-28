#pragma once

// Recipe title search predicate, shared by the app (main.cpp)
// and the unit tests (tests/test_search.cpp).
//
// Semantics (unchanged from the previously inline code in
// main.cpp): case-insensitive substring match on the recipe
// TITLE only. An empty query matches everything. This header
// depends only on the standard library, so the search tests
// build without SQLite, SDL, or Dear ImGui.

#include <algorithm>
#include <cctype>
#include <string>

inline std::string to_lower(const std::string& text) {
    std::string lowered = text;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return lowered;
}

// Returns true when recipe title matches query under the
// semantics above.
inline bool recipe_title_matches_search(const std::string& title,
                                        const std::string& query) {
    if (query.empty()) {
        return true;
    }
    return to_lower(title).find(to_lower(query)) != std::string::npos;
}
