#include "json_export.h"

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace {

// Two-space indentation at the given nesting level, as in
// serde_json::to_string_pretty.
std::string indent(int level) {
    return std::string(static_cast<size_t>(level) * 2, ' ');
}

// A string as a JSON string literal, with the escapes the
// import parser understands: " and \, the named control
// escapes, other control characters as \u00XX, and every other
// byte (including UTF-8 continuation bytes) passed through.
std::string quoted(const std::string& text) {
    std::string out = "\"";
    for (char raw : text) {
        unsigned char c = static_cast<unsigned char>(raw);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    out += buffer;
                } else {
                    out.push_back(raw);
                }
                break;
        }
    }
    out += "\"";
    return out;
}

std::string trimmed(const std::string& text) {
    size_t first = 0;
    while (first < text.size() &&
           std::isspace(static_cast<unsigned char>(text[first]))) {
        ++first;
    }
    size_t last = text.size();
    while (last > first &&
           std::isspace(static_cast<unsigned char>(text[last - 1]))) {
        --last;
    }
    return text.substr(first, last - first);
}

// Appends one recipe object, with its opening brace at the
// given indentation level. Fields are in import order: title,
// description, servings, image_path, notes, ingredients, steps.
void append_recipe(std::string& out, const Recipe& recipe, int level) {
    std::string pad = indent(level);
    std::string inner = indent(level + 1);
    out += "{\n";
    out += inner + "\"title\": " + quoted(recipe.title) + ",\n";
    out += inner + "\"description\": " + quoted(recipe.description) + ",\n";
    out += inner + "\"servings\": " + std::to_string(recipe.servings) + ",\n";
    // This stack stores image_path as a plain string, not an
    // Option: empty means absent, and absent serializes as
    // null, as in rust-egui and test-data/recipes.json.
    out += inner + "\"image_path\": " +
           (recipe.image_path.empty() ? std::string("null")
                                      : quoted(recipe.image_path)) +
           ",\n";
    out += inner + "\"notes\": " + quoted(recipe.notes) + ",\n";
    if (recipe.ingredients.empty()) {
        out += inner + "\"ingredients\": [],\n";
    } else {
        out += inner + "\"ingredients\": [\n";
        for (size_t i = 0; i < recipe.ingredients.size(); ++i) {
            const Ingredient& ingredient = recipe.ingredients[i];
            std::string item_pad = indent(level + 2);
            std::string field_pad = indent(level + 3);
            out += item_pad + "{\n";
            out += field_pad + "\"amount\": " + quoted(ingredient.amount) + ",\n";
            out += field_pad + "\"unit\": " + quoted(ingredient.unit) + ",\n";
            out += field_pad + "\"name\": " + quoted(ingredient.name) + "\n";
            out += item_pad + "}";
            if (i + 1 < recipe.ingredients.size()) {
                out += ",";
            }
            out += "\n";
        }
        out += inner + "],\n";
    }
    if (recipe.steps.empty()) {
        out += inner + "\"steps\": []\n";
    } else {
        out += inner + "\"steps\": [\n";
        for (size_t i = 0; i < recipe.steps.size(); ++i) {
            out += indent(level + 2) + quoted(recipe.steps[i]);
            if (i + 1 < recipe.steps.size()) {
                out += ",";
            }
            out += "\n";
        }
        out += inner + "]\n";
    }
    out += pad + "}";
}

}  // namespace

std::string export_single(const Recipe& recipe) {
    std::string out;
    append_recipe(out, recipe, 0);
    return out;
}

std::string export_collection(const std::vector<Recipe>& recipes) {
    std::string out = "{\n";
    if (recipes.empty()) {
        out += indent(1) + "\"recipes\": []\n";
    } else {
        out += indent(1) + "\"recipes\": [\n";
        for (size_t i = 0; i < recipes.size(); ++i) {
            out += indent(2);
            append_recipe(out, recipes[i], 2);
            if (i + 1 < recipes.size()) {
                out += ",";
            }
            out += "\n";
        }
        out += indent(1) + "]\n";
    }
    out += "}";
    return out;
}

bool write_export(const std::string& path, const std::string& text,
                  std::string& error) {
    error.clear();
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
        int reason = errno;
        error = "Could not write file " + path + ": " +
                (reason != 0 ? std::strerror(reason) : "could not open file") +
                ".";
        return false;
    }
    file << text;
    file.flush();
    if (!file) {
        int reason = errno;
        error = "Could not write file " + path + ": " +
                (reason != 0 ? std::strerror(reason) : "write failed") + ".";
        return false;
    }
    return true;
}

std::string default_file_name(const std::string& title) {
    std::string sanitized;
    for (char raw : title) {
        unsigned char c = static_cast<unsigned char>(raw);
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '_') {
            sanitized.push_back(raw);
        } else {
            sanitized.push_back('_');
        }
    }
    std::string name = trimmed(sanitized);
    if (name.empty()) {
        return "recipe.json";
    }
    return name + ".json";
}
