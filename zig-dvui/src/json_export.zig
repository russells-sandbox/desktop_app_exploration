const std = @import("std");
const db = @import("db.zig");
const json_import = @import("json_import.zig");

// JSON export for the recipe manager, mirroring rust-egui's
// json_export.rs (pushed as eb293fd) and the import format
// in json_import.zig, so an exported file can be imported
// again unchanged. The two document shapes are:
//   - a single recipe, as a pretty-printed bare object:
//     {"title": ..., ...}
//   - a collection, as a pretty-printed
//     {"recipes": [...]} object (the shape
//     test-data/recipes.json uses, so "Export all" writes
//     that shape, not a bare array).
//
// Per-recipe fields, in this order, matching the import
// format: title, description, servings, image_path,
// notes, ingredients (array of {amount, unit, name}
// objects, in order), steps (array of strings, in order).
// This stack's Recipe stores a null image_path as an
// empty string (see json_import.zig), so an empty
// image_path exports as JSON null, and a non-empty one
// exports as its string — the reverse of the importer's
// null -> "" mapping.
//
// Serialization is hand-written, not std.json.stringify,
// for the same reason the importer walks std.json.Value
// by hand: the field order must be exactly the one above,
// and pretty-printing must match serde_json's
// to_string_pretty (2-space indent, empty arrays as []).
// Escaping matches serde_json for valid UTF-8 text:
// '"' -> \", '\' -> \\, newline -> \n, carriage return
// -> \r, tab -> \t, backspace -> \b, form feed -> \f,
// other control bytes -> \u00xx (lowercase hex); all
// other bytes, including UTF-8 multibyte sequences,
// pass through unchanged. Strings here come from the
// database or the importer's UTF-8-checked parser, so
// they are valid UTF-8 in practice.
//
// Exporting runs on the UI thread (see main.zig): the
// data is already in memory, and writing a recipe file
// is small, so there is no worker thread here the way
// import has one for fetching and parsing. The path
// comes from a typed field in the UI (DVUI has no native
// file picker, as in the raw-file import row); this
// module only turns recipes into text and writes that
// text to the chosen path. No new dependencies: only
// std and the existing db/json_import modules.

// --- Pretty-printing writer ---

fn writeSpaces(writer: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn writeIndent(writer: anytype, level: usize) !void {
    try writer.writeByte('\n');
    try writeSpaces(writer, level);
}

/// Write one JSON string, with serde_json-style escaping
/// (see the module header).
fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    const hex = "0123456789abcdef";
                    try writer.writeAll("\\u00");
                    try writer.writeByte(hex[byte >> 4]);
                    try writer.writeByte(hex[byte & 0x0f]);
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeStringField(
    writer: anytype,
    level: usize,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    try writeIndent(writer, level);
    try writer.print("\"{s}\": ", .{name});
    try writeJsonString(writer, value);
    if (comma) try writer.writeByte(',');
}

fn writeIntField(
    writer: anytype,
    level: usize,
    name: []const u8,
    value: u32,
    comma: bool,
) !void {
    try writeIndent(writer, level);
    try writer.print("\"{s}\": {d}", .{ name, value });
    if (comma) try writer.writeByte(',');
}

/// Write one recipe object. `level` is the indent level
/// of the object's opening brace (in 2-space units); its
/// fields sit one level deeper, ingredient objects two
/// levels deeper, and so on. The caller writes the indent
/// before the opening brace when the recipe is an array
/// element; a top-level single recipe starts at level 0.
fn writeRecipe(writer: anytype, recipe: db.Recipe, level: usize) !void {
    try writer.writeByte('{');
    try writeStringField(writer, level + 1, "title", recipe.title, true);
    try writeStringField(writer, level + 1, "description", recipe.description, true);
    try writeIntField(writer, level + 1, "servings", recipe.servings, true);
    // image_path: empty (this stack's null) -> null.
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"image_path\": ");
    if (recipe.image_path.len == 0) {
        try writer.writeAll("null");
    } else {
        try writeJsonString(writer, recipe.image_path);
    }
    try writer.writeByte(',');
    try writeStringField(writer, level + 1, "notes", recipe.notes, true);
    // ingredients: [] when empty, otherwise one object
    // per line, each object's fields one level deeper.
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"ingredients\": ");
    if (recipe.ingredients.len == 0) {
        try writer.writeAll("[]");
    } else {
        try writer.writeByte('[');
        for (recipe.ingredients, 0..) |ing, i| {
            try writeIndent(writer, level + 2);
            try writer.writeByte('{');
            try writeStringField(writer, level + 3, "amount", ing.amount, true);
            try writeStringField(writer, level + 3, "unit", ing.unit, true);
            try writeStringField(writer, level + 3, "name", ing.name, false);
            try writeIndent(writer, level + 2);
            try writer.writeByte('}');
            if (i + 1 < recipe.ingredients.len) try writer.writeByte(',');
        }
        try writeIndent(writer, level + 1);
        try writer.writeByte(']');
    }
    try writer.writeByte(',');
    // steps: [] when empty, otherwise one string per line.
    // This is the last field, so it carries no comma.
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"steps\": ");
    if (recipe.steps.len == 0) {
        try writer.writeAll("[]");
    } else {
        try writer.writeByte('[');
        for (recipe.steps, 0..) |step, i| {
            try writeIndent(writer, level + 2);
            try writeJsonString(writer, step);
            if (i + 1 < recipe.steps.len) try writer.writeByte(',');
        }
        try writeIndent(writer, level + 1);
        try writer.writeByte(']');
    }
    try writeIndent(writer, level);
    try writer.writeByte('}');
}

