package main

import "core:testing"

// Unit tests for the recipe-list search predicate
// (src/search.odin), extracted from main.odin with identical
// semantics: case-insensitive substring match on the recipe
// TITLE only; an empty query matches everything.

@(test)
test_search_empty_query_matches_all :: proc(t: ^testing.T) {
	titles := []string{"Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"}
	for title in titles {
		testing.expect(t, title_matches_query(title, ""), "empty query should match every title")
		testing.expect(t, title_matches_query(title, "   "), "whitespace-only query should match every title")
	}
}

@(test)
test_search_exact_title :: proc(t: ^testing.T) {
	testing.expect(t, title_matches_query("Banana Bread", "Banana Bread"))
	testing.expect(t, !title_matches_query("Tomato Basil Pasta", "Banana Bread"))
	testing.expect(t, !title_matches_query("Chicken Stir Fry", "Banana Bread"))
}

@(test)
test_search_is_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, title_matches_query("Banana Bread", "BANANA"))
	testing.expect(t, title_matches_query("Banana Bread", "bAnAnA bReAd"))
	testing.expect(t, title_matches_query("Tomato Basil Pasta", "TOMATO"))
	testing.expect(t, !title_matches_query("Tomato Basil Pasta", "BANANA"))
}

@(test)
test_search_partial_substring :: proc(t: ^testing.T) {
	testing.expect(t, title_matches_query("Tomato Basil Pasta", "tom"))
	testing.expect(t, title_matches_query("Tomato Basil Pasta", "basil"))
	testing.expect(t, title_matches_query("Chicken Stir Fry", "stir"))
	testing.expect(t, !title_matches_query("Banana Bread", "tom"))
	testing.expect(t, !title_matches_query("Chicken Stir Fry", "tom"))
}

@(test)
test_search_query_matching_nothing :: proc(t: ^testing.T) {
	titles := []string{"Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"}
	for title in titles {
		testing.expectf(t, !title_matches_query(title, "pizza"), "query matching nothing matched %q", title)
	}
}

@(test)
test_search_query_longer_than_title_matches_nothing :: proc(t: ^testing.T) {
	testing.expect(t, !title_matches_query("Banana Bread", "Banana Breads"))
	testing.expect(t, !title_matches_query("Banana Bread", "Banana Bread is a very long query"))
	testing.expect(t, !title_matches_query("Chicken Stir Fry", "Chicken Stir Fry with extra words"))
}

@(test)
test_search_matches_title_only_not_description_or_ingredients :: proc(t: ^testing.T) {
	// "ripe" is in Banana Bread's description ("very ripe
	// bananas") and "soy" is in Chicken Stir Fry's
	// description/ingredients, but neither is in a title.
	testing.expect(t, !title_matches_query("Banana Bread", "ripe"))
	testing.expect(t, !title_matches_query("Chicken Stir Fry", "soy"))
	testing.expect(t, !title_matches_query("Tomato Basil Pasta", "parmesan"))
}

@(test)
test_search_trims_surrounding_whitespace :: proc(t: ^testing.T) {
	testing.expect(t, title_matches_query("Banana Bread", "  banana  "))
	testing.expect(t, !title_matches_query("Banana Bread", "  tomato  "))
}
