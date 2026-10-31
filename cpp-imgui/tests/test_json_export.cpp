// Unit tests for JSON export (cpp-imgui).
//
// Mirrors rust-egui's json_export tests, adapted to this stack's
// plain-assert test harness (see tests/test_json_import.cpp):
// a single recipe re-imports through this stack's own import
// parser, a collection re-imports, the empty collection, an
// image_path is preserved, file-name sanitization, writing and
// overwriting, and writing to a missing directory is an error.
// Plus the serializer-specific cases rust-egui gets for free
// from serde: field order, pretty-printing, and escaping of
// quotes, backslashes, and control characters round-tripping
// through the parser.
//
// Plain asserts only; no test framework. Links json_export.cpp
// and json_import.cpp only: no SQLite, SDL, or Dear ImGui.

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "json_export.h"
#include "json_import.h"

namespace {

Recipe sample_recipe() {
    Recipe recipe;
    recipe.id = 1;
    recipe.title = "Mushroom Risotto";
    recipe.description = "Creamy rice.";
    recipe.servings = 4;
    recipe.image_path = "";
    recipe.notes = "Stir often.";
    recipe.ingredients.push_back(Ingredient{"1", "lb", "mushrooms"});
    recipe.steps.push_back("Cook it.");
    return recipe;
}

bool parse_ok(const std::string& text, std::vector<Recipe>& recipes) {
    std::string error;
    bool ok = parse_recipes(text, recipes, error);
    if (!ok) {
        std::fprintf(stderr, "unexpected parse error: %s\n", error.c_str());
    }
    return ok;
}

std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)),
                       std::istreambuf_iterator<char>());
}

std::string temp_path(const std::string& name) {
    return (std::filesystem::temp_directory_path() /
            ("cpp-imgui-export-test-" + std::to_string(getpid()) + "-" + name +
             ".json"))
        .string();
}

}  // namespace