/// Serialize one recipe as a pretty-printed bare JSON
/// object. The returned text is owned by the caller.
pub fn exportSingle(alloc: std.mem.Allocator, recipe: db.Recipe) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try writeRecipe(&aw.writer, recipe, 0);
    var list = aw.toArrayList();
    return list.toOwnedSlice(alloc);
}

/// Serialize a slice of recipes as a pretty-printed
/// {"recipes": [...]} collection object. The returned
/// text is owned by the caller.
pub fn exportCollection(alloc: std.mem.Allocator, recipes: []const db.Recipe) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const writer = &aw.writer;
    try writer.writeByte('{');
    try writeIndent(writer, 1);
    try writer.writeAll("\"recipes\": ");
    if (recipes.len == 0) {
        try writer.writeAll("[]");
    } else {
        try writer.writeByte('[');
        for (recipes, 0..) |recipe, i| {
            try writeIndent(writer, 2);
            try writeRecipe(writer, recipe, 2);
            if (i + 1 < recipes.len) try writer.writeByte(',');
        }
        try writeIndent(writer, 1);
        try writer.writeByte(']');
    }
    try writeIndent(writer, 0);
    try writer.writeByte('}');
    var list = aw.toArrayList();
    return list.toOwnedSlice(alloc);
}

// --- Writing ---

/// Write already-serialized JSON text to the given path,
/// creating or overwriting it. The caller (main.zig) has
/// already asked the user for the path via a typed field,
/// so this does not pick a path itself. Read/write errors
/// propagate as the underlying file error (FileNotFound,
/// AccessDenied, ...); formatWriteError turns those into
/// rust-egui's "Could not write file {path}: …" style.
pub fn writeExport(io: std.Io, path: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// A one-line UI message for an export-write error, in
/// rust-egui's style ("Could not write file {path}: …").
/// OutOfMemory keeps a generic message rather than posing
/// as a write failure.
pub fn formatWriteError(alloc: std.mem.Allocator, path: []const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.OutOfMemory => alloc.dupe(u8, "Could not write export file."),
        else => std.fmt.allocPrint(alloc, "Could not write file {s}: {s}.", .{ path, @errorName(err) }),
    };
}

// --- Default file names ---

