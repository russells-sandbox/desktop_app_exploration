# odin-raygui

Odin + raylib/raygui version of the recipe manager test app:
a recipe view backed by SQLite, with a left pane listing
recipes with a title search box, and a right pane showing the
selected recipe's detail (description, servings, image,
ingredients, numbered steps, notes). Add, edit and delete
work through a form and an inline delete confirmation, and
images load asynchronously with a loading state.

raylib and raygui ship with Odin itself as `vendor:raylib`
(both live in that one package, so every control here is
`rl.Gui*`). The raylib window starts at 900x600, titled
"Recipe Manager", matching the Rust version's window size,
and is resizable (minimum 640x480); the list and detail
panels follow the window size. No font file is needed:
raylib's default font is used throughout.

## UI

- **Recipes pane** (left): a search box, an "Add recipe"
  button, then one row per recipe whose title contains the
  search text, case-insensitively (empty search shows all).
  Filtering the list does not change the selection, so the
  detail pane keeps showing the selected recipe even when it
  is filtered out, like the Rust version. The selected row is
  highlighted, and the list does not accept clicks while an
  edit is in progress, so a list click cannot discard a draft.
- **Detail pane** (right): title, description, servings,
  image (up to 400x300, aspect preserved), Edit and Delete
  buttons, ingredients, numbered steps, notes. Content
  taller than the pane scrolls with the mouse wheel (a
  raygui scroll panel).
- **Edit form** (replaces the detail pane): Title,
  Description, Servings, Image path, Ingredients rows
  (amount, unit, name, each with Remove), Steps rows (each
  with Remove), Notes, then Save and Cancel. Save writes
  and Cancel discards, like the Rust version. Title is
  required and servings must be a whole number, with the
  same error messages as the Rust version. Description and
  notes are single-line text boxes: raygui has no multi-line
  text box, so long text scrolls horizontally inside the box
  instead of wrapping (the stored value is unaffected).
- **List/detail transition**: when the selection changes
  (including the first recipe at startup), the detail pane
  fades in and slides up 12px over 0.25s with an ease-out
  cubic, driven by the frame time from `GetTime`. raylib
  redraws every frame at 60fps, so unlike the Rust version
  no explicit repaint request is needed to keep the
  animation moving.
- **Image loading state**: decoding runs on a worker thread
  (one per image path, see `src/images.odin`), so a large
  image never blocks the UI. While a path is decoding, the
  list shows a rotating spinner arc in the thumbnail slot
  and the detail shows a spinner plus "Loading image...".
  Once decoded, the texture is uploaded on the main thread
  and shown (detail up to 400x300, list thumbnail 32x32).
  A path that fails to decode shows "[Image could not be
  loaded: …]" in the detail (and no thumbnail in the list),
  and is not retried every frame.

## Data

On first run the app creates `recipes.db` in the current
working directory and seeds it once from `src/recipes.odin`
— the same data as the Rust version's seed (Banana Bread,
Tomato Basil Pasta, Chicken Stir Fry, 19 ingredients, 13
steps total). Later runs load from the database and do not
re-seed. The ingredient/step arrays in `src/recipes.odin`
are package-level globals that recipes hold slices into:
that matters in Odin, because a slice literal built inside
a procedure is backed by that procedure's stack frame and
corrupted data once the procedure returned (the
odin-microui stack hit exactly this and segfaulted).

There are no prep/cook fields anywhere: they were removed
from the test-app spec.

## Images

raylib has no file picker dialog, so image import works
through a text field plus an Import button in the edit
form: type (or paste) a source file path, click Import,
and the file is copied into `images/` next to `recipes.db`,
with a `_1`, `_2` suffix if that name is already taken;
the form's image path is then replaced with the stored
copy's path, so the recipe keeps working if the original
is moved. This mirrors the Rust version's
`import_image` (which gets its path from a native file
dialog instead). A path typed into the form and saved
without importing is stored as typed.

## Network JSON import

The left pane has an "Import from URL" field (defaulting
to `http://localhost:8000/recipes.json`, the local
test-data server) and an Import button. While a fetch is
in flight the button is replaced by a spinner and
"Importing..."; afterwards the pane shows "Imported N
recipe(s)." or a red error line. Imported recipes are
inserted through the existing `insert_recipe` in
`src/db.odin`, and the first imported recipe is selected.

Implementation (`src/json_import.odin`) mirrors
`rust-egui/src/json_import.rs`: the same three accepted
document shapes (a single recipe object, a bare array,
or an object with a `recipes` array), the same fields,
and the same defaults (missing description, notes,
ingredients or steps read as empty, `image_path` as null,
servings as 0; a missing or blank title is an error, and
a null optional field reads as missing). Fetching uses
only Odin's standard library — `core:net` TCP for
`http://` (no TLS, so `https://` is rejected with a clear
message, like the Rust version) and `core:encoding/json`
for parsing — with the Rust version's chunked-body
decoder and redirect handling (up to 3 redirects).
Fetching and parsing run on a worker thread and report
back through a mutex-guarded result that the main thread
polls once per frame (`import_poll`, next to
`image_poll`), following the image-loading thread pattern
in `src/images.odin`, so importing never blocks the UI.
Unlike the Rust version there are no connect/read
timeouts: `core:net` offers none for a blocking socket,
so a hung server would stall the worker thread (not the
UI) until the connection closes. The shared fixtures in
`test-data/` cover all three shapes plus the empty
collection and the invalid-JSON error case.

