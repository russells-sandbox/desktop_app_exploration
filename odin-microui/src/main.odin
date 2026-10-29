package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:unicode/utf8"

import mu "vendor:microui"
import rl "vendor:raylib"

FONT_SIZE :: 20
WINDOW_WIDTH :: 900
WINDOW_HEIGHT :: 600
// List/detail transition length, matching the Rust version.
DETAIL_ANIM_SECONDS :: 0.25

// microUI only measures and emits draw commands; raylib does the
// actual drawing. These callbacks bridge the two, using raylib's
// default font, so no font file is needed.
text_width :: proc(font: mu.Font, str: string) -> i32 {
	cstr := strings.clone_to_cstring(str, context.temp_allocator)
	return rl.MeasureText(cstr, FONT_SIZE)
}

text_height :: proc(font: mu.Font) -> i32 {
	return FONT_SIZE
}

to_rl_color :: proc(c: mu.Color) -> rl.Color {
	return rl.Color{c.r, c.g, c.b, c.a}
}

// Feed one raylib key into microUI as a pressed/released key.
// microUI clears the pressed bits at the end of each frame, so a
// key pressed this frame is seen exactly once.
feed_key :: proc(ctx: ^mu.Context, rl_key: rl.KeyboardKey, mu_key: mu.Key) {
	if rl.IsKeyPressed(rl_key) {
		mu.input_key_down(ctx, mu_key)
	}
	if rl.IsKeyReleased(rl_key) {
		mu.input_key_up(ctx, mu_key)
	}
}

// Wrap a paragraph into label lines that fit the detail pane.
// microUI's own mu.text wrapping does not line up with raylib's
// default-font measurements here (it wrapped some steps and
// clipped others at the pane edge), so wrap explicitly with
// MeasureText instead, at a conservative width inside the pane.
draw_wrapped :: proc(ctx: ^mu.Context, text: string, max_width: i32) {
	words := strings.split(text, " ", context.temp_allocator)
	current := ""
	for word in words {
		candidate := word
		if current != "" {
			candidate = fmt.tprintf("%s %s", current, word)
		}
		if current != "" && text_width(nil, candidate) > max_width {
			mu.label(ctx, current)
			current = word
		} else {
			current = candidate
		}
	}
	if current != "" {
		mu.label(ctx, current)
	}
}

// Case-insensitive title search, like the Rust version: an empty
// query matches everything, otherwise the title must contain it.
matches_search :: proc(title, query: string) -> bool {
	if len(query) == 0 {
		return true
	}
	return strings.contains(
		strings.to_lower(title, context.temp_allocator),
		strings.to_lower(query, context.temp_allocator),
	)
}

// Index of the recipe with this id, or -1. Selection is by id,
// not by list position, so it survives inserts and deletes.
selected_index :: proc(recipes: []Recipe, id: i64) -> int {
	for recipe, i in recipes {
		if recipe.id == id {
			return i
		}
	}
	return -1
}

// --- Edit form draft -------------------------------------------------
// microUI textboxes edit a byte buffer plus a length, so the
// draft holds one buffer per field. The buffers live in the
// draft struct itself (and, for ingredients and steps, in the
// dynamic arrays' elements), so each textbox's id — which
// microUI derives from its buffer's address — stays distinct
// per field. Description and notes are single-line textboxes:
// microUI has no multi-line textbox widget, unlike egui.
Draft_Ingredient :: struct {
	amount_buf: [64]u8,
	amount_len: int,
	unit_buf:   [64]u8,
	unit_len:   int,
	name_buf:   [256]u8,
	name_len:   int,
}

Draft_Step :: struct {
	buf: [512]u8,
	len: int,
}

Draft :: struct {
	id:            i64,
	title_buf:     [256]u8,
	title_len:     int,
	desc_buf:      [1024]u8,
	desc_len:      int,
	servings_buf:  [32]u8,
	servings_len:  int,
	image_buf:     [512]u8,
	image_len:     int,
	import_buf:    [512]u8,
	import_len:    int,
	ingredients:   [dynamic]Draft_Ingredient,
	steps:         [dynamic]Draft_Step,
	notes_buf:     [1024]u8,
	notes_len:     int,
}

buf_str :: proc(buf: []u8, len: int) -> string {
	return string(buf[:len])
}

buf_set :: proc(buf: []u8, length: ^int, s: string) {
	n := min(len(s), len(buf))
	copy(buf[:n], s[:n])
	length^ = n
}

