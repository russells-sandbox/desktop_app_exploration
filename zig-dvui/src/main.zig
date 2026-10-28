const std = @import("std");
const dvui = @import("dvui");
const db = @import("db.zig");
const search = @import("search.zig");
const images = @import("images.zig");
const imageloader = @import("imageloader.zig");

// Recipe manager test app.
// Recipes load from SQLite (db.zig) in the current working
// directory, seeded once from the seed data below — the same
// seed the Rust and Odin versions use (Banana Bread, Tomato
// Basil Pasta, Chicken Stir Fry; 19 ingredients, 13 steps).
// No network yet.
//
// Layout, like the Rust version:
//   - left pane: "Recipes", a title search box, an "Add
//     recipe" button, and one row per matching recipe — a
//     thumbnail (or a spinner while its image loads) plus a
//     button, the selected recipe marked with "> "
//   - right pane: detail for the selected recipe —
//     description, servings, image (or a loading spinner, an
//     error, or "[No image yet]"), ingredients, numbered
//     steps, notes, and Edit / Delete buttons; or the add/edit
//     form, which takes over the detail pane
// The search filters the list only; the detail keeps showing
// the selected recipe even if it no longer matches the filter,
// as in the Rust and Odin versions.
//
// Add/edit/delete and images match rust-egui's behavior:
//   - add/edit via a form (Save writes, Cancel discards,
//     title required, servings must be a whole number),
//     delete with inline confirmation, selection by id
//   - images decode on a worker thread (imageloader.zig) and
//     show a spinner while loading; detail photo up to
//     400x300, list thumbnail 32x32
//   - the detail pane fades in over 0.25s when the selection
//     changes (DVUI's AnimateWidget, kind .alpha; see below)
//   - image import copies a file into images/ (git-ignored)
//     with a _1/_2 suffix on collision; DVUI has no native
//     file picker, so the form takes a source path in a text
//     field plus an Import button instead of a file dialog

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 900.0, .h = 600.0 },
            .title = "Recipe Manager",
            .org = "example",
            .app = "recipe-manager",
        },
    },
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

// Seed data, used only when recipes.db is empty on first run;
// later runs load from the database and do not re-seed.
const seed_recipes: [3]db.Recipe = .{
    .{
        .title = "Banana Bread",
        .description = "A classic loaf, best with very ripe bananas.",
        .servings = 8,
        .ingredients = &.{
            .{ .amount = "3", .unit = "", .name = "ripe bananas, mashed" },
            .{ .amount = "1/2", .unit = "cup", .name = "butter, melted" },
            .{ .amount = "3/4", .unit = "cup", .name = "sugar" },
            .{ .amount = "1", .unit = "", .name = "egg" },
            .{ .amount = "1", .unit = "tsp", .name = "vanilla" },
            .{ .amount = "1", .unit = "tsp", .name = "baking soda" },
            .{ .amount = "1 1/2", .unit = "cups", .name = "flour" },
        },
        .steps = &.{
            "Preheat the oven to 350°F and grease a 9x5 loaf pan.",
            "Mash the bananas, then stir in the melted butter, sugar, egg, and vanilla.",
            "Stir in the baking soda and flour until just combined.",
            "Pour into the pan and bake for 55-65 minutes, until a toothpick comes out clean.",
            "Cool in the pan for 10 minutes, then turn out onto a rack.",
        },
        .notes = "Optional: fold in walnuts or chocolate chips before baking.",
    },
    .{
        .title = "Tomato Basil Pasta",
        .description = "A quick weeknight pasta with fresh tomatoes and basil.",
        .servings = 4,
        .ingredients = &.{
            .{ .amount = "12", .unit = "oz", .name = "pasta" },
            .{ .amount = "2", .unit = "lbs", .name = "tomatoes, chopped" },
            .{ .amount = "3", .unit = "cloves", .name = "garlic, sliced" },
            .{ .amount = "1/4", .unit = "cup", .name = "olive oil" },
            .{ .amount = "1", .unit = "cup", .name = "basil leaves" },
            .{ .amount = "1/2", .unit = "cup", .name = "parmesan, grated" },
        },
        .steps = &.{
            "Cook the pasta in salted water until al dente, reserving a cup of pasta water.",
            "Meanwhile, warm the olive oil and garlic until fragrant, about 2 minutes.",
            "Add the tomatoes and cook until they soften, about 8 minutes.",
            "Toss the pasta with the sauce, basil, and parmesan, adding pasta water as needed.",
        },
        .notes = "Serve immediately, with extra parmesan on top.",
    },
    .{
        .title = "Chicken Stir Fry",
        .description = "Chicken and vegetables in a simple soy-ginger sauce, served with rice.",
        .servings = 4,
        .ingredients = &.{
            .{ .amount = "1 1/2", .unit = "lbs", .name = "chicken breast, sliced" },
            .{ .amount = "2", .unit = "", .name = "bell peppers, sliced" },
            .{ .amount = "2", .unit = "cups", .name = "broccoli florets" },
            .{ .amount = "3", .unit = "tbsp", .name = "soy sauce" },
            .{ .amount = "1", .unit = "tbsp", .name = "ginger, grated" },
            .{ .amount = "2", .unit = "cloves", .name = "garlic, minced" },
        },
        .steps = &.{
            "Sear the chicken in a hot, oiled pan until cooked through, then set aside.",
            "Stir fry the peppers and broccoli until just tender, about 4 minutes.",
            "Return the chicken to the pan with the soy sauce, ginger, and garlic.",
            "Cook for 2 more minutes, stirring, until the sauce coats everything.",
        },
        .notes = "Serve over rice.",
    },
};

