const std = @import("std");

// The recipe-list search predicate, extracted verbatim from
// main.zig so it can be unit-tested without DVUI: main.zig
// imports DVUI, which blocks running its tests standalone,
// while this file depends only on std. App behaviour is
// unchanged — main.zig calls search.containsIgnoreCase
// where it previously called its own inline copy.
//
// Semantics (unchanged from the app):
//   - case-insensitive (ASCII) substring match on the recipe
//     TITLE only, never on description/ingredients/steps
//   - an empty query matches everything
//   - a query longer than the title matches nothing

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var matches = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

const seed_titles: [3][]const u8 = .{
    "Banana Bread",
    "Tomato Basil Pasta",
    "Chicken Stir Fry",
};

test "empty query matches all titles" {
    for (seed_titles) |title| {
        try std.testing.expect(containsIgnoreCase(title, ""));
    }
}

test "exact title matches, other titles do not" {
    try std.testing.expect(containsIgnoreCase("Banana Bread", "Banana Bread"));
    try std.testing.expect(!containsIgnoreCase("Tomato Basil Pasta", "Banana Bread"));
    try std.testing.expect(!containsIgnoreCase("Chicken Stir Fry", "Banana Bread"));
}

test "mixed-case query matches" {
    try std.testing.expect(containsIgnoreCase("Banana Bread", "BANANA"));
    try std.testing.expect(containsIgnoreCase("Banana Bread", "bAnAnA BrEaD"));
    try std.testing.expect(containsIgnoreCase("Tomato Basil Pasta", "TOMATO BASIL PASTA"));
}

test "partial substring matches only the title containing it" {
    try std.testing.expect(containsIgnoreCase("Tomato Basil Pasta", "tom"));
    try std.testing.expect(!containsIgnoreCase("Banana Bread", "tom"));
    try std.testing.expect(!containsIgnoreCase("Chicken Stir Fry", "tom"));
    try std.testing.expect(containsIgnoreCase("Chicken Stir Fry", "stir"));
    try std.testing.expect(containsIgnoreCase("Banana Bread", "bread"));
}

test "query matching nothing matches no title" {
    for (seed_titles) |title| {
        try std.testing.expect(!containsIgnoreCase(title, "zucchini"));
    }
}

test "query longer than a title matches nothing" {
    try std.testing.expect(!containsIgnoreCase("Banana Bread", "Banana Bread Extra"));
    for (seed_titles) |title| {
        try std.testing.expect(!containsIgnoreCase(title, "Banana Bread, Tomato Basil Pasta, Chicken Stir Fry"));
    }
}

test "match is on the title only, not the description" {
    // "A classic loaf, best with very ripe bananas." is
    // Banana Bread's description; none of it is in the title.
    try std.testing.expect(!containsIgnoreCase("Banana Bread", "classic loaf"));
    try std.testing.expect(!containsIgnoreCase("Banana Bread", "very ripe"));
    try std.testing.expect(!containsIgnoreCase("Tomato Basil Pasta", "weeknight pasta"));
}