draft_from_recipe :: proc(recipe: Recipe) -> Draft {
	draft: Draft
	draft.id = recipe.id
	buf_set(draft.title_buf[:], &draft.title_len, recipe.title)
	buf_set(draft.desc_buf[:], &draft.desc_len, recipe.description)
	buf_set(draft.servings_buf[:], &draft.servings_len, fmt.tprintf("%d", recipe.servings))
	buf_set(draft.image_buf[:], &draft.image_len, recipe.image_path)
	for ingredient in recipe.ingredients {
		row: Draft_Ingredient
		buf_set(row.amount_buf[:], &row.amount_len, ingredient.amount)
		buf_set(row.unit_buf[:], &row.unit_len, ingredient.unit)
		buf_set(row.name_buf[:], &row.name_len, ingredient.name)
		append(&draft.ingredients, row)
	}
	for step in recipe.steps {
		row: Draft_Step
		buf_set(row.buf[:], &row.len, step)
		append(&draft.steps, row)
	}
	buf_set(draft.notes_buf[:], &draft.notes_len, recipe.notes)
	return draft
}

draft_empty :: proc() -> Draft {
	return Draft{}
}

// Validate the draft into a Recipe, with the Rust version's
// error messages: a title is required, and servings must be
// a whole number.
draft_to_recipe :: proc(draft: ^Draft) -> (Recipe, string) {
	title := strings.trim_space(buf_str(draft.title_buf[:], draft.title_len))
	if title == "" {
		return {}, "Title is required."
	}
	servings_text := strings.trim_space(buf_str(draft.servings_buf[:], draft.servings_len))
	servings, ok := strconv.parse_int(servings_text)
	if !ok {
		return {}, "Servings must be a whole number."
	}
	image_path := strings.trim_space(buf_str(draft.image_buf[:], draft.image_len))
	ingredients := make([dynamic]Ingredient, 0, len(draft.ingredients))
	for &row in draft.ingredients {
		append(&ingredients, Ingredient{
			amount = buf_str(row.amount_buf[:], row.amount_len),
			unit   = buf_str(row.unit_buf[:], row.unit_len),
			name   = buf_str(row.name_buf[:], row.name_len),
		})
	}
	steps := make([dynamic]string, 0, len(draft.steps))
	for &row in draft.steps {
		append(&steps, buf_str(row.buf[:], row.len))
	}
	return Recipe{
		id          = draft.id,
		title       = title,
		description = buf_str(draft.desc_buf[:], draft.desc_len),
		servings    = int(servings),
		image_path  = image_path,
		ingredients = ingredients[:],
		steps       = steps[:],
		notes       = buf_str(draft.notes_buf[:], draft.notes_len),
	}, ""
}

// --- Raylib-side image drawing ---------------------------------------
// microUI has no image widget, so images are drawn by raylib
// after microUI's commands, at rectangles reserved during the
// microUI frame with layout_next. Each record also carries the
// clip rectangle in force when it was reserved, so a texture
// never draws outside its pane (or past scrolled content).
Draw_Kind :: enum {
	Texture,
	Detail_Spinner,
	Thumb_Spinner,
	Import_Spinner,
}

Draw_Record :: struct {
	kind:    Draw_Kind,
	texture: rl.Texture2D,
	rect:    mu.Rect,
	clip:    mu.Rect,
}

// A small animated spinner: a circle with one rotating spoke,
// like egui's Spinner. The angle comes from the frame time,
// so it animates while raylib keeps redrawing every frame.
draw_spinner :: proc(cx, cy: i32, radius: f32) {
	rl.DrawCircleLines(cx, cy, radius, rl.DARKGRAY)
	angle := rl.GetTime() * 6.0
	ex := cx + i32(radius * f32(math.cos(angle)))
	ey := cy + i32(radius * f32(math.sin(angle)))
	rl.DrawLine(cx, cy, ex, ey, rl.DARKGRAY)
}

