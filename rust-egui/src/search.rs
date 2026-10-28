// Search predicate for the recipe list, extracted verbatim from the
// inline filter in main.rs so it can be unit-tested.
// Semantics: case-insensitive substring match on the recipe TITLE
// only. An empty query matches everything.
pub(crate) fn matches_search(title: &str, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    title.to_lowercase().contains(&query.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TITLES: [&str; 3] = ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"];

    fn matching_titles(query: &str) -> Vec<&'static str> {
        TITLES
            .iter()
            .copied()
            .filter(|title| matches_search(title, query))
            .collect()
    }

    #[test]
    fn empty_query_matches_all() {
        assert_eq!(matching_titles(""), TITLES);
    }

    #[test]
    fn exact_title_matches_only_that_recipe() {
        assert_eq!(matching_titles("Banana Bread"), vec!["Banana Bread"]);
        assert_eq!(
            matching_titles("Tomato Basil Pasta"),
            vec!["Tomato Basil Pasta"]
        );
        assert_eq!(
            matching_titles("Chicken Stir Fry"),
            vec!["Chicken Stir Fry"]
        );
    }

    #[test]
    fn mixed_case_query_matches() {
        assert_eq!(matching_titles("BANANA"), vec!["Banana Bread"]);
        assert_eq!(matching_titles("bAnAnA bReAd"), vec!["Banana Bread"]);
    }

    #[test]
    fn partial_substring_matches() {
        assert_eq!(matching_titles("tom"), vec!["Tomato Basil Pasta"]);
        assert_eq!(matching_titles("STIR"), vec!["Chicken Stir Fry"]);
        assert_eq!(matching_titles("Bread"), vec!["Banana Bread"]);
    }

    #[test]
    fn query_matching_nothing_matches_none() {
        assert!(matching_titles("pizza").is_empty());
        assert!(matching_titles("zzz").is_empty());
    }

    #[test]
    fn query_longer_than_title_matches_nothing() {
        assert!(matching_titles("Banana Breads").is_empty());
        assert!(matching_titles("Banana Bread and much more text").is_empty());
    }

    #[test]
    fn match_is_title_only_not_description_or_ingredient() {
        // "weeknight" is in Tomato Basil Pasta's description, and
        // "soy sauce" is one of Chicken Stir Fry's ingredients, but
        // neither appears in a title, so neither may match.
        assert!(matching_titles("weeknight").is_empty());
        assert!(matching_titles("soy").is_empty());
    }
}
