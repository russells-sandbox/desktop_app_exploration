// SQLite access for the recipe manager.
// Each function opens its own connection, so the app never holds
// a connection open across UI frames. Single-user app, so this
// keeps borrowing simple and is fast enough for this data size.
// The database file, recipes.db, is created in the current working
// directory on first run.
use crate::{seed, Ingredient, Recipe};
use rusqlite::{params, Connection};

fn ensure_schema(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "PRAGMA foreign_keys = ON;
         CREATE TABLE IF NOT EXISTS recipes (
             id INTEGER PRIMARY KEY,
             title TEXT NOT NULL,
             description TEXT NOT NULL,
             servings INTEGER NOT NULL,
             image_path TEXT,
             notes TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS ingredients (
             id INTEGER PRIMARY KEY,
             recipe_id INTEGER NOT NULL REFERENCES recipes(id),
             position INTEGER NOT NULL,
             amount TEXT NOT NULL,
             unit TEXT NOT NULL,
             name TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS steps (
             id INTEGER PRIMARY KEY,
             recipe_id INTEGER NOT NULL REFERENCES recipes(id),
             position INTEGER NOT NULL,
             text TEXT NOT NULL
         );",
    )
}

fn insert_children(
    tx: &rusqlite::Transaction,
    recipe_id: i64,
    recipe: &Recipe,
) -> rusqlite::Result<()> {
    for (position, ingredient) in recipe.ingredients.iter().enumerate() {
        tx.execute(
            "INSERT INTO ingredients (recipe_id, position, amount, unit, name)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                recipe_id,
                position as i64,
                ingredient.amount,
                ingredient.unit,
                ingredient.name
            ],
        )?;
    }
    for (position, step) in recipe.steps.iter().enumerate() {
        tx.execute(
            "INSERT INTO steps (recipe_id, position, text) VALUES (?1, ?2, ?3)",
            params![recipe_id, position as i64, step],
        )?;
    }
    Ok(())
}

pub(crate) fn load_recipes() -> rusqlite::Result<Vec<Recipe>> {
    let mut conn = Connection::open("recipes.db")?;
    ensure_schema(&conn)?;

    let count: i64 = conn.query_row("SELECT COUNT(*) FROM recipes", [], |row| row.get(0))?;
    if count == 0 {
        let tx = conn.transaction()?;
        for recipe in seed::seed_recipes() {
            tx.execute(
                "INSERT INTO recipes (title, description, servings, image_path, notes)
                 VALUES (?1, ?2, ?3, NULL, ?4)",
                params![
                    recipe.title,
                    recipe.description,
                    recipe.servings,
                    recipe.notes
                ],
            )?;
            let recipe_id = tx.last_insert_rowid();
            insert_children(&tx, recipe_id, &recipe)?;
        }
        tx.commit()?;
    }

    // Collect recipe metadata first, so the statement is dropped
    // before querying ingredients and steps for each recipe.
    let mut meta: Vec<(i64, String, String, i64, Option<String>, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT id, title, description, servings, image_path, notes
             FROM recipes ORDER BY id",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, String>(5)?,
            ))
        })?;
        for row in rows {
            meta.push(row?);
        }
    }

    let mut recipes = Vec::new();
    for (id, title, description, servings, image_path, notes) in meta {
        let mut ingredients = Vec::new();
        {
            let mut stmt = conn.prepare(
                "SELECT amount, unit, name FROM ingredients
                 WHERE recipe_id = ?1 ORDER BY position",
            )?;
            let rows = stmt.query_map(params![id], |row| {
                Ok(Ingredient {
                    amount: row.get(0)?,
                    unit: row.get(1)?,
                    name: row.get(2)?,
                })
            })?;
            for row in rows {
                ingredients.push(row?);
            }
        }
        let mut steps = Vec::new();
        {
            let mut stmt = conn.prepare(
                "SELECT text FROM steps WHERE recipe_id = ?1 ORDER BY position",
            )?;
            let rows = stmt.query_map(params![id], |row| row.get::<_, String>(0))?;
            for row in rows {
                steps.push(row?);
            }
        }
        recipes.push(Recipe {
            id,
            title,
            description,
            servings,
            image_path,
            ingredients,
            steps,
            notes,
        });
    }
    Ok(recipes)
}