// Frame-persistent UI state.
var selected_id: i64 = 0;
var search_buffer: [128]u8 = @splat(0);

const Mode = enum { viewing, editing };
var mode: Mode = .viewing;
var draft_is_new: bool = true;
var confirming_delete: bool = false;

// Error texts: string literals, or formatted into these
// buffers at the time they are set (each slot has its own,
// so setting one never clobbers the other).
var form_error: ?[]const u8 = null;
var form_error_buf: [512]u8 = undefined;
var detail_error: ?[]const u8 = null;
var detail_error_buf: [512]u8 = undefined;

fn setFormError(comptime fmt: []const u8, args: anytype) void {
    form_error = std.fmt.bufPrint(&form_error_buf, fmt, args) catch "Error.";
}

fn setDetailError(comptime fmt: []const u8, args: anytype) void {
    detail_error = std.fmt.bufPrint(&detail_error_buf, fmt, args) catch "Error.";
}

// The add/edit draft. DVUI text entries read fixed buffers
// (up to the first zero byte) every frame, so the draft lives
// in buffers the widgets write into directly; opening the
// form refills them from the recipe being edited (or zeroes
// them for a new recipe). Rows are capped — a test app does
// not need unbounded rows, and fixed buffers keep the form
// free of per-frame allocation.
const MAX_INGREDIENTS = 32;
const MAX_STEPS = 32;

const IngDraft = struct {
    amount: [32]u8 = @splat(0),
    unit: [32]u8 = @splat(0),
    name: [256]u8 = @splat(0),
};

const StepDraft = struct {
    text: [1024]u8 = @splat(0),
};

// Captured form texts for one ingredient row. A named type
// (not an anonymous struct) so drawForm and saveForm agree
// on the type — Zig treats separately written anonymous
// structs as different types.
const IngRowText = struct {
    amount: []u8,
    unit: []u8,
    name: []u8,
};

const Draft = struct {
    id: i64 = 0,
    title: [256]u8 = @splat(0),
    description: [2048]u8 = @splat(0),
    servings: [32]u8 = @splat(0),
    image_path: [1024]u8 = @splat(0),
    import_source: [1024]u8 = @splat(0),
    notes: [2048]u8 = @splat(0),
    ingredients: [MAX_INGREDIENTS]IngDraft = @splat(.{}),
    ing_count: usize = 0,
    steps: [MAX_STEPS]StepDraft = @splat(.{}),
    step_count: usize = 0,
};

var draft: Draft = .{};

fn fillBuf(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    // Leave at least one zero byte so the widget always sees
    // a terminator, even for a full buffer.
    const n = @min(buf.len - 1, text.len);
    @memcpy(buf[0..n], text[0..n]);
}

fn draftClear() void {
    draft = .{};
}