main :: proc() {
	// microUI's context is ~270 KB of fixed-size state, so it lives
	// on the heap, not the stack.
	ctx := new(mu.Context)
	defer free(ctx)
	mu.init(ctx)
	ctx.text_width = text_width
	ctx.text_height = text_height

	// Load from SQLite, seeding from recipes.odin on first run.
	// A load failure leaves recipes empty and db_error set, and
	// the detail pane shows that error instead of crashing,
	// like the Rust version. The list is a dynamic array, not
	// a slice: add appends to it and delete removes from it,
	// and Odin's append/ordered_remove only accept dynamic
	// arrays, not plain slices.
	recipes := make([dynamic]Recipe, 0, 4)
	defer delete(recipes)
	db_error := ""
	db, db_open_err := open_database("recipes.db")
	defer close_database(db)
	if db_open_err != "" {
		db_error = db_open_err
	} else if err := ensure_schema_and_seed(db, RECIPES[:]); err != "" {
		db_error = err
	} else {
		loaded, load_err := load_recipes(db)
		if load_err != "" {
			db_error = load_err
		} else {
			append(&recipes, ..loaded)
		}
	}
	selected_id: i64 = -1
	if len(recipes) > 0 {
		selected_id = recipes[0].id
	}
	search_buf: [256]u8
	search_len := 0

	// Edit/delete state. The detail pane shows the form while
	// editing; list clicks are ignored then, so an in-progress
	// edit cannot be discarded by clicking another recipe.
	editing := false
	draft_is_new := false
	draft: Draft
	form_error := ""
	confirming_delete := false
	status_error := ""

	// Image texture cache, keyed by image path (see images.odin).
	image_cache := make(map[string]^Image_Entry)

	// Network JSON import state (see json_import.odin). The
	// URL field defaults to the local test-data server, like
	// the Rust version. import_message/import_error are heap
	// strings owned by main (poll_import_job transfers the
	// worker's error string, or clones); they are never
	// temp-allocator strings, so they survive the frame loop's
	// free_all(context.temp_allocator).
	import_url_buf: [512]u8
	import_url_len := 0
	buf_set(import_url_buf[:], &import_url_len, "http://localhost:8000/recipes.json")
	import_thread: ^thread.Thread
	import_job: ^Import_Job
	import_message := ""
	import_error := ""

	// List/detail transition state: which recipe id the current
	// fade/slide is for, when it started, and the detail pane's
	// y position when it started (so a user-dragged pane slides
	// from where it actually is, and returns there exactly).
	anim_for_id: i64 = -1
	anim_start: f64
	anim_base_y: i32 = 10
	anim_base_pending := false
	anim_active := false

	draw_records := make([dynamic]Draw_Record, 0, 16)
	defer delete(draw_records)

	// Without WINDOW_RESIZABLE, raylib creates a fixed-size
	// window and the window manager offers no resize handle:
	// that was the whole bug. The flag must be set before
	// InitWindow. The minimum size keeps the fixed-width form
	// rows (import, ingredients, steps) usable when the
	// window is shrunk; enlarging is unrestricted.
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Recipe Manager")
	rl.SetWindowMinSize(640, 480)
	rl.SetTargetFPS(60)
	defer rl.CloseWindow()
	defer cleanup_images(&image_cache)

	// Last seen window size, for snapping the panes to the
	// new layout when the outer window is resized (below).
	prev_win_w: i32 = WINDOW_WIDTH
	prev_win_h: i32 = WINDOW_HEIGHT

	for !rl.WindowShouldClose() {
		// Feed raylib's input into microUI.
		mouse := rl.GetMousePosition()
		mu.input_mouse_move(ctx, i32(mouse.x), i32(mouse.y))
		if rl.IsMouseButtonPressed(.LEFT) {
			mu.input_mouse_down(ctx, i32(mouse.x), i32(mouse.y), .LEFT)
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			mu.input_mouse_up(ctx, i32(mouse.x), i32(mouse.y), .LEFT)
		}
		// raylib reports wheel-up as positive, but in microUI a
		// positive scroll delta moves the content up (revealing
		// what is below), which is the wheel-DOWN direction for
		// the user. Negate so scrolling down reveals lower
		// content, as in every other app; without the negation
		// wheel-down at the top of a pane did nothing (the
		// negative delta clamped to zero) and wheel-up scrolled
		// the wrong way, which made the Save button of a tall
		// form unreachable by scrolling.
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			mu.input_scroll(ctx, 0, i32(-wheel * 20))
		}
		// Typed characters go to microUI's text input (the search
		// box and the form's textboxes).
		for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
			buf, n := utf8.encode_rune(ch)
			mu.input_text(ctx, string(buf[:n]))
		}
		// Keys microUI's textbox understands.
		feed_key(ctx, .BACKSPACE, .BACKSPACE)
		feed_key(ctx, .DELETE, .DELETE)
		feed_key(ctx, .LEFT, .LEFT)
		feed_key(ctx, .RIGHT, .RIGHT)
		feed_key(ctx, .HOME, .HOME)
		feed_key(ctx, .END, .END)
		feed_key(ctx, .ENTER, .RETURN)
		feed_key(ctx, .LEFT_SHIFT, .SHIFT)
		feed_key(ctx, .RIGHT_SHIFT, .SHIFT)
		feed_key(ctx, .LEFT_CONTROL, .CTRL)
		feed_key(ctx, .RIGHT_CONTROL, .CTRL)
		feed_key(ctx, .LEFT_ALT, .ALT)
		feed_key(ctx, .RIGHT_ALT, .ALT)
		feed_key(ctx, .A, .A)
		feed_key(ctx, .X, .X)
		feed_key(ctx, .C, .C)
		feed_key(ctx, .V, .V)

		// Advance image loading: start decodes for any new image
		// paths, and turn finished decodes into textures.
		ensure_image_loads(&image_cache, recipes[:])
		poll_image_loads(&image_cache)

		// Collect a finished URL import, if any, and insert it
		// (see poll_import_job in json_import.odin).
		poll_import_job(db, &recipes, &selected_id, &import_thread, &import_job, &import_message, &import_error)

		// List/detail transition progress, 0.0 (just changed) to
		// 1.0 (settled), eased so it starts fast and slows into
		// place — the same 0.25s ease-out cubic as the Rust
		// version. microUI's own drawing has no opacity, so the
		// fade is a window-background overlay drawn over the
		// detail pane in the raylib pass below, fading from
		// opaque to transparent, while the pane itself slides
		// up 12px into place by moving its window rectangle.
		// The slide only applies while the transition runs, so
		// dragging the pane afterwards is unaffected.
		//
		// The rectangle move itself happens after mu.end below,
		// not here: microUI's container pool only has a free
		// slot once the frame has started (its pool items are
		// stamped with the previous frame until begin runs), so
		// calling get_container before the first begin trips
		// its pool assertion. The move applies to the next
		// frame's layout, which is one frame behind the fade —
		// imperceptible at 60fps, and on the trigger frame the
		// overlay is fully opaque anyway.
		now := rl.GetTime()
		if !editing && selected_id >= 0 && selected_id != anim_for_id {
			anim_for_id = selected_id
			anim_start = now
			anim_active = true
			anim_base_pending = true
		}
		detail_eased := 1.0
		detail_t := 1.0
		if anim_active {
			detail_t = (now - anim_start) / DETAIL_ANIM_SECONDS
			if detail_t >= 1.0 {
				detail_eased = 1.0
			} else {
				detail_eased = 1.0 - (1.0 - detail_t) * (1.0 - detail_t) * (1.0 - detail_t)
			}
		}

		clear(&draw_records)
		query := string(search_buf[:search_len])
		sel_idx := selected_index(recipes[:], selected_id)

		// Pane layout follows the outer window size, keeping
		// the original proportions at 900x600: a fixed 280px
		// list column, a 10px gap, and the detail pane taking
		// the rest. The form rows and wrap width below are
		// derived from the detail width the same way, so at
		// 900x600 they are exactly the old fixed values
		// (550 wrap, 440 import/step text, 250 ingredient
		// name). Widths are clamped so a small window cannot
		// produce a negative column width.
		win_w := rl.GetScreenWidth()
		win_h := rl.GetScreenHeight()
		list_rect := mu.Rect{10, 10, 280, win_h - 20}
		detail_rect := mu.Rect{300, 10, win_w - 310, win_h - 20}
		detail_wrap := max(detail_rect.w - 40, 100)
		import_text_w := max(detail_rect.w - 150, 40)
		ing_name_w := max(detail_rect.w - 340, 40)
		step_text_w := max(detail_rect.w - 150, 40)

		mu.begin(ctx)

		// Left pane: recipe list with title search. Close is
		// disabled so a pane cannot be lost by clicking its X;
		// the panes can still be dragged and resized.
		if mu.begin_window(ctx, "Recipes", list_rect, {.NO_CLOSE}) {
			mu.layout_row(ctx, {-1}, 0)
			mu.label(ctx, "Recipes")
			mu.label(ctx, "Search recipes:")
			mu.textbox(ctx, search_buf[:], &search_len)
			if !editing {
				if res := mu.button(ctx, "Add recipe", .NONE, {}); .SUBMIT in res {
					draft = draft_empty()
					draft_is_new = true
					editing = true
					form_error = ""
				}
			}
			// Network JSON import from a URL (see
			// json_import.odin), like the Rust version's left
			// panel: a URL field, an Import button, a spinner
			// and "Importing…" while the worker thread runs,
			// then a success message with the imported count
			// or the error. The button is ignored while
			// editing, so an import cannot discard an
			// in-progress edit, and while an import is in
			// flight the spinner replaces the button. microUI
			// labels have no per-label colour, so unlike the
			// Rust version's red error label, the error here
			// is a plain label with the error text. The button
			// reads "Import from URL", not "Import": microUI
			// ids derive from the label, and the edit form
			// already has an "Import" button (for images),
			// which can be visible in the same frame while
			// editing — two "Import" buttons would share one
			// id and interfere with each other.
			mu.label(ctx, "Import from URL:")
			mu.textbox(ctx, import_url_buf[:], &import_url_len)
			if import_thread != nil {
				mu.label(ctx, "Importing…")
				mu.layout_row(ctx, {-1}, 32)
				spin_rect := mu.layout_next(ctx)
				spin_clip := mu.get_clip_rect(ctx)
				append(&draw_records, Draw_Record{
					kind = .Import_Spinner,
					rect = spin_rect, clip = spin_clip,
				})
				mu.layout_row(ctx, {-1}, 0)
			} else if res := mu.button(ctx, "Import from URL", .NONE, {}); .SUBMIT in res && !editing {
				// Fetch and parse on a worker thread;
				// poll_import_job collects the result. A
				// previous message or error is freed and
				// cleared so the spinner is the only status
				// shown. (Both are heap-owned when non-empty.)
				if import_message != "" {
					delete(import_message)
				}
				if import_error != "" {
					delete(import_error)
				}
				import_message = ""
				import_error = ""
				job := new(Import_Job)
				job.url = strings.clone(string(import_url_buf[:import_url_len]))
				import_job = job
				import_thread = thread.create_and_start_with_poly_data(job, import_job_proc)
			}
			if import_message != "" {
				mu.label(ctx, import_message)
			}
			if import_error != "" {
				mu.label(ctx, import_error)
			}
			for recipe in recipes {
				if !matches_search(recipe.title, query) {
					continue
				}
				// Two columns: a 32x32 thumbnail cell, then the
				// title button. The thumbnail cell's rectangle
				// is reserved with layout_next and drawn by
				// raylib after microUI's commands.
				mu.layout_row(ctx, {32, -1}, 32)
				thumb_rect := mu.layout_next(ctx)
				thumb_clip := mu.get_clip_rect(ctx)
				if recipe.image_path != "" {
					if entry, ok := image_cache[recipe.image_path]; ok {
						if entry.state == .Loaded {
							append(&draw_records, Draw_Record{
								kind = .Texture, texture = entry.thumb,
								rect = thumb_rect, clip = thumb_clip,
							})
						} else if entry.state == .Loading {
							append(&draw_records, Draw_Record{
								kind = .Thumb_Spinner,
								rect = thumb_rect, clip = thumb_clip,
							})
						}
					}
				}
				label := recipe.title
				if recipe.id == selected_id {
					label = strings.concatenate({"> ", recipe.title}, context.temp_allocator)
				}
				if res := mu.button(ctx, label, .NONE, {}); .SUBMIT in res && !editing {
					selected_id = recipe.id
					confirming_delete = false
					status_error = ""
				}
			}
			mu.end_window(ctx)
		}

		// Right pane: detail for the selected recipe, or the edit
		// form. The selection survives filtering, like the Rust
		// version: filtering the list does not change the detail.
		if mu.begin_window(ctx, "Detail", detail_rect, {.NO_CLOSE}) {
			mu.layout_row(ctx, {-1}, 0)
			if db_error != "" {
				mu.label(ctx, "Database error:")
				draw_wrapped(ctx, db_error, detail_wrap)
			} else if editing {
				mu.label(ctx, draft_is_new ? "Add recipe" : "Edit recipe")
				if form_error != "" {
					mu.label(ctx, form_error)
				}
				mu.label(ctx, "Title:")
				mu.textbox(ctx, draft.title_buf[:], &draft.title_len)
				mu.label(ctx, "Description:")
				mu.textbox(ctx, draft.desc_buf[:], &draft.desc_len)
				mu.label(ctx, "Servings:")
				mu.textbox(ctx, draft.servings_buf[:], &draft.servings_len)
				mu.label(ctx, "Image path:")
				mu.textbox(ctx, draft.image_buf[:], &draft.image_len)
				// Fixed widths, not -1 for the textbox: in
				// microUI a -1 width means "fill the body from
				// here", so {-1, 100} would give the textbox
				// the full body width and push the button
				// off-screen past the clip. -1 only works as
				// the LAST column (as in the list's {32, -1}).
				mu.label(ctx, "Import image from file (copied into images/):")
				mu.layout_row(ctx, {import_text_w, 100}, 0)
				mu.textbox(ctx, draft.import_buf[:], &draft.import_len)
				if res := mu.button(ctx, "Import", .NONE, {}); .SUBMIT in res {
					source := strings.trim_space(buf_str(draft.import_buf[:], draft.import_len))
					if imported, err := import_image(source); err != "" {
						form_error = err
					} else {
						buf_set(draft.image_buf[:], &draft.image_len, imported)
						form_error = ""
					}
				}
				mu.layout_row(ctx, {-1}, 0)
				mu.label(ctx, "Ingredients")
				remove_ingredient := -1
				for &row, i in draft.ingredients {
					// Repeated "Remove" labels would share one
					// microUI id, so each row pushes its index
					// onto the id stack to keep them distinct.
					mu.push_id(ctx, uintptr(i))
					mu.layout_row(ctx, {80, 80, ing_name_w, 80}, 0)
					mu.textbox(ctx, row.amount_buf[:], &row.amount_len)
					mu.textbox(ctx, row.unit_buf[:], &row.unit_len)
					mu.textbox(ctx, row.name_buf[:], &row.name_len)
					if res := mu.button(ctx, "Remove", .NONE, {}); .SUBMIT in res {
						remove_ingredient = i
					}
					mu.pop_id(ctx)
				}
				if remove_ingredient >= 0 {
					ordered_remove(&draft.ingredients, remove_ingredient)
				}
				// Reset to a single column: without this, the
				// multi-column row above would keep applying
				// (layout_row_items reuses the last widths),
				// and the button, the Steps label, the Add step
				// button and the Notes label would all land on
				// one row in the ingredient columns.
				mu.layout_row(ctx, {-1}, 0)
				if res := mu.button(ctx, "Add ingredient", .NONE, {}); .SUBMIT in res {
					append(&draft.ingredients, Draft_Ingredient{})
				}
				mu.label(ctx, "Steps")
				remove_step := -1
				for &row, i in draft.steps {
					mu.push_id(ctx, uintptr(i))
					mu.layout_row(ctx, {step_text_w, 80}, 0)
					mu.textbox(ctx, row.buf[:], &row.len)
					if res := mu.button(ctx, "Remove", .NONE, {}); .SUBMIT in res {
						remove_step = i
					}
					mu.pop_id(ctx)
				}
				if remove_step >= 0 {
					ordered_remove(&draft.steps, remove_step)
				}
				// Single column again, as above: otherwise the
				// step row's columns would keep applying to the
				// button, the Notes label, and the Notes box.
				mu.layout_row(ctx, {-1}, 0)
				if res := mu.button(ctx, "Add step", .NONE, {}); .SUBMIT in res {
					append(&draft.steps, Draft_Step{})
				}
				mu.label(ctx, "Notes:")
				mu.textbox(ctx, draft.notes_buf[:], &draft.notes_len)
				mu.layout_row(ctx, {100, 100}, 0)
				if res := mu.button(ctx, "Save", .NONE, {}); .SUBMIT in res {
					recipe, verr := draft_to_recipe(&draft)
					if verr != "" {
						form_error = verr
					} else if draft_is_new {
						id, dberr := insert_recipe(db, recipe)
						if dberr != "" {
							form_error = dberr
						} else {
							recipe.id = id
							append(&recipes, recipe)
							selected_id = id
							editing = false
							form_error = ""
						}
					} else {
						if dberr := update_recipe(db, recipe); dberr != "" {
							form_error = dberr
						} else {
							if idx := selected_index(recipes[:], recipe.id); idx >= 0 {
								recipes[idx] = recipe
							}
							selected_id = recipe.id
							editing = false
							form_error = ""
						}
					}
				}
				if res := mu.button(ctx, "Cancel", .NONE, {}); .SUBMIT in res {
					editing = false
					form_error = ""
				}
			} else if sel_idx >= 0 {
				recipe := recipes[sel_idx]
				mu.label(ctx, recipe.title)
				draw_wrapped(ctx, recipe.description, detail_wrap)
				mu.label(ctx, fmt.tprintf("Servings: %d", recipe.servings))
				if recipe.image_path == "" {
					mu.label(ctx, "[No image yet]")
				} else if entry, ok := image_cache[recipe.image_path]; ok && entry.state == .Loaded {
					// Scale down to at most 400x300, like the
					// Rust version, preserving the aspect ratio.
					disp_w, disp_h := entry.texture.width, entry.texture.height
					if disp_w > 400 || disp_h > 300 {
						scale := min(f32(400) / f32(disp_w), f32(300) / f32(disp_h))
						disp_w = i32(f32(disp_w) * scale)
						disp_h = i32(f32(disp_h) * scale)
					}
					mu.layout_row(ctx, {-1}, disp_h)
					img_rect := mu.layout_next(ctx)
					img_clip := mu.get_clip_rect(ctx)
					append(&draw_records, Draw_Record{
						kind = .Texture, texture = entry.texture,
						rect = mu.Rect{img_rect.x, img_rect.y, disp_w, disp_h},
						clip = img_clip,
					})
					mu.layout_row(ctx, {-1}, 0)
				} else if entry, ok := image_cache[recipe.image_path]; ok && entry.state == .Loading {
					mu.layout_row(ctx, {-1}, 32)
					spin_rect := mu.layout_next(ctx)
					spin_clip := mu.get_clip_rect(ctx)
					append(&draw_records, Draw_Record{
						kind = .Detail_Spinner,
						rect = spin_rect, clip = spin_clip,
					})
					mu.layout_row(ctx, {-1}, 0)
				} else {
					mu.label(ctx, fmt.tprintf("[Image could not be loaded: %s]", recipe.image_path))
				}
				if status_error != "" {
					mu.label(ctx, status_error)
				}
				mu.layout_row(ctx, {100, 100}, 0)
				if res := mu.button(ctx, "Edit", .NONE, {}); .SUBMIT in res {
					draft = draft_from_recipe(recipe)
					draft_is_new = false
					editing = true
					form_error = ""
					confirming_delete = false
				}
				if res := mu.button(ctx, "Delete", .NONE, {}); .SUBMIT in res {
					confirming_delete = true
				}
				mu.layout_row(ctx, {-1}, 0)
				if confirming_delete {
					mu.label(ctx, "Delete this recipe?")
					mu.layout_row(ctx, {150, 100}, 0)
					if res := mu.button(ctx, "Confirm delete", .NONE, {}); .SUBMIT in res {
						if dberr := delete_recipe(db, recipe.id); dberr != "" {
							status_error = dberr
						} else {
							ordered_remove(&recipes, sel_idx)
							if len(recipes) > 0 {
								selected_id = recipes[0].id
							} else {
								selected_id = -1
							}
							status_error = ""
						}
						confirming_delete = false
					}
					if res := mu.button(ctx, "Cancel", .NONE, {}); .SUBMIT in res {
						confirming_delete = false
					}
					mu.layout_row(ctx, {-1}, 0)
				}
				mu.label(ctx, "Ingredients")
				for ingredient in recipe.ingredients {
					if ingredient.unit == "" {
						mu.label(ctx, fmt.tprintf("- %s %s", ingredient.amount, ingredient.name))
					} else {
						mu.label(ctx, fmt.tprintf("- %s %s %s", ingredient.amount, ingredient.unit, ingredient.name))
					}
				}
				mu.label(ctx, "Steps")
				for step, i in recipe.steps {
					// Wrapped, not a single label: labels never
					// wrap, so long steps were clipped at the
					// pane edge.
					draw_wrapped(ctx, fmt.tprintf("%d. %s", i + 1, step), detail_wrap)
				}
				mu.label(ctx, "Notes")
				draw_wrapped(ctx, recipe.notes, detail_wrap)
			} else {
				mu.label(ctx, "No recipe selected.")
			}
			mu.end_window(ctx)
		}

		mu.end(ctx)

		// Outer-window resize: a rect passed to begin_window
		// does not move a pane that already exists (that is
		// what lets the user drag a pane and have it stay),
		// so a resized outer window would otherwise leave
		// the panes at their old size and position. When the
		// window size changes, snap both panes to the new
		// layout for the next frame. This deliberately
		// discards a user-dragged position on resize only;
		// the panes can be dragged again afterwards. The
		// slide below runs after this, so a mid-transition
		// resize still slides from the new base y.
		if win_w != prev_win_w || win_h != prev_win_h {
			if cnt := mu.get_container(ctx, "Recipes"); cnt != nil {
				cnt.rect = list_rect
			}
			if cnt := mu.get_container(ctx, "Detail"); cnt != nil {
				cnt.rect = detail_rect
				anim_base_y = 10
			}
			prev_win_w = win_w
			prev_win_h = win_h
		}

		// List/detail slide, for the next frame's layout (see
		// the transition comment above). The pane's y at the
		// moment the selection changed is the slide's base, so
		// a user-dragged pane slides from where it actually is
		// and returns there exactly when the transition ends.
		if anim_active {
			if cnt := mu.get_container(ctx, "Detail"); cnt != nil && cnt.rect.w != 0 {
				if anim_base_pending {
					anim_base_y = cnt.rect.y
					anim_base_pending = false
				}
				if detail_t >= 1.0 {
					cnt.rect.y = anim_base_y
					anim_active = false
				} else {
					cnt.rect.y = anim_base_y + i32((1.0-detail_eased)*12.0)
				}
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)

		// Draw every command microUI produced this frame.
		cmd: ^mu.Command
		scissoring := false
		for mu.next_command(ctx, &cmd) {
			switch v in cmd.variant {
			case ^mu.Command_Rect:
				rl.DrawRectangle(v.rect.x, v.rect.y, v.rect.w, v.rect.h, to_rl_color(v.color))
			case ^mu.Command_Text:
				cstr := strings.clone_to_cstring(v.str, context.temp_allocator)
				rl.DrawText(cstr, v.pos.x, v.pos.y, FONT_SIZE, to_rl_color(v.color))
			case ^mu.Command_Icon:
				color := to_rl_color(v.color)
				switch v.id {
				case .CLOSE:
					rl.DrawLine(v.rect.x, v.rect.y, v.rect.x + v.rect.w, v.rect.y + v.rect.h, color)
					rl.DrawLine(v.rect.x + v.rect.w, v.rect.y, v.rect.x, v.rect.y + v.rect.h, color)
				case .CHECK:
					rl.DrawLine(v.rect.x, v.rect.y + v.rect.h / 2, v.rect.x + v.rect.w / 2, v.rect.y + v.rect.h, color)
					rl.DrawLine(v.rect.x + v.rect.w / 2, v.rect.y + v.rect.h, v.rect.x + v.rect.w, v.rect.y, color)
				case .COLLAPSED:
					rl.DrawTriangle(
						rl.Vector2{f32(v.rect.x), f32(v.rect.y)},
						rl.Vector2{f32(v.rect.x), f32(v.rect.y + v.rect.h)},
						rl.Vector2{f32(v.rect.x + v.rect.w), f32(v.rect.y + v.rect.h / 2)},
						color,
					)
				case .EXPANDED:
					rl.DrawTriangle(
						rl.Vector2{f32(v.rect.x), f32(v.rect.y)},
						rl.Vector2{f32(v.rect.x + v.rect.w), f32(v.rect.y)},
						rl.Vector2{f32(v.rect.x + v.rect.w / 2), f32(v.rect.y + v.rect.h)},
						color,
					)
				case .RESIZE:
					rl.DrawLine(v.rect.x + v.rect.w, v.rect.y, v.rect.x, v.rect.y + v.rect.h, color)
					rl.DrawLine(v.rect.x + v.rect.w, v.rect.y + v.rect.h / 2, v.rect.x + v.rect.w / 2, v.rect.y + v.rect.h, color)
				case .NONE:
				}
			case ^mu.Command_Clip:
				// microUI resets clipping with a huge "unclipped" rect.
				if v.rect.w >= 0x1000000 {
					if scissoring {
						rl.EndScissorMode()
						scissoring = false
					}
				} else {
					rl.BeginScissorMode(v.rect.x, v.rect.y, v.rect.w, v.rect.h)
					scissoring = true
				}
			case ^mu.Command_Jump:
				// next_command already follows jumps, so this is unreachable.
			}
		}
		if scissoring {
			rl.EndScissorMode()
		}

		// Draw the images reserved during the microUI frame,
		// clipped to their panes.
		for record in draw_records {
			rl.BeginScissorMode(record.clip.x, record.clip.y, record.clip.w, record.clip.h)
			switch record.kind {
			case .Texture:
				rl.DrawTexturePro(
					record.texture,
					rl.Rectangle{0, 0, f32(record.texture.width), f32(record.texture.height)},
					rl.Rectangle{f32(record.rect.x), f32(record.rect.y), f32(record.rect.w), f32(record.rect.h)},
					rl.Vector2{0, 0}, 0, rl.WHITE,
				)
			case .Detail_Spinner:
				draw_spinner(record.rect.x + 14, record.rect.y + 16, 10)
				cstr := strings.clone_to_cstring("Loading image...", context.temp_allocator)
				rl.DrawText(cstr, record.rect.x + 32, record.rect.y + 6, FONT_SIZE, rl.DARKGRAY)
			case .Thumb_Spinner:
				draw_spinner(
					record.rect.x + record.rect.w / 2,
					record.rect.y + record.rect.h / 2,
					10,
				)
			case .Import_Spinner:
				draw_spinner(record.rect.x + 14, record.rect.y + 16, 10)
				import_cstr := strings.clone_to_cstring("Importing…", context.temp_allocator)
				rl.DrawText(import_cstr, record.rect.x + 32, record.rect.y + 6, FONT_SIZE, rl.DARKGRAY)
			}
			rl.EndScissorMode()
		}

		// List/detail transition fade: a window-background
		// overlay over the detail pane, fading from opaque to
		// transparent over the transition (the slide is applied
		// to the pane's rectangle above). Drawn last, so the
		// detail image fades with the rest of the pane.
		if anim_active && detail_eased < 1.0 && !editing {
			if cnt := mu.get_container(ctx, "Detail"); cnt != nil && cnt.rect.w != 0 {
				c := ctx.style.colors[.WINDOW_BG]
				c.a = u8((1.0 - detail_eased) * 255.0)
				rl.DrawRectangle(cnt.rect.x, cnt.rect.y, cnt.rect.w, cnt.rect.h, to_rl_color(c))
			}
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	// Join an import still in flight when the window closes,
	// rather than leaving its thread running: its recipes were
	// never inserted, so they are freed (see
	// discard_import_job in json_import.odin).
	discard_import_job(&import_thread, &import_job)
	// Import status strings are heap-owned when non-empty.
	if import_message != "" {
		delete(import_message)
	}
	if import_error != "" {
		delete(import_error)
	}
}