## SQLite — the wrinkle

Odin ships no SQLite package. `vendor/` has no sqlite
(unlike `vendor:raylib`), and `core/` has no database
package, so unlike the Rust version — which uses rusqlite
with its bundled SQLite — `src/db.odin` declares the
system SQLite C API by hand and links the system library:

    foreign import sqlite3 "system:sqlite3"

That means the build needs the system SQLite development
package, not just the runtime library: `libsqlite3-dev` on
Ubuntu (`sqlite-devel` on Fedora). The runtime library
alone (`libsqlite3-0`) lets a built binary run, but not
link, because linking needs the `libsqlite3.so` symlink
and `sqlite3.h` header that only the `-dev` package
provides. The resulting binary depends on `libsqlite3.so`
at runtime (check with `ldd`), unlike the Rust version,
whose SQLite is statically bundled.

Schema matches the Rust version (`rust-egui/src/db.rs`):
recipes (id, title, description, servings, image_path,
notes), ingredients (id, recipe_id, position, amount, unit,
name), steps (id, recipe_id, position, text), with foreign
keys on. The database file, `recipes.db`, is created in
the current working directory on first run and is
git-ignored, not pushed. One connection is held open for
the app's lifetime (single-user app, no borrowing rules to
work around in Odin) and closed when main returns — the
same choice as odin-microui, unlike the Rust version,
which opens a new connection per operation.

## Long text wrapping

raygui labels do not wrap, so long description, step and
note text is wrapped by hand in `src/main.odin`
(`wrap_lines`, using raylib's `MeasureText`) at the detail
width, the same lesson as odin-microui (whose widget
wrapping clipped long lines). Words longer than the width
are split at rune boundaries, so multi-byte characters
(like the ° in "350°F") are never split mid-sequence.

## Default-font glyphs

raylib's default font covers ASCII and Latin-1 (so the °
in "350°F" renders), but not characters outside that range:
a "•" bullet and a "…" ellipsis both rendered as "?".
Ingredient lines therefore use "- " bullets and the
loading line reads "Loading image..." with three ASCII
dots — the same class of wrinkle as the Dear ImGui stack,
whose font also lacks "•".

## Odin defers run at scope end, not function end

Unlike Go, an Odin `defer` runs when its enclosing scope
exits — so a `defer close_database(...)` placed inside the
`else` branch of the startup code closed the database as
soon as startup finished. Everything still looked fine
(recipes were already loaded into memory), but the first
add/edit/delete then failed with SQLITE_MISUSE ("bad
parameter or other API misuse") on the closed handle, with
an empty message from `sqlite3_exec`. The close defer now
lives at `main`'s scope, where it runs at program exit,
and `close_database` tolerates a nil handle for the
open-failed case. This was caught by the add-recipe UI
test, not by code review: the standalone database test
passed because its defer was at function scope.

## List rows are not GuiListView

`GuiListView` takes a single semicolon-separated string
and draws text-only rows, so it cannot show the 32x32
thumbnails the spec requires. The list here is therefore
a raygui scroll panel of rows, each with a thumbnail (or
loading spinner) drawn by raylib and a `GuiLabelButton`
for the title. Buttons, text boxes, labels and scroll
panels throughout are raygui controls.

## Build and run

Install Odin first (once per machine):

    ./install_ubuntu.sh    # Ubuntu
    ./install_fedora.sh    # Fedora (not tested on Fedora)

Then:

    ./build_linux.sh
    ./odin-raygui

Unit tests (recipe data, title search, and JSON import —
including fetching from a local one-shot server; they use
throwaway databases under the OS temp directory, never
`recipes.db`):

    odin test src -define:ODIN_TEST_TRACK_MEMORY=false

Memory tracking is off for the test run because the
existing DB layer deliberately never frees the cstrings it
allocates for SQLite binds/columns, so a tracked run logs
those pre-existing leaks at length even though all tests
pass; `odin test src` without the flag also passes.

Odin installs to `/opt/odin`, with a wrapper at
`/usr/local/bin/odin` that sets `ODIN_ROOT` (symlinking
the binary alone is not enough: Odin looks for its
library folders next to the executable it runs). Odin
uses clang to link on Linux.

## Current state

Up to and including network JSON import from a URL in
`todo.md` (past `display animations: image loading
state`): install scripts (Ubuntu, Fedora),
hello world (the window itself), recipe view with
hard-coded data (superseded by SQLite), recipe view with
SQLite integration, add recipe, edit recipe, delete
recipe, recipe list with title search, recipe detail,
display images (list thumbnails and detail photo),
import image from a file, display animations (list/detail
transitions, image loading state), network JSON import
from a URL.

Out of scope for this stack, as for the others at this
stage: network image import, raw-file JSON
import/export, CPU/memory profiling, Windows/macOS builds.