/// Sanitize one title into a file name, in rust-egui's
/// style: characters that are not letters, digits, spaces,
/// hyphens, or underscores become underscores, so a title
/// like "Fish & Chips" does not become a strange file
/// name, and a title containing "/" cannot escape the
/// chosen directory. Non-ASCII bytes pass through
/// unchanged (they are UTF-8 continuation/lead bytes, and
/// the ASCII test below only replaces ASCII punctuation
/// and control bytes); a title that sanitizes to nothing
/// but whitespace falls back to "recipe.json".
pub fn defaultFileName(alloc: std.mem.Allocator, title: []const u8) ![]u8 {
    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(alloc);
    for (title) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == ' ' or byte == '-' or byte == '_') {
            try sanitized.append(alloc, byte);
        } else if (byte >= 0x80) {
            try sanitized.append(alloc, byte);
        } else {
            try sanitized.append(alloc, '_');
        }
    }
    const trimmed = std.mem.trim(u8, sanitized.items, " \t\r\n");
    if (trimmed.len == 0) return alloc.dupe(u8, "recipe.json");
    return std.fmt.allocPrint(alloc, "{s}.json", .{trimmed});
}

/// The same default file name, written into `buf` with
/// no allocation, for the UI's fixed path buffer (see
/// main.zig): the returned slice points into `buf`, and
/// the caller must zero-terminate after it if the buffer
/// is to be read as a text-entry buffer. Long titles are
/// truncated to fit, reserving room for ".json"; a title
/// that sanitizes to nothing but whitespace gives
/// "recipe.json", as in defaultFileName.
pub fn defaultFileNameInto(buf: []u8, title: []const u8) []const u8 {
    // Stage the sanitized title on the stack first, so
    // trimming and the ".json" suffix do not have to run
    // while writing into the caller's buffer.
    var staging: [1024]u8 = undefined;
    var len: usize = 0;
    for (title) |byte| {
        if (len >= staging.len) break;
        if (std.ascii.isAlphanumeric(byte) or byte == ' ' or byte == '-' or byte == '_') {
            staging[len] = byte;
        } else if (byte >= 0x80) {
            staging[len] = byte;
        } else {
            staging[len] = '_';
        }
        len += 1;
    }
    const trimmed = std.mem.trim(u8, staging[0..len], " \t\r\n");
    if (trimmed.len == 0) {
        const fallback = "recipe.json";
        const n = @min(buf.len, fallback.len);
        @memcpy(buf[0..n], fallback[0..n]);
        return buf[0..n];
    }
    const suffix = ".json";
    // Reserve one byte for the text-entry terminator, so
    // the returned slice is never the whole buffer.
    const max_title = if (buf.len > suffix.len + 1) buf.len - suffix.len - 1 else 0;
    const n = @min(trimmed.len, max_title);
    @memcpy(buf[0..n], trimmed[0..n]);
    @memcpy(buf[n .. n + suffix.len], suffix);
    return buf[0 .. n + suffix.len];
}

// --- Tests ---

const test_alloc = std.testing.allocator;

fn sampleRecipe() db.Recipe {
    return .{
        .title = "Mushroom Risotto",
        .description = "Creamy rice.",
        .servings = 4,
        .image_path = "",
        .ingredients = &.{.{ .amount = "1", .unit = "lb", .name = "mushrooms" }},
        .steps = &.{"Cook it."},
        .notes = "Stir often.",
    };
}

test "export single is a bare object that reimports" {
    const text = try exportSingle(test_alloc, sampleRecipe());
    defer test_alloc.free(text);
    // Bare object, not wrapped in a "recipes" collection.
    try std.testing.expect(std.mem.startsWith(u8, text, "{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"recipes\"") == null);
    const recipes = try json_import.parseRecipes(test_alloc, text);
    defer json_import.freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
    try std.testing.expectEqual(@as(u32, 4), recipes[0].servings);
    try std.testing.expectEqualStrings("", recipes[0].image_path);
    try std.testing.expectEqual(@as(usize, 1), recipes[0].ingredients.len);
    try std.testing.expectEqualStrings("mushrooms", recipes[0].ingredients[0].name);
    try std.testing.expectEqual(@as(usize, 1), recipes[0].steps.len);
    try std.testing.expectEqualStrings("Cook it.", recipes[0].steps[0]);
}

