// Title search predicate, extracted from the recipe list in main.rs
// so it can be unit-tested without building the UI. Semantics:
// case-insensitive substring match on the recipe title only; an
// empty query matches everything. A query that matches only a
// description, an ingredient, or a step does not match.
pub(crate) fn recipe_matches_search(title: &str, query: &str) -> bool {
    let query = query.to_lowercase();
    query.is_empty() || title.to_lowercase().contains(&query)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The seed titles, matching src/seed.rs.
    const TITLES: [&str; 3] = ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"];

    fn matches(query: &str) -> Vec<&'static str> {
        TITLES
            .iter()
            .copied()
            .filter(|title| recipe_matches_search(title, query))
            .collect()
    }

    #[test]
    fn empty_query_matches_all() {
        assert_eq!(matches(""), TITLES);
    }

    #[test]
    fn exact_title_matches() {
        assert_eq!(matches("Banana Bread"), ["Banana Bread"]);
        assert_eq!(matches("Chicken Stir Fry"), ["Chicken Stir Fry"]);
    }

    #[test]
    fn mixed_case_query_matches() {
        assert_eq!(matches("BANANA"), ["Banana Bread"]);
        assert_eq!(matches("tOmAtO"), ["Tomato Basil Pasta"]);
    }

    #[test]
    fn partial_substring_matches() {
        assert_eq!(matches("tom"), ["Tomato Basil Pasta"]);
        assert_eq!(matches("read"), ["Banana Bread"]);
    }

    #[test]
    fn query_matching_nothing_matches_none() {
        assert!(matches("pizza").is_empty());
        assert!(matches("zzz").is_empty());
    }

    #[test]
    fn query_longer_than_title_matches_nothing() {
        assert!(matches("Banana Bread with walnuts and chocolate chips").is_empty());
        assert!(matches("Tomato Basil Pasta extra").is_empty());
    }

    #[test]
    fn description_only_query_does_not_match() {
        // "weeknight" appears in Tomato Basil Pasta's description,
        // not its title, so it must not match.
        assert!(matches("weeknight").is_empty());
        assert!(matches("ripe bananas").is_empty());
    }
}
