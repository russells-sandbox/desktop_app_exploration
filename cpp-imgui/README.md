# cpp-imgui

C++ + Dear ImGui version of the recipe manager test app, with a
recipe list/detail view loaded from SQLite, add/edit/delete,
images, display animations, and network JSON import from a URL
— matching rust-egui's feature set up to and including
"network request import: recipe JSON from a URL".
Backend is SDL2 + OpenGL3.

Dear ImGui source is fetched at build time by CMake (FetchContent,
pinned to v1.93.0) and is not checked in. stb_image (for decoding
image files) is fetched the same way, shallow, from master — stb
has no release tags, so there is no version to pin to; the API
used here (`stbi_load`/`stbi_image_free`) has been stable for
years.

Recipes are stored in `recipes.db` in the current working
directory, created on first run and seeded with 3 recipes.
`recipes.db` is git-ignored, as are `build/`, `imgui.ini`, and
`images/`.

## Features

- Recipe list with title search, detail view (description,
  servings, ingredients, numbered steps, notes).
- Add/edit form: Save writes, Cancel discards, title required,
  servings must be a whole number. Ingredients and steps can be
  added and removed in the form; ingredient rows use fixed-width
  fields so the Remove buttons stay visible.
- Delete with inline confirmation ("Delete ... for good?",
  "Confirm delete" / "Keep it").
- Images: the edit form's "Choose image..." button opens a file
  picker (see below) that copies the chosen file into `images/`
  next to `recipes.db`, with a `_1`/`_2` suffix on collision.
  The detail pane shows the photo at up to 400x300, the list
  shows a 32x32 thumbnail. A missing or undecodable image shows
  an error label instead, and is not retried every frame.
- List/detail transition: when the selection changes, the detail
  pane fades in and slides up 12px over 0.25s (ease-out cubic).
  Dear ImGui has no built-in view transition, so the progress is
  tracked from the frame time and applied with style alpha plus
  a cursor offset. The app renders every frame anyway, so no
  explicit repaint request is needed.
- Image loading state: images decode on a worker thread
  (`std::thread`, one per image) and the OpenGL texture is
  created on the main thread only, from the decoded pixels. While
  an image is decoding, the detail pane shows a spinner arc with
  "Loading image..." and the list shows a 32px spinner in place
  of the thumbnail; the rest of the UI stays responsive.
- Network JSON import: the list pane has a URL field (default
  `http://localhost:8000/recipes.json`, the local test-data
  server) and an Import button. Fetching and parsing run on a
  worker thread (`json_import.cpp`, one thread per import) and
  the UI thread polls for the result each frame, inserts the
  recipes with the same `insert_recipe` the Add form uses, and
  selects the first imported recipe. While a fetch is in flight
  the button is replaced by a spinner with "Importing..."; on
  completion the list pane shows "Imported N recipe(s)." or the
  error in red. Accepted shapes, defaults, and error cases match
  rust-egui exactly (single object, bare array, or
  `{"recipes": [...]}`; missing title is an error). Only
  `http://` is supported — an `https://` URL fails with a clear
  message — because this importer uses plain POSIX sockets and
  no TLS library, same as rust-egui. The JSON parser in
  `json_import.cpp` is a small focused one for exactly these
  recipe shapes (objects, arrays, strings with escapes, numbers,
  null), not a general-purpose library; see its header for the
  trade-off.

## File picker

The picker is drawn with Dear ImGui itself (`filepicker.h`),
not a native dialog. On Linux, native dialogs (tinyfiledialogs,
zenity, kdialog) need an external helper program, and this VM
has none installed, so a native dialog would silently fall back
to terminal input and be unusable from the GUI. The built-in
picker lists directories and image files, navigates with
double-click on a folder, and confirms with the Select button
(or double-click on a file). One wrinkle: ImGui popup ids are
scoped to the current window, so the picker must be opened and
drawn from the main window — opening it from inside the detail
child (where the button lives) made it silently never appear.

## Build

Ubuntu (this VM):

```sh
./install_dependencies_ubuntu.sh
./build_linux.sh
./build/cpp-imgui
```

Fedora (not yet tested here — `install_dependencies_fedora.sh`
is the Fedora equivalent of `install_dependencies_ubuntu.sh`):

```sh
./install_dependencies_fedora.sh
./build_linux.sh
./build/cpp-imgui
```

No new system packages were needed for the features above:
stb_image is fetched by CMake, and the picker, threads,
filesystem, and socket code are all standard library / POSIX.
A fresh checkout needs only the packages
`install_dependencies_ubuntu.sh` installs (cmake, g++,
libsdl2-dev, libgl1-mesa-dev, libsqlite3-dev); the import adds
no dependency. `build/` is git-ignored.

## Tests

Unit tests for recipe data, title search, and URL JSON import
only (plain asserts, no test framework). They use a throwaway
temp database, never `recipes.db`. Encoding, UI, and end-to-end
tests are out of scope here.

```sh
# Search tests only: no SQLite/SDL/Dear ImGui needed.
g++ -std=c++17 -I. tests/test_search.cpp -o /tmp/cpp-imgui-search-tests
/tmp/cpp-imgui-search-tests

# JSON import parse/fetch tests only: no SDL/Dear ImGui needed,
# and no SQLite symbols are linked (the SQLite header is still
# needed to compile, for the Recipe struct in db.h, so this
# needs libsqlite3-dev installed, as the install script does).
g++ -std=c++17 -I. tests/test_json_import.cpp json_import.cpp -o /tmp/cpp-imgui-json-import-tests
/tmp/cpp-imgui-json-import-tests

# All test executables, once dependencies are installed:
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

To try the import against the shared fixtures by hand, start
the test-data server from the repo root's `test-data/`
(`bash run_server.sh`, port 8000 by default), run the app, and
click Import with the default URL — or point the URL field at
another fixture (`recipe-single.json`, `recipes-array.json`,
`recipe-minimal.json`, `recipes-empty.json`, `invalid.json`)
and click Import again. Stop the server with
`bash kill_server.sh` when done.

## Notes and wrinkles

- Dear ImGui's default font does not render the bullet
  character, so ingredients use `BulletText` (which draws a
  filled circle, not a glyph), and the search hint uses ASCII
  "..." instead of the ellipsis character. "Loading image..."
  likewise uses ASCII dots.
- Dear ImGui 1.93 types `ImTextureID` as an integer, not a
  pointer, so OpenGL texture ids are converted with
  `static_cast`, not `reinterpret_cast`.
- `imgui_stdlib` (from Dear ImGui's `misc/cpp`) is used so the
  form can edit `std::string` fields directly.
- Test note: instant synthetic mouse clicks (press and release
  in the same frame) are unreliable against this app at high
  frame rates, because ImGui only observes the press if it
  spans a frame boundary; holding the button briefly before
  release works reliably. This is a test-harness artifact, not
  an app bug — a real user always holds the button for tens of
  milliseconds.