test "export single field order matches import format" {
    const text = try exportSingle(test_alloc, sampleRecipe());
    defer test_alloc.free(text);
    const fields = [_][]const u8{
        "\"title\"", "\"description\"", "\"servings\"", "\"image_path\"",
        "\"notes\"", "\"ingredients\"", "\"steps\"",
    };
    var prev: usize = 0;
    for (fields) |field| {
        const idx = std.mem.indexOfPos(u8, text, prev, field) orelse
            return error.TestExpectedEqual;
        try std.testing.expect(idx >= prev);
        prev = idx;
    }
    const ing_fields = [_][]const u8{ "\"amount\"", "\"unit\"", "\"name\"" };
    prev = 0;
    for (ing_fields) |field| {
        const idx = std.mem.indexOfPos(u8, text, prev, field) orelse
            return error.TestExpectedEqual;
        prev = idx;
    }
}

test "export collection is a recipes object that reimports" {
    const recipes = [_]db.Recipe{ sampleRecipe(), sampleRecipe() };
    const text = try exportCollection(test_alloc, &recipes);
    defer test_alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"recipes\"") != null);
    const parsed = try json_import.parseRecipes(test_alloc, text);
    defer json_import.freeRecipes(test_alloc, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", parsed[0].title);
    try std.testing.expectEqualStrings("Mushroom Risotto", parsed[1].title);
}

test "export collection empty is an empty recipes array" {
    const text = try exportCollection(test_alloc, &.{});
    defer test_alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"recipes\": []") != null);
    const parsed = try json_import.parseRecipes(test_alloc, text);
    defer json_import.freeRecipes(test_alloc, parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
}

test "export preserves image path when present" {
    var recipe = sampleRecipe();
    recipe.image_path = "images/risotto.png";
    const text = try exportSingle(test_alloc, recipe);
    defer test_alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "images/risotto.png") != null);
    const parsed = try json_import.parseRecipes(test_alloc, text);
    defer json_import.freeRecipes(test_alloc, parsed);
    try std.testing.expectEqualStrings("images/risotto.png", parsed[0].image_path);
}

test "export escapes quotes, backslashes, and control characters" {
    var recipe = sampleRecipe();
    recipe.title = "Fish \"Special\" \\ Chips\n\t\x01";
    recipe.description = "Line one\r\nLine two";
    const text = try exportSingle(test_alloc, recipe);
    defer test_alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\\"Special\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\r\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\u0001") != null);
    // And the escaped text still parses back to the original.
    const parsed = try json_import.parseRecipes(test_alloc, text);
    defer json_import.freeRecipes(test_alloc, parsed);
    try std.testing.expectEqualStrings("Fish \"Special\" \\ Chips\n\t\x01", parsed[0].title);
    try std.testing.expectEqualStrings("Line one\r\nLine two", parsed[0].description);
}

test "default file name sanitizes and falls back" {
    const cases = [_]struct { title: []const u8, want: []const u8 }{
        .{ .title = "Banana Bread", .want = "Banana Bread.json" },
        .{ .title = "Fish & Chips / Fries", .want = "Fish _ Chips _ Fries.json" },
        .{ .title = "   ", .want = "recipe.json" },
        .{ .title = "", .want = "recipe.json" },
    };
    for (cases) |c| {
        const got = try defaultFileName(test_alloc, c.title);
        defer test_alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Fish _ Chips _ Fries.json",
        defaultFileNameInto(&buf, "Fish & Chips / Fries"),
    );
    try std.testing.expectEqualStrings("recipe.json", defaultFileNameInto(&buf, "   "));
}

test "write export writes and overwrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fmt.allocPrint(test_alloc, "{s}/out.json", .{path_buf[0..n]});
    defer test_alloc.free(path);
    try writeExport(std.testing.io, path, "{\"title\": \"Toast\"}");
    const first = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, test_alloc, .limited(1 << 20));
    defer test_alloc.free(first);
    try std.testing.expectEqualStrings("{\"title\": \"Toast\"}", first);
    try writeExport(std.testing.io, path, "replaced");
    const second = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, test_alloc, .limited(1 << 20));
    defer test_alloc.free(second);
    try std.testing.expectEqualStrings("replaced", second);
}

test "write export to a missing directory is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fmt.allocPrint(test_alloc, "{s}/no-such-dir/out.json", .{path_buf[0..n]});
    defer test_alloc.free(path);
    try std.testing.expectError(error.FileNotFound, writeExport(std.testing.io, path, "x"));
    const msg = try formatWriteError(test_alloc, path, error.FileNotFound);
    defer test_alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Could not write file") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, path) != null);
}
