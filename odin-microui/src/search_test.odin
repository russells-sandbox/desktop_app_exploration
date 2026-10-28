package main

import "core:testing"

// Search semantics under test (src/main.odin, matches_search):
// case-insensitive substring match on the recipe TITLE only;
// an empty query matches everything. Seed titles: Banana Bread,
// Tomato Basil Pasta, Chicken Stir Fry.

@(test)
test_search_empty_query_matches_all :: proc(t: ^testing.T) {
	testing.expect(t, matches_search("Banana Bread", ""))
	testing.expect(t, matches_search("Tomato Basil Pasta", ""))
	testing.expect(t, matches_search("Chicken Stir Fry", ""))
}

@(test)
test_search_exact_title :: proc(t: ^testing.T) {
	testing.expect(t, matches_search("Banana Bread", "Banana Bread"))
	testing.expect(t, !matches_search("Tomato Basil Pasta", "Banana Bread"))
	testing.expect(t, !matches_search("Chicken Stir Fry", "Banana Bread"))
}

@(test)
test_search_mixed_case_query :: proc(t: ^testing.T) {
	testing.expect(t, matches_search("Banana Bread", "BANANA"))
	testing.expect(t, matches_search("Tomato Basil Pasta", "ToMaTo"))
	testing.expect(t, matches_search("Chicken Stir Fry", "cHiCkEn StIr FrY"))
}

@(test)
test_search_partial_substring :: proc(t: ^testing.T) {
	testing.expect(t, matches_search("Tomato Basil Pasta", "tom"))
	testing.expect(t, !matches_search("Banana Bread", "tom"))
	testing.expect(t, !matches_search("Chicken Stir Fry", "tom"))
	testing.expect(t, matches_search("Chicken Stir Fry", "stir"))
	testing.expect(t, matches_search("Banana Bread", "ana"))
}

@(test)
test_search_query_matching_nothing :: proc(t: ^testing.T) {
	testing.expect(t, !matches_search("Banana Bread", "zzz"))
	testing.expect(t, !matches_search("Tomato Basil Pasta", "zzz"))
	testing.expect(t, !matches_search("Chicken Stir Fry", "zzz"))
	testing.expect(t, !matches_search("Banana Bread", "pasta"))
}

@(test)
test_search_query_longer_than_title_matches_nothing :: proc(t: ^testing.T) {
	testing.expect(t, !matches_search("Banana Bread", "Banana Bread Extra"))
	testing.expect(t, !matches_search("Banana Bread", "Banana Breads"))
	testing.expect(t, !matches_search("Chicken Stir Fry", "Chicken Stir Fry With Rice And More"))
}

@(test)
test_search_matches_title_only_not_description :: proc(t: ^testing.T) {
	// "ripe" appears in Banana Bread's description ("best with
	// very ripe bananas") but not in its title, so it must not
	// match; likewise "soy" is in Chicken Stir Fry's description
	// and ingredients, but not its title.
	testing.expect(t, !matches_search("Banana Bread", "ripe"))
	testing.expect(t, !matches_search("Chicken Stir Fry", "soy"))
}