fn draftFromRecipe(recipe: db.Recipe) void {
    draft = .{};
    draft.id = recipe.id;
    fillBuf(&draft.title, recipe.title);
    fillBuf(&draft.description, recipe.description);
    var servings_buf: [32]u8 = undefined;
    const servings_text = std.fmt.bufPrint(&servings_buf, "{d}", .{recipe.servings}) catch "";
    fillBuf(&draft.servings, servings_text);
    fillBuf(&draft.image_path, recipe.image_path);
    fillBuf(&draft.notes, recipe.notes);
    draft.ing_count = @min(recipe.ingredients.len, MAX_INGREDIENTS);
    for (recipe.ingredients[0..draft.ing_count], 0..) |ing, i| {
        fillBuf(&draft.ingredients[i].amount, ing.amount);
        fillBuf(&draft.ingredients[i].unit, ing.unit);
        fillBuf(&draft.ingredients[i].name, ing.name);
    }
    draft.step_count = @min(recipe.steps.len, MAX_STEPS);
    for (recipe.steps[0..draft.step_count], 0..) |step, i| {
        fillBuf(&draft.steps[i].text, step);
    }
}

/// Index of the selected recipe, or 0 when the selection is
/// stale (the caller checks for an empty list first).
fn selectedIndex(recipes: []db.Recipe) usize {
    for (recipes, 0..) |recipe, i| {
        if (recipe.id == selected_id) return i;
    }
    return 0;
}

/// Draw one text field bound to a draft buffer and return its
/// current text. The slice points into the buffer and stays
/// valid for the rest of the frame.
fn textField(
    src: std.builtin.SourceLocation,
    buf: []u8,
    multiline: bool,
    opts: dvui.Options,
) []u8 {
    var entry = dvui.textEntry(src, .{ .text = .{ .buffer = buf }, .multiline = multiline }, opts);
    const text = entry.textGet();
    entry.deinit();
    return text;
}

/// Scale an image to fit inside max_w x max_h, preserving
/// aspect ratio and never scaling up.
fn fitSize(w: u32, h: u32, max_w: f32, max_h: f32) dvui.Size {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const scale = @min(@min(max_w / fw, max_h / fh), 1.0);
    return .{ .w = fw * scale, .h = fh * scale };
}

/// Draw a loaded image scaled to fit max_w x max_h.
fn drawLoadedImage(
    src: std.builtin.SourceLocation,
    img: imageloader.LoadedImage,
    max_w: f32,
    max_h: f32,
) void {
    _ = dvui.image(src, .{
        .source = .{ .pixels = .{
            .rgba = img.rgba,
            .width = img.width,
            .height = img.height,
        } },
        .shrink = .ratio,
    }, .{
        .min_size_content = fitSize(img.width, img.height, max_w, max_h),
    });
}

