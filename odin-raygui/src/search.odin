package main

import "core:strings"

// The recipe-list search predicate, extracted verbatim from
// the filter loop in main.odin so it can be unit-tested
// without opening a window. Semantics are unchanged:
// case-insensitive substring match on the recipe TITLE
// only (never description, ingredients, steps, or notes);
// the query is trimmed first, so an empty (or
// whitespace-only) query matches everything.
title_matches_query :: proc(title, query: string) -> bool {
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	if q == "" {
		return true
	}
	return strings.contains(strings.to_lower(title, context.temp_allocator), q)
}
