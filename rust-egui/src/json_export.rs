// JSON export for the recipe manager.
//
// This is the mirror of json_import.rs: it serializes the same
// per-recipe fields, in the same order, so an exported file can be
// imported again unchanged. The two document shapes are:
//   - a single recipe, as a bare object: {"title": ..., ...}
//   - a collection, as {"recipes": [...]}
// The collection shape is the one test-data/recipes.json uses, so
// "Export all" writes that shape, not a bare array.
//
// Serializing runs on the UI thread: the data is already in
// memory, and writing a recipe file is small, so there is no
// worker thread here the way import has one for fetching and
// parsing. The OS file picker (rfd, in main.rs) is what chooses
// the file name and location; this module only turns recipes
// into text and writes that text to the chosen path.
use crate::Recipe;
use serde::Serialize;

#[derive(Serialize)]
struct JsonIngredient {
    amount: String,
    unit: String,
    name: String,
}

#[derive(Serialize)]
struct JsonRecipe {
    title: String,
    description: String,
    servings: i64,
    image_path: Option<String>,
    notes: String,
    ingredients: Vec<JsonIngredient>,
    steps: Vec<String>,
}

impl From<&Recipe> for JsonRecipe {
    fn from(recipe: &Recipe) -> Self {
        JsonRecipe {
            title: recipe.title.clone(),
            description: recipe.description.clone(),
            servings: recipe.servings,
            image_path: recipe.image_path.clone(),
            notes: recipe.notes.clone(),
            ingredients: recipe
                .ingredients
                .iter()
                .map(|ingredient| JsonIngredient {
                    amount: ingredient.amount.clone(),
                    unit: ingredient.unit.clone(),
                    name: ingredient.name.clone(),
                })
                .collect(),
            steps: recipe.steps.clone(),
        }
    }
}

#[derive(Serialize)]
struct JsonCollection {
    recipes: Vec<JsonRecipe>,
}

// Serialize one recipe as a pretty-printed bare JSON object.
pub(crate) fn export_single(recipe: &Recipe) -> Result<String, String> {
    serde_json::to_string_pretty(&JsonRecipe::from(recipe))
        .map_err(|err| format!("Could not serialize recipe JSON: {}", err))
}

// Serialize a slice of recipes as a pretty-printed
// {"recipes": [...]} collection object.
pub(crate) fn export_collection(recipes: &[Recipe]) -> Result<String, String> {
    let collection = JsonCollection {
        recipes: recipes.iter().map(JsonRecipe::from).collect(),
    };
    serde_json::to_string_pretty(&collection)
        .map_err(|err| format!("Could not serialize recipe JSON: {}", err))
}

// Write already-serialized JSON text to the given path, creating
// or overwriting it. The caller (main.rs) has already asked the
// user where the file goes via the OS save dialog, so this does
// not pick a path itself.
pub(crate) fn write_export(path: &std::path::Path, text: &str) -> Result<(), String> {
    std::fs::write(path, text)
        .map_err(|err| format!("Could not write file {}: {}", path.display(), err))
}

// A file name derived from a recipe title, safe to offer as the
// save dialog's default: characters that are not letters, digits,
// spaces, hyphens, or underscores become underscores, so a title
// like "Fish & Chips" does not become a strange file name, and a
// title containing "/" cannot escape the chosen directory.
pub(crate) fn default_file_name(title: &str) -> String {
    let sanitized: String = title
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || ch == ' ' || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = sanitized.trim();
    if trimmed.is_empty() {
        "recipe.json".to_string()
    } else {
        format!("{}.json", trimmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{json_import, Ingredient};

    fn sample_recipe() -> Recipe {
        Recipe {
            id: 1,
            title: "Mushroom Risotto".to_string(),
            description: "Creamy rice.".to_string(),
            servings: 4,
            image_path: None,
            ingredients: vec![Ingredient {
                amount: "1".to_string(),
                unit: "lb".to_string(),
                name: "mushrooms".to_string(),
            }],
            steps: vec!["Cook it.".to_string()],
            notes: "Stir often.".to_string(),
        }
    }

    #[test]
    fn export_single_is_a_bare_object_that_reimports() {
        let text = export_single(&sample_recipe()).unwrap();
        // Bare object, not wrapped in a "recipes" collection.
        assert!(text.trim_start().starts_with('{'));
        assert!(!text.contains("\"recipes\""));
        let recipes = json_import::parse_recipes(&text).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        assert_eq!(recipes[0].servings, 4);
        assert_eq!(recipes[0].image_path, None);
        assert_eq!(recipes[0].ingredients.len(), 1);
        assert_eq!(recipes[0].ingredients[0].name, "mushrooms");
        assert_eq!(recipes[0].steps, vec!["Cook it."]);
    }

    #[test]
    fn export_collection_is_a_recipes_object_that_reimports() {
        let recipes = vec![sample_recipe(), sample_recipe()];
        let text = export_collection(&recipes).unwrap();
        assert!(text.contains("\"recipes\""));
        let parsed = json_import::parse_recipes(&text).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].title, "Mushroom Risotto");
        assert_eq!(parsed[1].title, "Mushroom Risotto");
    }

    #[test]
    fn export_collection_empty_is_an_empty_recipes_array() {
        let text = export_collection(&[]).unwrap();
        let parsed = json_import::parse_recipes(&text).unwrap();
        assert!(parsed.is_empty());
    }

    #[test]
    fn export_preserves_image_path_when_present() {
        let mut recipe = sample_recipe();
        recipe.image_path = Some("images/risotto.png".to_string());
        let text = export_single(&recipe).unwrap();
        assert!(text.contains("images/risotto.png"));
        let parsed = json_import::parse_recipes(&text).unwrap();
        assert_eq!(
            parsed[0].image_path.as_deref(),
            Some("images/risotto.png")
        );
    }

    #[test]
    fn default_file_name_sanitizes_and_falls_back() {
        assert_eq!(default_file_name("Banana Bread"), "Banana Bread.json");
        assert_eq!(
            default_file_name("Fish & Chips / Fries"),
            "Fish _ Chips _ Fries.json"
        );
        assert_eq!(default_file_name("   "), "recipe.json");
        assert_eq!(default_file_name(""), "recipe.json");
    }

    #[test]
    fn write_export_writes_and_overwrites() {
        let path = std::env::temp_dir().join(format!(
            "rust-egui-export-test-{}.json",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        write_export(&path, "{\"title\": \"Toast\"}").unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\"title\": \"Toast\"}"
        );
        write_export(&path, "replaced").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "replaced");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn write_export_to_a_missing_directory_is_an_error() {
        let path = std::env::temp_dir()
            .join("rust-egui-export-test-no-such-dir")
            .join("out.json");
        let Err(err) = write_export(&path, "x") else {
            panic!("expected a write error");
        };
        assert!(err.contains("Could not write file"), "error was: {}", err);
    }
}
