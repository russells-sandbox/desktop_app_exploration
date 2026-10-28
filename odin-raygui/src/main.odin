package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

// Odin + raygui version of the recipe manager test app: a
// 900x600 window titled "Recipe Manager", a left pane listing
// recipes with a title search box, and a right pane showing
// the selected recipe's detail (description, servings, image,
// ingredients, numbered steps, notes), backed by SQLite
// (src/db.odin) and seeded once from src/recipes.odin — the
// same data as the Rust version (Banana Bread, Tomato Basil
// Pasta, Chicken Stir Fry, 19 ingredients, 13 steps total).
//
// UI toolkit: raygui (vendor:raylib, same package as raylib
// itself, so everything here is rl.Gui*). Buttons, text boxes
// and labels are raygui controls. One exception: the recipe
// list is not GuiListView. ListView takes a single
// semicolon-separated string and draws text-only rows, so it
// cannot show the 32x32 thumbnails the spec requires; the
// list here is instead a raygui scroll panel of rows, each
// with a thumbnail (or loading spinner) drawn by raylib and
// a GuiLabelButton for the title. The detail and form panes
// are raygui scroll panels too, with raylib DrawText for the
// wrapped body text (see draw_wrapped).
//
// Text wrapping: raygui labels do not wrap, so long
// description, step and note text is wrapped by hand with
// raylib's MeasureText at the detail width, the same lesson
// as odin-microui (whose widget wrapping clipped long lines).
//
// Animation: the detail pane fades in (raylib Fade on every
// drawn color) and slides up 12px over 0.25s with an ease-out
// cubic whenever the selection changes, including the first
// recipe at startup — mirroring the Rust version's
// list/detail transition. Image loading state lives in
// src/images.odin: while a path is decoding on its worker
// thread, both panes draw a rotating spinner arc (raylib
// DrawCircleSectorLines, driven by GetTime) instead of an
// image; on failure the detail shows an error line.

WINDOW_WIDTH :: 900
WINDOW_HEIGHT :: 600
DETAIL_ANIM_SECONDS :: 0.25

FONT_TITLE :: 26
FONT_BODY :: 20
LINE_GAP :: 6

// ---- Application state (package-level globals) ----

db_conn: ^Sqlite_Db
recipes: []Recipe
selected_id: i64 = -1
load_error: string
confirming_delete: bool
form_error: string

search_buf: [256]byte
search_edit: bool

list_scroll: rl.Vector2
detail_scroll: rl.Vector2
form_scroll: rl.Vector2

detail_anim_for: i64 = -1
detail_anim_start: f64

// The one text field currently in edit mode, if any.
// raygui text boxes take editMode by value and report a
// click (or Enter) as their return value, so the app owns
// the edit state: clicking a field makes it the active one,
// clicking it again (or pressing Enter) deactivates it, and
// clicking outside the active field deactivates it too, so
// at most one field ever captures keystrokes.
active_field: ^bool
active_field_bounds: rl.Rectangle

Mode :: enum {
	Viewing,
	Editing,
}

mode: Mode = .Viewing

// ---- Edit draft ----

// Fixed-size buffers, because GuiTextBox writes into a
// caller-owned cstring buffer. buf_str/set_buf convert
// between these and Odin strings.
Draft_Ingredient :: struct {
	amount:      [64]byte,
	unit:        [64]byte,
	name:        [256]byte,
	amount_edit: bool,
	unit_edit:   bool,
	name_edit:   bool,
}

Draft_Step :: struct {
	text: [512]byte,
	edit: bool,
}

Draft :: struct {
	id:               i64,
	is_new:           bool,
	title:            [256]byte,
	title_edit:       bool,
	description:      [512]byte,
	description_edit: bool,
	servings:         [32]byte,
	servings_edit:    bool,
	image_path:       [512]byte,
	image_path_edit:  bool,
	notes:            [512]byte,
	notes_edit:       bool,
	ingredients:      [dynamic]Draft_Ingredient,
	steps:            [dynamic]Draft_Step,
}

