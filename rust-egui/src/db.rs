// SQLite access for the recipe manager.
// Each function opens its own connection, so the app never holds
// a connection open across UI frames. Single-user app, so this
// keeps borrowing simple and is fast enough for this data size.
// The database file, recipes.db, is created in the current working
// directory on first run.
use crate::{seed, Ingredient, Recipe};
use rusqlite::{params, Connection};

// Test-only lock serialising the tests that switch the process working
// directory (this module's DB tests and the images test): the working
// directory is process-global, so two such tests running in parallel
// would otherwise operate on each other's throwaway directory. It has
// no effect on the app itself.
#[cfg(test)]
pub(crate) static CWD_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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

    // Restores the working directory and removes the throwaway DB
    // directory on drop, so a failed assertion does not strand the
    // process in the temp directory for the remaining tests.
    struct RestoreCwd {
        original: PathBuf,
        tmp: PathBuf,
    }

    impl Drop for RestoreCwd {
        fn drop(&mut self) {
            let _ = env::set_current_dir(&self.original);
            let _ = std::fs::remove_dir_all(&self.tmp);
        }
    }

    #[test]
    fn insert_update_delete_round_trip() {
        // Hold the cwd lock for the whole test (declared first, so
        // it is released after the RestoreCwd guard below).
        let _cwd_lock = CWD_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = env::temp_dir().join(format!("recipe-test-{}", std::process::id()));
        // A previous crashed run may have left this directory behind
        // with a populated recipes.db; start clean so seeding is tested.
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let original = env::current_dir().unwrap();
        env::set_current_dir(&tmp).unwrap();
        let _restore = RestoreCwd {
            original,
            tmp: tmp.clone(),
        };

        // Seed loads 3 recipes, in order, with ingredients and steps
        // preserved and in order.
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        let titles: Vec<&str> = recipes.iter().map(|r| r.title.as_str()).collect();
        assert_eq!(
            titles,
            ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"]
        );
        assert_eq!(
            recipes
                .iter()
                .map(|r| (r.servings, r.ingredients.len(), r.steps.len()))
                .collect::<Vec<_>>(),
            [(8, 7, 5), (4, 6, 4), (4, 6, 4)]
        );
        let banana = &recipes[0];
        let banana_ingredients: Vec<&str> = banana
            .ingredients
            .iter()
            .map(|i| i.name.as_str())
            .collect();
        assert_eq!(
            banana_ingredients,
            [
                "ripe bananas, mashed",
                "butter, melted",
                "sugar",
                "egg",
                "vanilla",
                "baking soda",
                "flour",
            ]
        );
        assert_eq!(banana.ingredients[0].amount, "3");
        assert_eq!(banana.ingredients[0].unit, "");
        assert_eq!(banana.ingredients[1].amount, "1/2");
        assert_eq!(banana.ingredients[1].unit, "cup");
        assert_eq!(
            banana.steps[0],
            "Preheat the oven to 350°F and grease a 9x5 loaf pan."
        );
        assert_eq!(
            banana.steps[4],
            "Cool in the pan for 10 minutes, then turn out onto a rack."
        );
        assert_eq!(recipes[1].ingredients[0].name, "pasta");
        assert_eq!(
            recipes[1].steps[0],
            "Cook the pasta in salted water until al dente, reserving a cup of pasta water."
        );
        assert_eq!(recipes[2].ingredients[0].name, "chicken breast, sliced");
        assert_eq!(
            recipes[2].steps[3],
            "Cook for 2 more minutes, stirring, until the sauce coats everything."
        );

        // Seeding twice does not duplicate recipes.
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        assert_eq!(
            recipes.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
            ["Banana Bread", "Tomato Basil Pasta", "Chicken Stir Fry"]
        );

        // Insert round-trip, with children preserved.
        let mut new = Recipe {
            id: 0,
            title: "Test Soup".to_string(),
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
        };
        let id = insert_recipe(&new).unwrap();
        new.id = id;
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 4);
        let inserted = recipes.iter().find(|r| r.id == id).unwrap();
        assert_eq!(inserted.title, "Test Soup");
        assert_eq!(inserted.ingredients.len(), 1);
        assert_eq!(inserted.ingredients[0].name, "water");
        assert_eq!(inserted.steps, vec!["Boil."]);

        // Update replaces the title AND the ingredients/steps:
        // the old children must be gone, not appended to.
        new.title = "Test Soup Edited".to_string();
        new.description = "Edited".to_string();
        new.servings = 3;
        new.ingredients = vec![
            Ingredient {
                amount: "2".to_string(),
                unit: "cups".to_string(),
                name: "stock".to_string(),
            },
            Ingredient {
                amount: "1".to_string(),
                unit: "".to_string(),
                name: "onion".to_string(),
            },
        ];
        new.steps = vec!["Simmer.".to_string(), "Serve.".to_string()];
        update_recipe(&new).unwrap();
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 4);
        let updated = recipes.iter().find(|r| r.id == id).unwrap();
        assert_eq!(updated.title, "Test Soup Edited");
        assert_eq!(updated.description, "Edited");
        assert_eq!(updated.servings, 3);
        assert_eq!(
            updated
                .ingredients
                .iter()
                .map(|i| i.name.as_str())
                .collect::<Vec<_>>(),
            ["stock", "onion"]
        );
        assert_eq!(updated.steps, vec!["Simmer.", "Serve."]);

        // Delete removes the recipe and its children: no orphan
        // ingredient or step rows for the deleted id, and the seed
        // children's totals are unchanged (7+6+6 ingredients,
        // 5+4+4 steps).
        delete_recipe(id).unwrap();
        let recipes = load_recipes().unwrap();
        assert_eq!(recipes.len(), 3);
        assert!(!recipes.iter().any(|r| r.title == "Test Soup Edited"));
        let conn = Connection::open("recipes.db").unwrap();
        let orphan_ingredients: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM ingredients WHERE recipe_id = ?1",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        let orphan_steps: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM steps WHERE recipe_id = ?1",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(orphan_ingredients, 0);
        assert_eq!(orphan_steps, 0);
        let total_ingredients: i64 = conn
            .query_row("SELECT COUNT(*) FROM ingredients", [], |row| row.get(0))
            .unwrap();
        let total_steps: i64 = conn
            .query_row("SELECT COUNT(*) FROM steps", [], |row| row.get(0))
            .unwrap();
        assert_eq!(total_ingredients, 19);
        assert_eq!(total_steps, 13);
    }
}