pub(crate) fn insert_recipe(recipe: &Recipe) -> rusqlite::Result<i64> {
    let mut conn = Connection::open("recipes.db")?;
    ensure_schema(&conn)?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO recipes (title, description, servings, image_path, notes)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            recipe.title,
            recipe.description,
            recipe.servings,
            recipe.image_path,
            recipe.notes
        ],
    )?;
    let recipe_id = tx.last_insert_rowid();
    insert_children(&tx, recipe_id, recipe)?;
    tx.commit()?;
    Ok(recipe_id)
}

pub(crate) fn update_recipe(recipe: &Recipe) -> rusqlite::Result<()> {
    let mut conn = Connection::open("recipes.db")?;
    ensure_schema(&conn)?;
    let tx = conn.transaction()?;
    tx.execute(
        "UPDATE recipes SET title = ?1, description = ?2, servings = ?3,
         image_path = ?4, notes = ?5
         WHERE id = ?6",
        params![
            recipe.title,
            recipe.description,
            recipe.servings,
            recipe.image_path,
            recipe.notes,
            recipe.id
        ],
    )?;
    tx.execute("DELETE FROM ingredients WHERE recipe_id = ?1", params![recipe.id])?;
    tx.execute("DELETE FROM steps WHERE recipe_id = ?1", params![recipe.id])?;
    insert_children(&tx, recipe.id, recipe)?;
    tx.commit()?;
    Ok(())
}