int main() {
    int checks = 0;
    std::vector<Recipe> recipes;
    std::string error;

    // Single recipe: a bare object (not a "recipes" collection)
    // that re-imports with every field intact.
    {
        std::string text = export_single(sample_recipe());
        assert(!text.empty());
        ++checks;
        assert(text[0] == '{');
        ++checks;
        assert(text.find("\"recipes\"") == std::string::npos);
        ++checks;
        assert(parse_ok(text, recipes));
        ++checks;
        assert(recipes.size() == 1);
        ++checks;
        assert(recipes[0].title == "Mushroom Risotto");
        ++checks;
        assert(recipes[0].description == "Creamy rice.");
        ++checks;
        assert(recipes[0].servings == 4);
        ++checks;
        assert(recipes[0].image_path.empty());
        ++checks;
        assert(recipes[0].notes == "Stir often.");
        ++checks;
        assert(recipes[0].ingredients.size() == 1);
        ++checks;
        assert(recipes[0].ingredients[0].amount == "1");
        ++checks;
        assert(recipes[0].ingredients[0].unit == "lb");
        ++checks;
        assert(recipes[0].ingredients[0].name == "mushrooms");
        ++checks;
        assert(recipes[0].steps.size() == 1 && recipes[0].steps[0] == "Cook it.");
        ++checks;
    }

    // Collection: a {"recipes": [...]} object that re-imports.
    {
        std::vector<Recipe> two = {sample_recipe(), sample_recipe()};
        std::string text = export_collection(two);
        assert(text.find("\"recipes\"") != std::string::npos);
        ++checks;
        assert(parse_ok(text, recipes));
        ++checks;
        assert(recipes.size() == 2);
        ++checks;
        assert(recipes[0].title == "Mushroom Risotto");
        ++checks;
        assert(recipes[1].title == "Mushroom Risotto");
        ++checks;
    }

    // Empty collection re-imports as zero recipes.
    {
        std::string text = export_collection({});
        assert(parse_ok(text, recipes));
        ++checks;
        assert(recipes.empty());
        ++checks;
    }

    // An image_path is preserved, not dropped or nulled.
    {
        Recipe recipe = sample_recipe();
        recipe.image_path = "images/risotto.png";
        std::string text = export_single(recipe);
        assert(text.find("images/risotto.png") != std::string::npos);
        ++checks;
        assert(parse_ok(text, recipes));
        ++checks;
        assert(recipes.size() == 1);
        ++checks;
        assert(recipes[0].image_path == "images/risotto.png");
        ++checks;
    }

    // Field order, as in the import format: title, description,
    // servings, image_path, notes, ingredients, steps.
    {
        std::string text = export_single(sample_recipe());
        size_t title = text.find("\"title\"");
        size_t description = text.find("\"description\"");
        size_t servings = text.find("\"servings\"");
        size_t image_path = text.find("\"image_path\"");
        size_t notes = text.find("\"notes\"");
        size_t ingredients = text.find("\"ingredients\"");
        size_t steps = text.find("\"steps\"");
        assert(title < description && description < servings &&
               servings < image_path && image_path < notes &&
               notes < ingredients && ingredients < steps);
        ++checks;
        // Pretty-printed: two-space indent, as serde_json does.
        assert(text.find("\n  \"title\"") != std::string::npos);
        ++checks;
        // An absent image_path serializes as null, not "".
        assert(text.find("\"image_path\": null") != std::string::npos);
        ++checks;
    }

    // Escaping round-trips: quotes, backslashes, newlines,
    // tabs, and a control character survive export and parse.
    {
        Recipe recipe = sample_recipe();
        recipe.title = "Say \"hi\" \\ ok";
        recipe.description = "Line one\nLine two\ttabbed";
        recipe.notes = std::string("ctrl") + static_cast<char>(0x01) + "char";
        recipe.ingredients[0].name = "a/b";
        std::string text = export_single(recipe);
        assert(text.find("\\\"hi\\\"") != std::string::npos);
        ++checks;
        assert(text.find("\\\\") != std::string::npos);
        ++checks;
        assert(text.find("\\n") != std::string::npos);
        ++checks;
        assert(text.find("\\t") != std::string::npos);
        ++checks;
        assert(text.find("\\u0001") != std::string::npos);
        ++checks;
        assert(parse_ok(text, recipes));
        ++checks;
        assert(recipes.size() == 1);
        ++checks;
        assert(recipes[0].title == recipe.title);
        ++checks;
        assert(recipes[0].description == recipe.description);
        ++checks;
        assert(recipes[0].notes == recipe.notes);
        ++checks;
    }

    // Default file names, as in rust-egui.
    assert(default_file_name("Banana Bread") == "Banana Bread.json");
    ++checks;
    assert(default_file_name("Fish & Chips / Fries") == "Fish _ Chips _ Fries.json");
    ++checks;
    assert(default_file_name("   ") == "recipe.json");
    ++checks;
    assert(default_file_name("") == "recipe.json");
    ++checks;

    // Writing creates the file, and overwrites it on a second write.
    {
        std::string path = temp_path("write");
        std::filesystem::remove(path);
        assert(write_export(path, "{\"title\": \"Toast\"}", error));
        ++checks;
        assert(read_file(path) == "{\"title\": \"Toast\"}");
        ++checks;
        assert(write_export(path, "replaced", error));
        ++checks;
        assert(read_file(path) == "replaced");
        ++checks;
        std::filesystem::remove(path);
    }

    // Writing to a missing directory is an error, not a crash.
    {
        std::string path =
            (std::filesystem::temp_directory_path() /
             ("cpp-imgui-export-test-" + std::to_string(getpid()) +
              "-no-such-dir") /
             "out.json")
                .string();
        assert(!write_export(path, "x", error));
        ++checks;
        assert(error.find("Could not write file") != std::string::npos);
        ++checks;
    }

    std::printf("test_json_export: all %d checks passed\n", checks);
    return 0;
}