pub fn appFrame() !dvui.App.Result {
    // Load from SQLite on the first frame; a no-op after that.
    // On failure db.recipes stays empty and db.load_error is
    // set, shown in the detail pane below instead of crashing.
    db.ensureLoaded(&seed_recipes);
    const recipes = db.recipes;

    // Advance image loading and start decoding any recipe
    // image that is not already cached, failed, or loading.
    imageloader.poll();
    for (recipes) |recipe| {
        if (recipe.image_path.len > 0) imageloader.ensureStarted(recipe.image_path);
    }

    // Keep the selection valid: first recipe when nothing is
    // selected yet, first recipe when the selected one is
    // gone (deleted), none when the list is empty.
    if (recipes.len > 0) {
        if (selected_id == 0) {
            selected_id = recipes[0].id;
        } else {
            var found = false;
            for (recipes) |recipe| {
                if (recipe.id == selected_id) found = true;
            }
            if (!found) selected_id = recipes[0].id;
        }
    } else {
        selected_id = 0;
    }

    const editing = mode == .editing;

    var root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true });
    defer root.deinit();

    // Left pane: list + search.
    {
        var left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 260.0 },
            .expand = .vertical,
            .background = true,
            .padding = .all(8),
        });
        defer left.deinit();

        dvui.label(@src(), "Recipes", .{}, .{ .font = .theme(.title) });
        dvui.label(@src(), "Search recipes:", .{}, .{});

        // The text entry returns its current text; deinit after
        // reading it, as in DVUI's own examples.
        var search_entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &search_buffer } }, .{ .expand = .horizontal });
        const filter = search_entry.textGet();
        search_entry.deinit();

        if (dvui.button(@src(), "Add recipe", .{}, .{ .expand = .horizontal })) {
            if (!editing) {
                draftClear();
                draft_is_new = true;
                form_error = null;
                mode = .editing;
            }
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        for (recipes, 0..) |recipe, i| {
            if (!search.containsIgnoreCase(recipe.title, filter)) continue;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand = .horizontal,
            });
            defer row.deinit();

            // Thumbnail, spinner, or nothing (failed images
            // show nothing in the list, as in rust-egui).
            if (recipe.image_path.len > 0) {
                switch (imageloader.status(recipe.image_path)) {
                    .ready => if (imageloader.getReady(recipe.image_path)) |img| {
                        drawLoadedImage(@src(), img, 32.0, 32.0);
                    },
                    .loading, .not_started => dvui.spinner(@src(), .{
                        .min_size_content = .{ .w = 32.0, .h = 32.0 },
                    }),
                    .failed => {},
                }
            }

            // Buttons are identified by @src() plus id_extra, so
            // each recipe in the loop gets its own widget id.
            var label_buf: [64]u8 = undefined;
            const button_label = if (recipe.id == selected_id)
                std.fmt.bufPrint(&label_buf, "> {s}", .{recipe.title}) catch recipe.title
            else
                recipe.title;
            if (editing) {
                // Don't let a list click discard an in-progress edit.
                dvui.label(@src(), "{s}", .{button_label}, .{ .id_extra = i });
            } else if (dvui.button(@src(), button_label, .{}, .{ .id_extra = i, .expand = .horizontal })) {
                selected_id = recipe.id;
                confirming_delete = false;
                detail_error = null;
            }
        }
    }

    // Right pane: detail or form, scrollable.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        if (db.load_error) |err| {
            dvui.label(@src(), "Failed to load recipes:", .{}, .{ .font = .theme(.title) });
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl.deinit();
            tl.addText(err, .{});
            return .ok;
        }

        if (editing) {
            drawForm();
            return .ok;
        }

        if (recipes.len == 0) {
            dvui.label(@src(), "No recipes found.", .{}, .{ .font = .theme(.title) });
            return .ok;
        }

        const recipe = recipes[selectedIndex(recipes)];

        // List/detail transition: the detail pane fades in
        // over 0.25s. DVUI's AnimateWidget (kind .alpha) does
        // this natively, with an ease-out cubic; it starts its
        // animation on the widget's first frame, so the widget
        // id carries the recipe id and every selection change
        // is a first frame for a new widget id. AnimateWidget
        // has no slide kind that moves content (its .vertical
        // kind grows the height instead), so this stack fades
        // without the Rust version's 12px slide-up.
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
            .easing = dvui.easing.outCubic,
        }, .{
            .expand = .horizontal,
            .id_extra = @intCast(recipe.id),
        });
        defer animator.deinit();

        var detail = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .all(8),
        });
        defer detail.deinit();

        dvui.label(@src(), "{s}", .{recipe.title}, .{ .font = .theme(.title) });

        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl.deinit();
            tl.addText(recipe.description, .{});
        }

        dvui.label(@src(), "Servings: {d}", .{recipe.servings}, .{});

        // Image: loaded photo, loading spinner, error, or
        // "[No image yet]" — matching rust-egui's states.
        if (recipe.image_path.len == 0) {
            dvui.label(@src(), "[No image yet]", .{}, .{});
        } else switch (imageloader.status(recipe.image_path)) {
            .ready => if (imageloader.getReady(recipe.image_path)) |img| {
                drawLoadedImage(@src(), img, 400.0, 300.0);
            } else {
                dvui.label(@src(), "[Image could not be loaded: {s}]", .{recipe.image_path}, .{});
            },
            .loading, .not_started => {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                defer row.deinit();
                dvui.spinner(@src(), .{ .min_size_content = .{ .w = 32.0, .h = 32.0 } });
                dvui.label(@src(), "Loading image…", .{}, .{});
            },
            .failed => dvui.label(@src(), "[Image could not be loaded: {s}]", .{recipe.image_path}, .{}),
        }

        if (detail_error) |err| {
            dvui.label(@src(), "{s}", .{err}, .{});
        }

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            if (dvui.button(@src(), "Edit", .{}, .{})) {
                draftFromRecipe(recipe);
                draft_is_new = false;
                form_error = null;
                mode = .editing;
            }
            if (dvui.button(@src(), "Delete", .{}, .{})) {
                confirming_delete = true;
            }
        }
        if (confirming_delete) {
            dvui.label(@src(), "Delete this recipe?", .{}, .{});
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            if (dvui.button(@src(), "Yes, delete", .{}, .{})) {
                // Clear first, so a stale error from an earlier
                // failed attempt cannot skip the reload below.
                detail_error = null;
                db.deleteRecipe(recipe.id) catch |err| {
                    setDetailError("Could not delete recipe: {s}", .{@errorName(err)});
                };
                if (detail_error == null) {
                    db.reload() catch |err| {
                        setDetailError("Could not reload recipes: {s}", .{@errorName(err)});
                    };
                }
                confirming_delete = false;
            }
            if (dvui.button(@src(), "Cancel", .{}, .{})) {
                confirming_delete = false;
            }
        }

        dvui.label(@src(), "Ingredients", .{}, .{ .font = .theme(.title) });
        for (recipe.ingredients, 0..) |ing, i| {
            // One label per ingredient, each with its own id.
            if (ing.unit.len == 0) {
                dvui.label(@src(), "- {s} {s}", .{ ing.amount, ing.name }, .{ .id_extra = i });
            } else {
                dvui.label(@src(), "- {s} {s} {s}", .{ ing.amount, ing.unit, ing.name }, .{ .id_extra = i });
            }
        }

        dvui.label(@src(), "Steps", .{}, .{ .font = .theme(.title) });
        for (recipe.steps, 0..) |step, i| {
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = i, .expand = .horizontal });
            defer tl.deinit();
            tl.format("{d}. {s}", .{ i + 1, step }, .{});
        }

        dvui.label(@src(), "Notes", .{}, .{ .font = .theme(.title) });
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl.deinit();
            tl.addText(recipe.notes, .{});
        }
    }

    return .ok;
}