pub(crate) fn delete_recipe(id: i64) -> rusqlite::Result<()> {
    let mut conn = Connection::open("recipes.db")?;
    ensure_schema(&conn)?;
    let tx = conn.transaction()?;
    // Explicit child deletes, not ON DELETE CASCADE: databases created
    // before this feature do not have cascade on these foreign keys,
    // so relying on it would leave orphan rows there.
    tx.execute("DELETE FROM ingredients WHERE recipe_id = ?1", params![id])?;
    tx.execute("DELETE FROM steps WHERE recipe_id = ?1", params![id])?;
    tx.execute("DELETE FROM recipes WHERE id = ?1", params![id])?;
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard};

    // The DB functions open "recipes.db" in the current directory,
    // so tests run in a throwaway directory, never the real one.
    // The lock serializes these tests: the working directory is
    // process-wide, so two of them running at once would share it.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    // Switches into a fresh temp directory on creation and restores
    // the original directory (and removes the temp directory) on
    // drop, so a failing assertion cannot leave the process in a
    // temp directory or leak the directory behind.
    struct TempDirGuard {
        original: PathBuf,
        dir: PathBuf,
        _lock: MutexGuard<'static, ()>,
    }

    impl TempDirGuard {
        fn new(name: &str) -> Self {
            let lock = TEST_LOCK.lock().unwrap();
            let dir = env::temp_dir()
                .join(format!("recipe-test-{}-{}", std::process::id(), name));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let original = env::current_dir().unwrap();
            env::set_current_dir(&dir).unwrap();
            TempDirGuard {
                original,
                dir,
                _lock: lock,
            }
        }
    }

    impl Drop for TempDirGuard {
        fn drop(&mut self) {
            let _ = env::set_current_dir(&self.original);
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn test_recipe(title: &str) -> Recipe {
        Recipe {
            id: 0,
            title: title.to_string(),
            description: "Test".to_string(),
            servings: 2,
            image_path: None,
            ingredients: vec![Ingredient {
                amount: "1".to_string(),
                unit: "cup".to_string(),
                name: "water".to_string(),
            }],
            steps: vec!["Boil.".to_string()],
            notes: String::new(),
        }
    }

    #[test]
    fn insert_update_delete_round_trip() {
        let _guard = TempDirGuard::new("round-trip");

        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);

        let mut new = test_recipe("Test Soup");
        let id = insert_recipe(&new).unwrap();
        new.id = id;
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 4);
        assert!(recipes.iter().any(|r| r.title == "Test Soup"));

        new.title = "Test Soup Edited".to_string();
        update_recipe(&new).unwrap();
        let recipes = load_recipes().unwrap();
        assert!(recipes.iter().any(|r| r.title == "Test Soup Edited"));

        delete_recipe(id).unwrap();
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        assert!(!recipes.iter().any(|r| r.title == "Test Soup Edited"));
    }

    #[test]
    fn seed_loads_three_recipes_with_children_in_order() {
        let _guard = TempDirGuard::new("seed");

        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        let titles: Vec<&str> = recipes.iter().map(|r| r.title.as_str()).collect();
        assert_eq!(
            titles,
            ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"]
        );

        // Ingredient and step counts, matching src/seed.rs (19/13 total).
        let counts: Vec<(usize, usize)> = recipes
            .iter()
            .map(|r| (r.ingredients.len(), r.steps.len()))
            .collect();
        assert_eq!(counts, [(7, 5), (6, 4), (6, 4)]);

        // Order is preserved, not just the set: first and last
        // child of the first and last recipe, in stored order.
        let banana = &recipes[0];
        assert_eq!(banana.servings, 8);
        assert_eq!(banana.image_path, None);
        assert_eq!(banana.ingredients[0].name, "ripe bananas, mashed");
        assert_eq!(banana.ingredients[6].name, "flour");
        assert_eq!(
            banana.steps[0],
            "Preheat the oven to 350°F and grease a 9x5 loaf pan."
        );
        assert_eq!(
            banana.steps[4],
            "Cool in the pan for 10 minutes, then turn out onto a rack."
        );
        let chicken = &recipes[2];
        assert_eq!(chicken.ingredients[0].name, "chicken breast, sliced");
        assert_eq!(chicken.ingredients[5].name, "garlic, minced");
        assert_eq!(
            chicken.steps[3],
            "Cook for 2 more minutes, stirring, until the sauce coats everything."
        );
    }

    #[test]
    fn seeding_twice_does_not_duplicate() {
        let _guard = TempDirGuard::new("seed-twice");

        let first = load_recipes().unwrap();
        assert_eq!(first.len(), 3);
        let second = load_recipes().unwrap();
        assert_eq!(second.len(), 3);
        let titles: Vec<&str> = second.iter().map(|r| r.title.as_str()).collect();
        assert_eq!(
            titles,
            ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"]
        );
    }

    #[test]
    fn update_replaces_ingredients_and_steps() {
        let _guard = TempDirGuard::new("update-children");

        load_recipes().unwrap();
        let mut recipe = test_recipe("Test Soup");
        let id = insert_recipe(&recipe).unwrap();
        recipe.id = id;

        // Replace the single ingredient/step with different ones.
        recipe.ingredients = vec![
            Ingredient {
                amount: "2".to_string(),
                unit: "tbsp".to_string(),
                name: "oil".to_string(),
            },
            Ingredient {
                amount: "3".to_string(),
                unit: "".to_string(),
                name: "carrots".to_string(),
            },
        ];
        recipe.steps = vec!["Heat the oil.".to_string(), "Add carrots.".to_string()];
        update_recipe(&recipe).unwrap();

        let recipes = load_recipes().unwrap();
        let saved = recipes.iter().find(|r| r.id == id).unwrap();
        // The old children are gone, not appended to.
        assert_eq!(saved.ingredients.len(), 2);
        assert_eq!(saved.ingredients[0].name, "oil");
        assert_eq!(saved.ingredients[0].unit, "tbsp");
        assert_eq!(saved.ingredients[1].name, "carrots");
        assert_eq!(saved.steps, ["Heat the oil.", "Add carrots."]);
    }

    #[test]
    fn delete_removes_children_too() {
        let _guard = TempDirGuard::new("delete-children");

        load_recipes().unwrap();
        let id = insert_recipe(&test_recipe("Test Soup")).unwrap();
        delete_recipe(id).unwrap();

        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        assert!(!recipes.iter().any(|r| r.id == id));

        // No orphan rows left behind in the child tables.
        let conn = Connection::open("recipes.db").unwrap();
        let ingredients: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM ingredients WHERE recipe_id = ?1",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        let steps: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM steps WHERE recipe_id = ?1",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(ingredients, 0);
        assert_eq!(steps, 0);
    }
}
