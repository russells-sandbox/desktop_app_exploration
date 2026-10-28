# odin-microui

Odin + microUI version of the recipe manager test app: a recipe
manager backed by SQLite, with a left pane listing recipes with
a title search box, and a right pane showing the selected
recipe's detail (description, servings, photo, ingredients,
numbered steps, notes). Add, edit, and delete work through a
microUI form in the detail pane, images load asynchronously
with a loading state, and changing the selection fades/slides
the detail pane in — matching the Rust version's state up to
"display animations: image loading state".

microUI ships with Odin itself as `vendor:microui`, and it does
no drawing itself: it measures text and emits draw commands, and
`src/main.odin` renders those commands with raylib
(`vendor:raylib`, whose prebuilt Linux library ships with Odin
too, and whose default font is used, so no font file is needed).
The raylib window starts at 900x600, titled "Recipe Manager",
matching the Rust version's window size, and is resizable
(minimum 640x480); the panes follow the window size, snapping
back to the default layout when the outer window is resized
(they can still be dragged and resized individually afterwards).

## UI

- **Recipes pane** (left): a search box, then one button per
  recipe whose title contains the search text, case-insensitively
  (empty search shows all). The selected recipe is marked with
  a `> ` prefix. Filtering the list does not change the
  selection, so the detail pane keeps showing the selected recipe
  even when it is filtered out, like the Rust version.