draft: Draft

buf_str :: proc(buf: []byte) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return string(buf[:n])
}

set_buf :: proc(buf: []byte, s: string) {
	n := min(len(buf) - 1, len(s))
	copy(buf[:n], s)
	for i := n; i < len(buf); i += 1 {
		buf[i] = 0
	}
}

buf_cstr :: proc(buf: []byte) -> cstring {
	return cstring(&buf[0])
}

draft_from_recipe :: proc(recipe: Recipe, is_new: bool) -> Draft {
	d: Draft
	d.id = recipe.id
	d.is_new = is_new
	set_buf(d.title[:], recipe.title)
	set_buf(d.description[:], recipe.description)
	// A new recipe starts with a blank servings field, like
	// the Rust version's empty draft (not a prefilled 0).
	if !is_new {
		set_buf(d.servings[:], fmt.tprintf("%d", recipe.servings))
	}
	set_buf(d.image_path[:], recipe.image_path)
	set_buf(d.notes[:], recipe.notes)
	for ingredient in recipe.ingredients {
		row: Draft_Ingredient
		set_buf(row.amount[:], ingredient.amount)
		set_buf(row.unit[:], ingredient.unit)
		set_buf(row.name[:], ingredient.name)
		append(&d.ingredients, row)
	}
	for step in recipe.steps {
		row: Draft_Step
		set_buf(row.text[:], step)
		append(&d.steps, row)
	}
	return d
}

// Validate like the Rust version's EditDraft::to_recipe:
// title required, servings a whole number, empty image path
// stored as "" (NULL in the database).
draft_to_recipe :: proc(d: ^Draft) -> (Recipe, string) {
	title := strings.trim_space(buf_str(d.title[:]))
	if title == "" {
		return {}, "Title is required."
	}
	servings, ok := strconv.parse_int(strings.trim_space(buf_str(d.servings[:])))
	if !ok {
		return {}, "Servings must be a whole number."
	}
	recipe: Recipe
	recipe.id = d.id
	recipe.title = title
	recipe.description = buf_str(d.description[:])
	recipe.servings = servings
	recipe.image_path = strings.trim_space(buf_str(d.image_path[:]))
	recipe.notes = buf_str(d.notes[:])
	ingredients := make([dynamic]Ingredient)
	for &row in d.ingredients {
		append(&ingredients, Ingredient{
			amount = buf_str(row.amount[:]),
			unit   = buf_str(row.unit[:]),
			name   = buf_str(row.name[:]),
		})
	}
	recipe.ingredients = ingredients[:]
	steps := make([dynamic]string)
	for &row in d.steps {
		append(&steps, buf_str(row.text[:]))
	}
	recipe.steps = steps[:]
	return recipe, ""
}

// ---- Text fields ----

text_field :: proc(bounds: rl.Rectangle, buf: []byte, edit: ^bool) {
	if active_field != nil && active_field != edit && rl.IsMouseButtonPressed(.LEFT) {
		mp := rl.GetMousePosition()
		b := active_field_bounds
		if mp.x < b.x || mp.x > b.x + b.width || mp.y < b.y || mp.y > b.y + b.height {
			active_field = nil
		}
	}
	editing := active_field == edit
	if rl.GuiTextBox(bounds, buf_cstr(buf), i32(len(buf)), editing) {
		if active_field == edit {
			active_field = nil
		} else {
			active_field = edit
			active_field_bounds = bounds
		}
	}
}

// ---- Wrapped text ----