/// The add/edit form, drawn in place of the detail pane.
/// Field texts are captured during drawing and used by Save
/// in the same frame; the draft buffers themselves are what
/// the text entries edit, so Cancel just discards them.
fn drawForm() void {
    var form = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .all(8),
    });
    defer form.deinit();

    dvui.label(@src(), "{s}", .{if (draft_is_new) "Add recipe" else "Edit recipe"}, .{ .font = .theme(.title) });
    if (form_error) |err| {
        dvui.label(@src(), "{s}", .{err}, .{});
    }

    dvui.label(@src(), "Title:", .{}, .{});
    const title_text = textField(@src(), &draft.title, false, .{ .expand = .horizontal });
    dvui.label(@src(), "Description:", .{}, .{});
    const desc_text = textField(@src(), &draft.description, true, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 80.0 },
    });
    dvui.label(@src(), "Servings:", .{}, .{});
    const servings_text = textField(@src(), &draft.servings, false, .{ .expand = .horizontal });
    dvui.label(@src(), "Image path:", .{}, .{});
    const image_text = textField(@src(), &draft.image_path, false, .{ .expand = .horizontal });

    // Image import: DVUI has no native file picker, so the
    // source path comes from a text field and Import copies
    // it into images/ (see images.zig), filling the image
    // path field above with the stored copy. The row lives in
    // its own block so its defer deinit() runs at the end of
    // the row, not at the end of the form — otherwise every
    // widget after it would lay out inside this horizontal
    // row.
    dvui.label(@src(), "Import image from file:", .{}, .{});
    {
        var import_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer import_row.deinit();
        const import_text = textField(@src(), &draft.import_source, false, .{ .expand = .horizontal });
        if (dvui.button(@src(), "Import", .{}, .{})) {
            const source = std.mem.trim(u8, import_text, " \t\r\n");
            if (source.len == 0) {
                setFormError("Enter an image file path to import.", .{});
            } else if (images.importImage(source)) |stored| {
                fillBuf(&draft.image_path, stored);
                form_error = null;
            } else |err| {
                setFormError("Could not import image: {s}", .{@errorName(err)});
            }
        }
    }

    dvui.label(@src(), "Ingredients", .{}, .{ .font = .theme(.title) });
    var ing_texts: [MAX_INGREDIENTS]IngRowText = undefined;
    var remove_ingredient: ?usize = null;
    for (0..draft.ing_count) |i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer row.deinit();
        // Amount/unit use default text-entry sizing on purpose:
        // overriding min_size_content with only a width (height
        // defaulting to 0) leaves the entry's text clipped out
        // of view even though textGet() reports it correctly.
        ing_texts[i].amount = textField(@src(), &draft.ingredients[i].amount, false, .{ .id_extra = i });
        ing_texts[i].unit = textField(@src(), &draft.ingredients[i].unit, false, .{ .id_extra = i });
        ing_texts[i].name = textField(@src(), &draft.ingredients[i].name, false, .{ .id_extra = i, .expand = .horizontal });
        if (dvui.button(@src(), "Remove", .{}, .{ .id_extra = i })) {
            remove_ingredient = i;
        }
    }
    if (remove_ingredient) |i| {
        // Shift the buffers after the removed row up by one.
        // The widgets re-read the buffers next frame, so the
        // rows on screen follow the shift.
        for (i..draft.ing_count - 1) |j| {
            draft.ingredients[j] = draft.ingredients[j + 1];
        }
        draft.ingredients[draft.ing_count - 1] = .{};
        draft.ing_count -= 1;
    }
    if (draft.ing_count < MAX_INGREDIENTS) {
        if (dvui.button(@src(), "Add ingredient", .{}, .{})) {
            draft.ingredients[draft.ing_count] = .{};
            draft.ing_count += 1;
        }
    }

    dvui.label(@src(), "Steps", .{}, .{ .font = .theme(.title) });
    var step_texts: [MAX_STEPS][]u8 = undefined;
    var remove_step: ?usize = null;
    for (0..draft.step_count) |i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer row.deinit();
        step_texts[i] = textField(@src(), &draft.steps[i].text, false, .{ .id_extra = i, .expand = .horizontal });
        if (dvui.button(@src(), "Remove", .{}, .{ .id_extra = i })) {
            remove_step = i;
        }
    }
    if (remove_step) |i| {
        for (i..draft.step_count - 1) |j| {
            draft.steps[j] = draft.steps[j + 1];
        }
        draft.steps[draft.step_count - 1] = .{};
        draft.step_count -= 1;
    }
    if (draft.step_count < MAX_STEPS) {
        if (dvui.button(@src(), "Add step", .{}, .{})) {
            draft.steps[draft.step_count] = .{};
            draft.step_count += 1;
        }
    }

    dvui.label(@src(), "Notes:", .{}, .{});
    const notes_text = textField(@src(), &draft.notes, true, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 80.0 },
    });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();
    if (dvui.button(@src(), "Save", .{}, .{})) {
        saveForm(title_text, desc_text, servings_text, image_text, notes_text, ing_texts, step_texts);
    }
    if (dvui.button(@src(), "Cancel", .{}, .{})) {
        mode = .viewing;
        form_error = null;
    }
}

