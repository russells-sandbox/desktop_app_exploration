#include "json_export.h"

#include <cerrno>
#include <cctype>
#include <cstring>
#include <fstream>

namespace {

std::string escaped(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 2);
    out += '"';
    static const char* kHex = "0123456789abcdef";
    for (char ch : text) {
        unsigned char c = static_cast<unsigned char>(ch);
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
                    out += "\\u00";
                    out += kHex[(c >> 4) & 0xF];
                    out += kHex[c & 0xF];
                } else {
                    out += ch;
                }
                break;
        }
    }
    out += '"';
    return out;
}

void indent(std::string& out, int level) {
    for (int i = 0; i < level; ++i) {
        out += "  ";
    }
}

// One recipe object, pretty-printed at the given indent level
// (0 for a top-level single recipe, 2 for a recipe inside a
// collection's array, matching serde_json's pretty output in
// rust-egui). Empty ingredient/step arrays print as [] on one
// line, as serde does.
void append_recipe(std::string& out, const ImportedRecipe& recipe,
                   int level) {
    indent(out, level);
    out += "{\n";
    indent(out, level + 1);
    out += "\"title\": " + escaped(recipe.title) + ",\n";
    indent(out, level + 1);
    out += "\"description\": " + escaped(recipe.description) + ",\n";
    indent(out, level + 1);
    out += "\"servings\": " + std::to_string(recipe.servings) + ",\n";
    indent(out, level + 1);
    if (recipe.image_path.empty()) {
        out += "\"image_path\": null,\n";
    } else {
        out += "\"image_path\": " + escaped(recipe.image_path) + ",\n";
    }
    indent(out, level + 1);
    out += "\"notes\": " + escaped(recipe.notes) + ",\n";
    indent(out, level + 1);
    if (recipe.ingredients.empty()) {
        out += "\"ingredients\": [],\n";
    } else {
        out += "\"ingredients\": [\n";
        for (size_t i = 0; i < recipe.ingredients.size(); ++i) {
            const ImportedIngredient& ingredient = recipe.ingredients[i];
            indent(out, level + 2);
            out += "{\n";
            indent(out, level + 3);
            out += "\"amount\": " + escaped(ingredient.amount) + ",\n";
            indent(out, level + 3);
            out += "\"unit\": " + escaped(ingredient.unit) + ",\n";
            indent(out, level + 3);
            out += "\"name\": " + escaped(ingredient.name) + "\n";
            indent(out, level + 2);
            out += "}";
            out += (i + 1 < recipe.ingredients.size()) ? ",\n" : "\n";
        }
        indent(out, level + 1);
        out += "],\n";
    }
    indent(out, level + 1);
    if (recipe.steps.empty()) {
        out += "\"steps\": []\n";
    } else {
        out += "\"steps\": [\n";
        for (size_t i = 0; i < recipe.steps.size(); ++i) {
            indent(out, level + 2);
            out += escaped(recipe.steps[i]);
            out += (i + 1 < recipe.steps.size()) ? ",\n" : "\n";
        }
        indent(out, level + 1);
        out += "]\n";
    }
    indent(out, level);
    out += "}";
}

}  // namespace

std::string export_single(const ImportedRecipe& recipe) {
    std::string out;
    append_recipe(out, recipe, 0);
    return out;
}

std::string export_collection(const std::vector<ImportedRecipe>& recipes) {
    std::string out = "{\n";
    if (recipes.empty()) {
        out += "  \"recipes\": []\n";
    } else {
        out += "  \"recipes\": [\n";
        for (size_t i = 0; i < recipes.size(); ++i) {
            append_recipe(out, recipes[i], 2);
            out += (i + 1 < recipes.size()) ? ",\n" : "\n";
        }
        out += "  ]\n";
    }
    out += "}";
    return out;
}

bool write_export(const std::string& path, const std::string& text,
                  std::string& error) {
    errno = 0;
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
        error = "Could not write file " + path + ": " +
                std::strerror(errno);
        return false;
    }
    file << text;
    file.flush();
    if (!file) {
        error = "Could not write file " + path + ": " +
                std::strerror(errno);
        return false;
    }
    return true;
}

std::string default_file_name(const std::string& title) {
    std::string sanitized;
    sanitized.reserve(title.size());
    size_t i = 0;
    while (i < title.size()) {
        unsigned char c = static_cast<unsigned char>(title[i]);
        if (c < 0x80) {
            // ASCII: keep letters, digits, spaces, hyphens,
            // underscores; everything else becomes an underscore.
            if (std::isalnum(c) || c == ' ' || c == '-' || c == '_') {
                sanitized += static_cast<char>(c);
            } else {
                sanitized += '_';
            }
            ++i;
        } else {
            // Non-ASCII: copy the whole UTF-8 sequence as-is
            // (see json_export.h for why), instead of replacing
            // each byte separately.
            size_t length = (c & 0xE0) == 0xC0 ? 2
                : (c & 0xF0) == 0xE0 ? 3
                : (c & 0xF8) == 0xF0 ? 4 : 1;
            if (i + length > title.size()) {
                length = title.size() - i;
            }
            sanitized.append(title, i, length);
            i += length;
        }
    }
    // Trim spaces (the only whitespace that can survive
    // sanitizing: tabs and newlines became underscores above).
    size_t begin = sanitized.find_first_not_of(' ');
    if (begin == std::string::npos) {
        return "recipe.json";
    }
    size_t end = sanitized.find_last_not_of(' ');
    return sanitized.substr(begin, end - begin + 1) + ".json";
}