// Split text into lines that fit max_width at font_size,
// measured with raylib's default font. Words longer than the
// width are split at rune boundaries (never inside a UTF-8
// sequence, so the ° in "350°F" survives).
wrap_lines :: proc(text: string, max_width: f32, font_size: i32) -> []string {
	words := strings.fields(text, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	current := ""
	for word in words {
		candidate := word
		if current != "" {
			candidate = strings.concatenate({current, " ", word}, context.temp_allocator)
		}
		if f32(rl.MeasureText(strings.clone_to_cstring(candidate, context.temp_allocator), font_size)) <= max_width {
			current = candidate
			continue
		}
		if current != "" {
			append(&lines, current)
			current = ""
		}
		if f32(rl.MeasureText(strings.clone_to_cstring(word, context.temp_allocator), font_size)) <= max_width {
			current = word
			continue
		}
		// Over-long word: split it into fitting chunks.
		chunk := ""
		for r in word {
			rbuf, n := utf8.encode_rune(r)
			rstr := string(rbuf[:n])
			cand := rstr
			if chunk != "" {
				cand = strings.concatenate({chunk, rstr}, context.temp_allocator)
			}
			if f32(rl.MeasureText(strings.clone_to_cstring(cand, context.temp_allocator), font_size)) <= max_width {
				chunk = cand
			} else {
				if chunk != "" {
					append(&lines, chunk)
				}
				chunk = rstr
			}
		}
		if chunk != "" {
			current = chunk
		}
	}
	if current != "" {
		append(&lines, current)
	}
	return lines[:]
}

wrapped_height :: proc(text: string, max_width: f32, font_size: i32) -> f32 {
	return f32(len(wrap_lines(text, max_width, font_size))) * f32(font_size + LINE_GAP)
}

draw_wrapped :: proc(x, y, max_width: f32, font_size: i32, color: rl.Color, text: string) -> f32 {
	yy := y
	for line in wrap_lines(text, max_width, font_size) {
		rl.DrawText(strings.clone_to_cstring(line, context.temp_allocator), i32(x), i32(yy), font_size, color)
		yy += f32(font_size + LINE_GAP)
	}
	return yy
}

draw_text :: proc(x, y: f32, font_size: i32, color: rl.Color, text: string) {
	rl.DrawText(strings.clone_to_cstring(text, context.temp_allocator), i32(x), i32(y), font_size, color)
}

// ---- Spinner ----

// A rotating 270-degree arc outline, driven by the frame
// time. Used wherever an image is still decoding: the list
// thumbnail slot and the detail pane.
draw_spinner :: proc(cx, cy, radius: f32, color: rl.Color) {
	start := f32(int(rl.GetTime()*240.0) % 360)
	rl.DrawCircleSectorLines({cx, cy}, radius, start, start + 270, 24, color)
}

// ---- Recipes ----

selected_recipe :: proc() -> ^Recipe {
	for &recipe in recipes {
		if recipe.id == selected_id {
			return &recipe
		}
	}
	return nil
}

reload_recipes :: proc() {
	loaded, err := load_recipes(db_conn)
	if err != "" {
		load_error = strings.clone(err)
		return
	}
	load_error = ""
	recipes = loaded
	if selected_recipe() == nil {
		if len(recipes) > 0 {
			selected_id = recipes[0].id
		} else {
			selected_id = -1
		}
	}
}

// Fit a texture inside a box, preserving its aspect ratio
// (like the Rust version's fit_to_exact_size), and return
// the destination rectangle within the box.
fit_rect :: proc(tex_w, tex_h: int, box_x, box_y, box_w, box_h: f32) -> rl.Rectangle {
	scale := min(box_w / f32(tex_w), box_h / f32(tex_h))
	w := f32(tex_w) * scale
	h := f32(tex_h) * scale
	return {box_x + (box_w-w)/2, box_y + (box_h-h)/2, w, h}
}

// ---- Detail pane ----

// Draw (draw = true) or measure (draw = false) the detail
// content for one recipe at (ox, oy), returning its total
// height. The scroll panel needs the height before drawing,
// so this runs twice per frame with identical layout; only
// the draw pass runs controls (buttons) and therefore only
// it can change state. alpha/y_slide carry the list/detail
// transition: fade from transparent and slide up 12px.
detail_block :: proc(draw: bool, ox, oy, width: f32, recipe: ^Recipe, alpha, y_slide: f32) -> f32 {
	y := oy + y_slide
	black := rl.Fade(rl.BLACK, alpha)
	dark := rl.Fade(rl.DARKGRAY, alpha)

	if draw {
		draw_text(ox, y, FONT_TITLE, black, recipe.title)
	}
	y += f32(FONT_TITLE + LINE_GAP)
	if draw {
		y = draw_wrapped(ox, y, width, FONT_BODY, dark, recipe.description)
	} else {
		y += wrapped_height(recipe.description, width, FONT_BODY)
	}
	if draw {
		draw_text(ox, y, FONT_BODY, dark, fmt.tprintf("Servings: %d", recipe.servings))
	}
	y += f32(FONT_BODY + LINE_GAP)

	// Image block: texture, loading spinner, error, or none.
	if recipe.image_path != "" {
		entry := image_ensure(recipe.image_path)
		switch entry.state {
		case .Ready:
			dest := fit_rect(int(entry.texture.width), int(entry.texture.height), ox, y, 400, 300)
			if draw {
				rl.DrawTexturePro(entry.texture, {0, 0, f32(entry.texture.width), f32(entry.texture.height)}, dest, {0, 0}, 0, rl.Fade(rl.WHITE, alpha))
			}
			y += dest.height + 10
		case .Loading:
			if draw {
				draw_spinner(ox + 14, y + 14, 12, rl.Fade(rl.DARKGRAY, alpha))
				draw_text(ox + 32, y + 4, FONT_BODY, dark, "Loading image...")
			}
			y += 38
		case .Failed:
			if draw {
				draw_text(ox, y, FONT_BODY, rl.Fade(rl.RED, alpha), fmt.tprintf("[Image could not be loaded: %s]", recipe.image_path))
			}
			y += f32(FONT_BODY + LINE_GAP)
		}
	} else {
		if draw {
			draw_text(ox, y, FONT_BODY, dark, "[No image yet]")
		}
		y += f32(FONT_BODY + LINE_GAP)
	}

	// Edit / Delete row.
	if draw {
		if rl.GuiButton({ox, y, 90, 30}, "Edit") {
			draft = draft_from_recipe(recipe^, false)
			mode = .Editing
			confirming_delete = false
			form_error = ""
		}
		if rl.GuiButton({ox + 100, y, 90, 30}, "Delete") {
			confirming_delete = true
		}
	}
	y += 40
	if confirming_delete {
		if draw {
			draw_text(ox, y, FONT_BODY, rl.Fade(rl.RED, alpha), "Delete this recipe?")
			if rl.GuiButton({ox, y + 28, 130, 30}, "Confirm delete") {
				if err := delete_recipe(db_conn, recipe.id); err != "" {
					load_error = strings.clone(err)
				} else {
					confirming_delete = false
					reload_recipes()
				}
			}
			if rl.GuiButton({ox + 140, y + 28, 90, 30}, "Cancel") {
				confirming_delete = false
			}
		}
		y += 68
	}

	if draw {
		draw_text(ox, y, FONT_BODY, black, "Ingredients")
	}
	y += f32(FONT_BODY + LINE_GAP)
	for ingredient in recipe.ingredients {
		line := ingredient.name
		if ingredient.amount != "" || ingredient.unit != "" {
			line = fmt.tprintf("- %s %s %s", ingredient.amount, ingredient.unit, ingredient.name)
		} else {
			line = fmt.tprintf("- %s", ingredient.name)
		}
		if draw {
			y = draw_wrapped(ox, y, width, FONT_BODY, dark, line)
		} else {
			y += wrapped_height(line, width, FONT_BODY)
		}
	}
	if draw {
		draw_text(ox, y, FONT_BODY, black, "Steps")
	}
	y += f32(FONT_BODY + LINE_GAP)
	for step, i in recipe.steps {
		line := fmt.tprintf("%d. %s", i + 1, step)
		if draw {
			y = draw_wrapped(ox, y, width, FONT_BODY, dark, line)
		} else {
			y += wrapped_height(line, width, FONT_BODY)
		}
	}
	if draw {
		draw_text(ox, y, FONT_BODY, black, "Notes")
	}
	y += f32(FONT_BODY + LINE_GAP)
	if draw {
		y = draw_wrapped(ox, y, width, FONT_BODY, dark, recipe.notes)
	} else {
		y += wrapped_height(recipe.notes, width, FONT_BODY)
	}
	return y - oy - y_slide
}

// ---- Edit form ----

// Same two-pass shape as detail_block: measure first (for
// the scroll panel's content height), then draw. Only the
// draw pass runs controls and mutates state.
form_block :: proc(draw: bool, ox, oy, width: f32) -> f32 {
	y := oy
	if draw {
		draw_text(ox, y, FONT_TITLE, rl.BLACK, "Add recipe" if draft.is_new else "Edit recipe")
	}
	y += f32(FONT_TITLE + LINE_GAP)
	if form_error != "" {
		if draw {
			draw_text(ox, y, FONT_BODY, rl.RED, form_error)
		}
		y += f32(FONT_BODY + LINE_GAP)
	}
	field :: proc(draw: bool, ox, y, width: f32, label: string, buf: []byte, edit: ^bool) -> f32 {
		if draw {
			draw_text(ox, y, FONT_BODY, rl.DARKGRAY, label)
			text_field({ox, y + 22, width, 30}, buf, edit)
		}
		return 62
	}
	y += field(draw, ox, y, width, "Title:", draft.title[:], &draft.title_edit)
	y += field(draw, ox, y, width, "Description:", draft.description[:], &draft.description_edit)
	y += field(draw, ox, y, width, "Servings:", draft.servings[:], &draft.servings_edit)
	// Image path row: text field plus Import button.
	if draw {
		draw_text(ox, y, FONT_BODY, rl.DARKGRAY, "Image path:")
		text_field({ox, y + 22, width - 120, 30}, draft.image_path[:], &draft.image_path_edit)
		if rl.GuiButton({ox + width - 110, y + 22, 110, 30}, "Import") {
			source := strings.trim_space(buf_str(draft.image_path[:]))
			if source == "" {
				form_error = "Enter an image file path to import."
			} else if dest, err := import_image(source); err != "" {
				form_error = strings.clone(err)
			} else {
				set_buf(draft.image_path[:], dest)
				delete(dest)
				form_error = ""
			}
		}
	}
	y += 62

	if draw {
		draw_text(ox, y, FONT_BODY, rl.BLACK, "Ingredients")
	}
	y += f32(FONT_BODY + LINE_GAP)
	remove_ingredient := -1
	for &row, i in draft.ingredients {
		if draw {
			text_field({ox, y, 70, 30}, row.amount[:], &row.amount_edit)
			text_field({ox + 78, y, 70, 30}, row.unit[:], &row.unit_edit)
			text_field({ox + 156, y, width - 246, 30}, row.name[:], &row.name_edit)
			if rl.GuiButton({ox + width - 80, y, 80, 30}, "Remove") {
				remove_ingredient = i
			}
		}
		y += 38
	}
	if draw && remove_ingredient >= 0 {
		ordered_remove(&draft.ingredients, remove_ingredient)
	}
	if draw {
		if rl.GuiButton({ox, y, 130, 30}, "Add ingredient") {
			append(&draft.ingredients, Draft_Ingredient{})
		}
	}
	y += 40

	if draw {
		draw_text(ox, y, FONT_BODY, rl.BLACK, "Steps")
	}
	y += f32(FONT_BODY + LINE_GAP)
	remove_step := -1
	for &row, i in draft.steps {
		if draw {
			text_field({ox, y, width - 90, 30}, row.text[:], &row.edit)
			if rl.GuiButton({ox + width - 80, y, 80, 30}, "Remove") {
				remove_step = i
			}
		}
		y += 38
	}
	if draw && remove_step >= 0 {
		ordered_remove(&draft.steps, remove_step)
	}
	if draw {
		if rl.GuiButton({ox, y, 110, 30}, "Add step") {
			append(&draft.steps, Draft_Step{})
		}
	}
	y += 40

	y += field(draw, ox, y, width, "Notes:", draft.notes[:], &draft.notes_edit)
	if draw {
		if rl.GuiButton({ox, y, 90, 30}, "Save") {
			recipe, err := draft_to_recipe(&draft)
			if err != "" {
				form_error = err
			} else if draft.is_new {
				if id, derr := insert_recipe(db_conn, recipe); derr != "" {
					form_error = strings.clone(derr)
				} else {
					mode = .Viewing
					reload_recipes()
					selected_id = id
				}
			} else {
				if derr := update_recipe(db_conn, recipe); derr != "" {
					form_error = strings.clone(derr)
				} else {
					mode = .Viewing
					reload_recipes()
					selected_id = recipe.id
				}
			}
		}
		if rl.GuiButton({ox + 100, y, 90, 30}, "Cancel") {
			mode = .Viewing
			form_error = ""
		}
	}
	y += 40
	return y - oy
}

// ---- Main ----

main :: proc() {
	// Without WINDOW_RESIZABLE, raylib creates a fixed-size
	// window and the window manager offers no resize handle:
	// that was the whole bug. The flag must be set before
	// InitWindow. The minimum size keeps the fixed-width
	// form rows usable when the window is shrunk; enlarging
	// is unrestricted.
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Recipe Manager")
	rl.SetWindowMinSize(640, 480)
	rl.SetTargetFPS(60)
	defer rl.CloseWindow()

	db, err := open_database("recipes.db")
	if err != "" {
		// No database: keep the window usable enough to show
		// the error, like the Rust version's load-error pane.
		load_error = strings.clone(err)
	} else {
		db_conn = db
		if serr := ensure_schema_and_seed(db_conn, RECIPES[:]); serr != "" {
			load_error = strings.clone(serr)
		} else {
			reload_recipes()
		}
	}
	// NOTE: this defer must stay at main's scope, not inside
	// the else above. Odin defers run at the end of their
	// enclosing scope, so a defer inside the else block would
	// close the database as soon as startup finished — and
	// every later write (add/edit/delete) would then fail
	// with SQLITE_MISUSE ("bad parameter or other API
	// misuse") on the closed handle, while reads from the
	// already-loaded recipes kept working. That exact bug
	// was caught by the add-recipe UI test and fixed here.
	// close_database tolerates a nil handle (open failed).
	defer close_database(db_conn)
	defer image_cleanup()

	for !rl.WindowShouldClose() {
		image_poll()

		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)

		// ---- Left pane: search, Add, recipe list ----
		rl.GuiLabel({20, 12, 260, 20}, "Search recipes:")
		text_field({20, 34, 260, 30}, search_buf[:], &search_edit)
		if mode != .Editing {
			if rl.GuiButton({20, 72, 260, 30}, "Add recipe") {
				draft = draft_from_recipe(Recipe{}, true)
				mode = .Editing
				form_error = ""
			}
		}

		// Filtered list, case-insensitive on the title, like
		// the Rust version. Filtering never changes the
		// selection, so the detail keeps showing the selected
		// recipe even when it is filtered out. The predicate
		// lives in src/search.odin so it can be unit-tested.
		filtered := make([dynamic]int, context.temp_allocator)
		for recipe, i in recipes {
			if title_matches_query(recipe.title, buf_str(search_buf[:])) {
				append(&filtered, i)
			}
		}
		// Panels follow the outer window size, keeping the
		// original proportions at 900x600: a fixed 280px
		// list column, a 10px gap, and the detail panel
		// taking the rest. Everything inside the panels
		// already derives from the panel size, so no other
		// layout code changes.
		list_panel := rl.Rectangle{10, 110, 280, f32(rl.GetScreenHeight() - 120)}
		list_view: rl.Rectangle
		list_content := rl.Rectangle{0, 0, list_panel.width - 20, f32(len(filtered) * 40)}
		rl.GuiScrollPanel(list_panel, "", list_content, &list_scroll, &list_view)
		rl.BeginScissorMode(i32(list_view.x), i32(list_view.y), i32(list_view.width), i32(list_view.height))
		for idx, i in filtered {
			recipe := &recipes[idx]
			row_x := list_view.x + list_scroll.x
			row_y := list_view.y + list_scroll.y + f32(i * 40)
			if recipe.id == selected_id {
				rl.DrawRectangle(i32(row_x), i32(row_y), i32(list_view.width), 40, rl.LIGHTGRAY)
			}
			if recipe.image_path != "" {
				entry := image_ensure(recipe.image_path)
				switch entry.state {
				case .Ready:
					dest := fit_rect(int(entry.texture.width), int(entry.texture.height), row_x + 4, row_y + 4, 32, 32)
					rl.DrawTexturePro(entry.texture, {0, 0, f32(entry.texture.width), f32(entry.texture.height)}, dest, {0, 0}, 0, rl.WHITE)
				case .Loading:
					draw_spinner(row_x + 20, row_y + 20, 12, rl.DARKGRAY)
				case .Failed:
				// Like the Rust list: no thumbnail on failure.
				}
			}
			if mode == .Editing {
				draw_text(row_x + 42, row_y + 10, FONT_BODY, rl.BLACK, recipe.title)
			} else if rl.GuiLabelButton({row_x + 42, row_y + 5, list_view.width - 46, 30}, strings.clone_to_cstring(recipe.title, context.temp_allocator)) {
				selected_id = recipe.id
				confirming_delete = false
			}
		}
		rl.EndScissorMode()

		// List/detail transition: restart whenever the
		// selection changes, including the first recipe at
		// startup. Progress is eased ease-out cubic, like the
		// Rust version; raylib redraws every frame at 60fps,
		// so no explicit repaint request is needed.
		now := rl.GetTime()
		if detail_anim_for != selected_id {
			detail_anim_for = selected_id
			detail_anim_start = now
		}
		t := (now - detail_anim_start) / DETAIL_ANIM_SECONDS
		if t < 0 {
			t = 0
		}
		if t > 1 {
			t = 1
		}
		fade := f32(1.0 - (1.0-t)*(1.0-t)*(1.0-t))
		y_slide := (1.0 - fade) * 12.0

		// ---- Right pane: detail or edit form ----
		detail_panel := rl.Rectangle{300, 10, f32(rl.GetScreenWidth() - 310), f32(rl.GetScreenHeight() - 20)}
		if load_error != "" {
			draw_wrapped(detail_panel.x + 10, detail_panel.y + 10, detail_panel.width - 20, FONT_BODY, rl.RED, load_error)
		} else if mode == .Editing {
			content_h := form_block(false, 0, 0, detail_panel.width - 30)
			form_view: rl.Rectangle
			rl.GuiScrollPanel(detail_panel, "", {0, 0, detail_panel.width - 20, content_h}, &form_scroll, &form_view)
			rl.BeginScissorMode(i32(form_view.x), i32(form_view.y), i32(form_view.width), i32(form_view.height))
			form_block(true, form_view.x + form_scroll.x + 10, form_view.y + form_scroll.y + 10, form_view.width - 20)
			rl.EndScissorMode()
		} else if recipe := selected_recipe(); recipe != nil {
			content_h := detail_block(false, 0, 0, detail_panel.width - 30, recipe, 1, 0)
			detail_view: rl.Rectangle
			rl.GuiScrollPanel(detail_panel, "", {0, 0, detail_panel.width - 20, content_h}, &detail_scroll, &detail_view)
			rl.BeginScissorMode(i32(detail_view.x), i32(detail_view.y), i32(detail_view.width), i32(detail_view.height))
			detail_block(true, detail_view.x + detail_scroll.x + 10, detail_view.y + detail_scroll.y + 10, detail_view.width - 20, recipe, fade, y_slide)
			rl.EndScissorMode()
		} else {
			draw_text(detail_panel.x + 10, detail_panel.y + 10, FONT_BODY, rl.DARKGRAY, "No recipes yet. Add one with the button on the left.")
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