- **Detail pane** (right): title, description, servings,
  photo (or "[No image yet]", or an error for a failed image),
  Edit and Delete buttons, ingredients, numbered steps, notes.
  Long description, step and note text is wrapped by hand in
  `src/main.odin` (`draw_wrapped`, using raylib's MeasureText),
  because microUI's own text wrapping did not line up with
  raylib's default-font measurements and clipped long lines.
  Panes can be dragged and resized; their close buttons are
  disabled so a pane cannot be lost by clicking its X. Content
  taller than a pane scrolls with the mouse wheel (the wheel
  direction is negated in `src/main.odin`: raylib reports
  wheel-up as positive, but a positive microUI scroll delta
  moves content up, so without the negation wheel-down did
  nothing at the top of a pane and wheel-up scrolled the wrong
  way).
- **Add recipe**: the "Add recipe" button in the Recipes pane
  (hidden while editing) opens a form in the detail pane.
- **Edit recipe**: the detail pane's Edit button opens the same
  form filled with the selected recipe. Title is required and
  servings must be a whole number; failures show an error label
  at the top of the form and do not save, like the Rust
  version. Save writes to SQLite (insert for a new recipe,
  update for an existing one, children deleted and re-inserted
  in one transaction); Cancel discards the draft. Description
  and notes are single-line textboxes: microUI has no multi-line
  textbox, unlike egui. Selection is by id, so editing keeps
  the selection on the same recipe.
- **Delete recipe**: the detail pane's Delete button asks
  "Delete this recipe?" inline, with "Confirm delete" and
  "Cancel". Confirming deletes the recipe and its ingredients
  and steps in one transaction and selects the first remaining
  recipe (or none, if the list is empty).
- **Form layout notes**: microUI textboxes edit a buffer plus
  a length, and a textbox's id derives from its buffer address,
  so the draft keeps one fixed buffer per field (and per
  ingredient/step row). Repeated "Remove" labels would share
  one microUI id, so each ingredient/step row wraps its widgets
  in `push_id`/`pop_id` with the row index.
- **Data**: on first run the app creates `recipes.db` in the
  current working directory and seeds it once from
  `src/recipes.odin` — the same data as the Rust version's seed
  (Banana Bread, Tomato Basil Pasta, Chicken Stir Fry, 19
  ingredients, 13 steps total). Later runs load from the
  database and do not re-seed. The ingredient/step arrays in
  `recipes.odin` are package-level globals that recipes hold
  slices into, deliberately: a slice literal built inside a
  procedure is backed by that procedure's stack frame in Odin,
  so building the recipes in a function corrupted them once it
  returned.

## SQLite — the wrinkle

Odin ships no SQLite package. `vendor/` has no sqlite (unlike
`vendor:microui` and `vendor:raylib`), and `core/` has no
database package, so unlike the Rust version — which uses
rusqlite with its bundled SQLite — `src/db.odin` declares the
system SQLite C API by hand and links the system library:

```odin
foreign import sqlite3 "system:sqlite3"
```

The bindings in `db.odin` cover only what this app uses:
`sqlite3_open`, `sqlite3_close`, `sqlite3_exec`,
`sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_finalize`,
`sqlite3_column_text`/`_int`/`_int64`/`_type`,
`sqlite3_bind_text`/`_int64`/`_null`, `sqlite3_errmsg`,
`sqlite3_last_insert_rowid`, and `sqlite3_free`. Strings bound
with `SQLITE_STATIC` (a nil destructor) are heap-allocated
and live until after the step, which is all that binding
requires.

Consequences, compared with the Rust version:

- **The build needs the development package, not just the
  runtime library.** `libsqlite3-dev` on Ubuntu (and
  `sqlite-devel` on Fedora) provides the `libsqlite3.so`
  symlink and `sqlite3.h` header that linking needs; the
  runtime package alone (`libsqlite3-0`) lets a built binary
  run but not link.
- **The binary depends on the system SQLite at runtime.**
  Check with `ldd odin-microui`: it links `libsqlite3.so`,
  whereas the Rust binary's SQLite is statically bundled.
- **Schema matches Rust** (`rust-egui/src/db.rs`): recipes
  (id, title, description, servings, image_path, notes), ingredients (id, recipe_id,
  position, amount, unit, name), steps (id, recipe_id, position,
  text), foreign keys on. Seed recipes are inserted with a
  NULL `image_path`, as in Rust, until the image step sets it.
- **One connection for the app's lifetime**, closed when
  `main` returns. Rust opens a new connection per operation
  to keep borrowing simple; Odin has no borrowing rules to
  work around, so one connection is simpler here.
- **A load failure is shown, not fatal.** If opening,
  seeding, or loading fails, the detail pane shows
  "Database error:" plus the message, like the Rust version.
- `recipes.db` is git-ignored and never pushed.

Not yet: any network/JSON work (deferred by Russell's decision
— JSON import/export is on hold pending decisions he wants to
make later), CPU/memory profiling, or Windows/macOS builds.

Odin dev-2026-10 is pinned in `install_ubuntu.sh` and
`install_fedora.sh`.

## Images

microUI has no image widget and its draw commands are only
rect/text/icon/clip, so images are drawn by raylib, not microUI:
during the microUI frame the code reserves space with
`layout_row` + `layout_next` and records a draw record (texture,
rectangle, and the pane's clip rect from `get_clip_rect`); after
the microUI command loop, raylib draws each record with
`DrawTexturePro` inside `BeginScissorMode`/`EndScissorMode` with
the recorded clip, so a texture never draws outside its pane or
past scrolled content. The detail photo is scaled to at most
400x300, aspect preserved (smaller images are shown at native
size); the list thumbnail is a second 32x32 texture, resized
from the decoded image like the Rust version's thumbnail.

- **Display** (`src/images.odin`, `src/main.odin`): a recipe
  with no image path shows "[No image yet]". A path that fails
  to decode shows "[Image could not be loaded: <path>]" and is
  remembered as failed, not retried every frame.
- **Import**: raylib has no file picker, so the edit form has
  an "Import image from file" row: type a source path and click
  Import. `import_image` copies the file into `images/`
  (created if missing, git-ignored) and sets the form's image
  path to the copy; a second import of the same filename gets
  a `_1`, `_2` suffix instead of overwriting, like the Rust
  version. An import failure shows as the form error. The
  import row uses fixed column widths (`{440, 100}`), not
  `{-1, 100}` — see the layout note below.
- **Loading state**: images decode on a worker thread
  (`core:thread`) with `vendor:stb/image` (`load_from_memory`,
  RGBA), never raylib on the worker (raylib calls are not
  thread-safe). While a decode runs, the detail pane shows a
  spinner (raylib circle outline plus a rotating spoke, angle
  from `GetTime()`) with "Loading image..." and the list shows
  a mini spinner in the thumbnail column; the rest of the UI
  keeps rendering and responding. When the worker finishes,
  the main thread joins it and uploads the texture with
  `LoadTextureFromImage` (detail texture at full decoded size,
  thumbnail from `ImageCopy` + `ImageResize(32, 32)`). A large
  image (tested: 8000x6000) therefore shows spinners first and
  the photo plus thumbnail once decoded.
- **stb libraries**: a fresh Odin download ships
  `vendor/stb/src/*.c` but no compiled `vendor/stb/lib/*.a`,
  and the first build then fails with "Could not find the
  compiled STB libraries". Both install scripts build them if
  missing (`vendor/stb/src/build_stb.sh`, needs only a C
  compiler, which the scripts already install); no new system
  packages were needed for the image work.

## Animations

- **List/detail transition** (0.25s, ease-out cubic
  `1.0 - (1.0-t)^3`, matching Rust): when the selection changes
  (including the first recipe at startup) and the app is not
  editing, the detail pane fades and slides up 12px into place.
  microUI's own drawing has no opacity, so the fade is a
  window-background overlay (`WINDOW_BG` colour with alpha
  `(1.0-eased)*255`) drawn over the detail pane's rectangle in
  the raylib pass, fading opaque to transparent, which dims
  the detail text and the detail photo together. The slide
  moves the detail pane's window rectangle y by
  `(1.0-eased)*12` and restores it exactly when the transition
  ends, so it applies only while the transition runs and later
  user dragging is unaffected. The rectangle move happens
  after `mu.end`, not before `mu.begin`: calling
  `get_container` before the first `begin` trips microUI's pool
  assertion (`n > -1` in `pool_init`), because before frame 1
  no pool item satisfies `last_update < frame`. The one-frame
  slide lag this causes is invisible on the trigger frame,
  because the fade overlay is fully opaque then.
- **Image loading state**: see Images above (spinner plus
  "Loading image..." while the worker thread decodes).

## microUI layout notes (learned the hard way)

- **A `-1` width means "fill the body from here", not
  "remaining space after the fixed columns."** So `{-1, 100}`
  gives the first widget the full body width and pushes the
  second widget off-screen past the clip (this hid the Import
  button, and would have hidden the ingredient/step Remove
  buttons). `-1` only works as the LAST column (as in the
  list's `{32, -1}`). Multi-column rows here therefore use
  fixed widths (`{440, 100}` for import, `{80, 80, 250, 80}`
  for ingredients, `{440, 80}` for steps).
- **A multi-column `layout_row` keeps applying until the next
  `layout_row` call.** After the ingredient/step loops the code
  resets to `layout_row {-1}, 0` before the "Add ingredient" /
  "Add step" buttons; without the reset, the button, the next
  section label, and the following widgets all landed on one
  row in the previous row's columns.
- **Hover must precede press by a frame.** microUI sets
  `hover_id` only when the mouse is over a control and no
  button is down, and sets focus on press only if the control
  is already hovered. An atomic move-and-click in one frame
  batch (as `xdotool mousemove … click` sends) therefore
  submits to the previously hovered control, or nothing. Real
  users always hover first; automated tests must move, wait a
  frame, then press.

## Build

Ubuntu:

```sh
./install_ubuntu.sh
./build_linux.sh
./odin-microui
```

`install_ubuntu.sh` installs clang (used by Odin to link on Linux),
X11/GL development files (used by the raylib window), and Odin
dev-2026-10 to `/opt/odin`, with a wrapper at
`/usr/local/bin/odin` that sets `ODIN_ROOT=/opt/odin`. The wrapper
matters: Odin expects its `base/`, `core/` and `vendor/` folders
next to the compiler binary, so symlinking the binary alone is
not enough. Both install scripts also build the stb libraries
under `/opt/odin/vendor/stb/lib/` if they are missing (see
Images above); no new system packages beyond the ones listed
here were needed for the add/edit/delete, image, or animation
work.

Fedora (not yet tested here — `install_fedora.sh` is the Fedora
equivalent of `install_ubuntu.sh`):

```sh
./install_fedora.sh
./build_linux.sh
./odin-microui
```

The built `odin-microui` binary and `recipes.db` are git-ignored.

## Tests

Unit tests for recipe data and title search live in
`src/search_test.odin` and `src/db_test.odin` (`@(test)`
procedures, run with the Odin test runner):

```sh
odin test src
```

The search tests call the app's own `matches_search`
(`src/main.odin`) directly; the data tests use the app's DB
layer (`src/db.odin`) against throwaway databases in `/tmp`,
never the real `recipes.db`, and each test removes its file
when it finishes. No test files are included in a normal
`odin build src`.