/// Validate the captured form texts and write the recipe.
/// On success the list reloads, the saved recipe is selected,
/// and the form closes; on failure form_error is set and the
/// form stays open.
fn saveForm(
    title_text: []u8,
    desc_text: []u8,
    servings_text: []u8,
    image_text: []u8,
    notes_text: []u8,
    ing_texts: [MAX_INGREDIENTS]IngRowText,
    step_texts: [MAX_STEPS][]u8,
) void {
    const title = std.mem.trim(u8, title_text, " \t\r\n");
    if (title.len == 0) {
        setFormError("Title is required.", .{});
        return;
    }
    const servings_parsed = std.fmt.parseInt(i64, std.mem.trim(u8, servings_text, " \t\r\n"), 10) catch {
        setFormError("Servings must be a whole number.", .{});
        return;
    };
    if (servings_parsed < 0 or servings_parsed > std.math.maxInt(u32)) {
        setFormError("Servings must be a whole number.", .{});
        return;
    }
    const servings: u32 = @intCast(servings_parsed);

    // Children are copied into fixed buffers first: the
    // slices handed to db must outlive this call, and the
    // text slices point into draft buffers that Save does not
    // modify, but building owned copies keeps that obvious.
    var ingredients: [MAX_INGREDIENTS]db.Ingredient = undefined;
    for (0..draft.ing_count) |i| {
        ingredients[i] = .{
            .amount = ing_texts[i].amount,
            .unit = ing_texts[i].unit,
            .name = ing_texts[i].name,
        };
    }
    var steps: [MAX_STEPS][]const u8 = undefined;
    for (0..draft.step_count) |i| {
        steps[i] = step_texts[i];
    }
    const recipe = db.Recipe{
        .id = draft.id,
        .title = title,
        .description = desc_text,
        .servings = servings,
        .image_path = std.mem.trim(u8, image_text, " \t\r\n"),
        .ingredients = ingredients[0..draft.ing_count],
        .steps = steps[0..draft.step_count],
        .notes = notes_text,
    };

    var saved_id: i64 = draft.id;
    if (draft_is_new) {
        saved_id = db.insertRecipe(recipe) catch |err| {
            setFormError("Could not save recipe: {s}", .{@errorName(err)});
            return;
        };
    } else {
        db.updateRecipe(recipe) catch |err| {
            setFormError("Could not save recipe: {s}", .{@errorName(err)});
            return;
        };
    }
    db.reload() catch |err| {
        setFormError("Could not reload recipes: {s}", .{@errorName(err)});
        return;
    };
    selected_id = saved_id;
    form_error = null;
    mode = .viewing;
}
