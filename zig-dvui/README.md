# zig-dvui

Zig + DVUI version of the recipe manager test app, a 900x600
window titled "Recipe Manager", at feature parity with the
Rust (egui) version through the display-animation items
plus network JSON import: list/detail views, SQLite
storage, add/edit/delete, image display and import, both
animations, and importing recipes from a URL.

DVUI's current main is tested with Zig v0.17.0, so that version
is pinned in `install_ubuntu.sh`, `install_fedora.sh`, and in
`build.zig.zon`.
The backend is SDL2 (`dvui_sdl2`): DVUI's SDL2 Zig package
builds against system X11 headers, which keeps the dependency
tree much smaller than the SDL3 backend's.

## Build

Ubuntu:

```sh
./install_ubuntu.sh
./build_linux.sh
./zig-out/bin/zig-dvui
```

`install_ubuntu.sh` installs Zig 0.17.0 to `/opt/zig` (symlinked
from `/usr/local/bin/zig`) and adds the DVUI dependency to
`build.zig.zon` with `zig fetch --save`, pinned to DVUI main at
commit `f85184497c5d231e398344d288d6626e9d6d792c` (2026-10-27).
The committed `build.zig.zon` already contains that same DVUI
entry, so on a machine with direct GitHub access the fetch in
the install script is just a re-fetch of the same pin; the
first build then also fetches DVUI's own dependencies (SDL,
translate-c, freetype, tree-sitter, svg2tvg, etc.), so it
needs network access.

Fedora (not yet tested here — `install_fedora.sh` is the Fedora
equivalent of `install_ubuntu.sh`):

```sh
./install_fedora.sh
./build_linux.sh
./zig-out/bin/zig-dvui
```

`zig-out/`, `.zig-cache/` and `zig-pkg/` are git-ignored.

## Tests

Unit tests cover recipe data, search, and network JSON
import (parsing, URL handling, chunked bodies, fetching
from a local one-shot server, and inserting into a
throwaway database) — no encoding, UI, or end-to-end
tests:

```sh
zig build test
```

Search tests also run standalone, with no dependencies:

```sh
zig test src/search.zig
```

Database and JSON-import tests run standalone too (the
JSON-import tests link the system SQLite library, since
`json_import.zig` imports `db.zig` for its Recipe type):

```sh
zig test src/db.zig -lsqlite3
zig test src/json_import.zig -lsqlite3
```

Database tests open throwaway databases in temp directories
(via the test-only `openForTest` in `src/db.zig`), never the
real `recipes.db`. Zig 0.17.0 is required, as for the build.

## Features

Recipes load from SQLite (`recipes.db` in the current working
directory, git-ignored), seeded once on first run with the
same seed the Rust and Odin versions use: Banana Bread,
Tomato Basil Pasta, and Chicken Stir Fry (19 ingredients,
13 steps total). A second run loads from the database and
does not re-seed. A load failure is shown in the detail pane
instead of crashing.

- Left pane: "Recipes", a title search box, an "Add recipe"
  button, and one row per matching recipe — a 32x32 thumbnail
  (or a spinner while its image loads) plus a button. The
  selected recipe is marked "> ". The search filters the list
  only; the detail keeps showing the selected recipe even if
  it no longer matches the filter. While the add/edit form is
  open, list rows are labels, so a list click cannot discard
  an in-progress edit.
- Right pane (scrollable): detail for the selected recipe —
  description, servings, image, ingredients, numbered steps,
  notes, and Edit / Delete buttons. Delete asks for inline
  confirmation ("Delete this recipe?" / "Yes, delete" /
  "Cancel") before deleting.
- Add/edit form (takes over the detail pane): title,
  description, servings, image path, ingredients (amount,
  unit, name, with Add/Remove rows), steps (with Add/Remove
  rows), and notes. Save writes (title required, servings
  must be a whole number) and selects the saved recipe;
  Cancel discards. Rows are capped at 32 ingredients and 32
  steps — plenty for a test app, and it keeps the form on
  fixed buffers (see below).
- Images: the detail photo is shown up to 400x300, the list
  thumbnail at 32x32. A missing or undecodable image shows
  "[Image could not be loaded: …]" in the detail pane (and
  nothing in the list) and is not retried every frame.
- Image import: DVUI has no native file picker, so the form
  has an "Import image from file" row — a source-path text
  field plus an Import button. Import copies the file into
  `images/` (git-ignored, next to `recipes.db`), never
  overwriting: a second import of the same filename gets a
  `_1`, `_2` suffix, as in the Rust version. The stored copy's
  path is then filled into the image-path field. A path can
  also just be typed into the image-path field directly.
- List/detail transition: the detail pane fades in over
  0.25s (ease-out cubic) whenever the selection changes,
  using DVUI's `AnimateWidget` (kind `.alpha`). DVUI's
  animator has no kind that slides content (its `.vertical`
  kind grows the height instead), so this stack fades without
  the Rust version's 12px slide-up.
- Image loading state: images decode on a worker thread
  (`src/imageloader.zig`) and show a spinner while loading —
  a 32px spinner in the list row and a spinner plus "Loading
  image…" in the detail pane — so the UI stays responsive
  while a large image loads. The texture itself is created on
  the main thread, from the decoded pixels.
- Network JSON import: the left pane has an "Import from
  URL" field (defaulting to the local test-data server,
  `http://localhost:8000/recipes.json`, as in rust-egui)
  and an Import button. Fetching and parsing run on a
  worker thread (`src/json_import.zig`, same pattern as the
  image loader), with a spinner plus "Importing…" while in
  flight; the main thread inserts the results through
  `db.zig`, selects the first imported recipe, and shows
  "Imported N recipe(s)." — or the error message on
  failure. Accepted shapes are a single recipe object, a
  bare array, or `{"recipes": [...]}` (see
  `test-data/README.md`); http:// only, no TLS, matching
  rust-egui, including its chunked-body and redirect
  handling. While the add/edit form is open the Import
  button is hidden, so a click cannot discard an
  in-progress edit.

## Code

- `src/main.zig` — a minimal `dvui.App`: `dvui_app` with
  `frameFn = appFrame`, which draws the two-pane recipe UI
  above. `main`, `panic` and the log function are all
  DVUI's App-provided ones. The search text, selection,
  mode, and edit draft are the mutable frame state; the
  recipes themselves come from `db.zig`.
- `src/search.zig` — the recipe-list search predicate
  (case-insensitive substring match on the title only),
  extracted from `main.zig` so it can be tested without
  DVUI, plus its unit tests.
- `src/db.zig` — SQLite storage via the system SQLite C API
  (declared by hand with `extern fn`, since Zig 0.17 removed
  `@cImport`; linked with `linkSystemLibrary("sqlite3")` on
  the root module in `build.zig`, so the build needs
  libsqlite3-dev on Ubuntu / sqlite-devel on Fedora).
  Schema matches the Rust and Odin versions (recipes,
  ingredients, steps, foreign keys on). Loading is lazy, once,
  on the first frame; one connection is held for the app's
  lifetime. `insertRecipe`, `updateRecipe`, and `deleteRecipe`
  run in transactions (children are deleted and re-inserted
  on update, since the schema has no ON DELETE CASCADE);
  callers `reload()` afterwards.
- `src/images.zig` — image import: copies a file into
  `images/` with `_1`/`_2` suffixes on collision, mirroring
  `rust-egui/src/images.rs`.
- `src/json_import.zig` — network JSON import from a URL,
  mirroring `rust-egui/src/json_import.rs`: std.json parsing
  (shapes and defaults as above, walked by hand from a
  `std.json.Value` so a missing title is a distinct error),
  a plain std TCP http:// client via `std.Io.net` (no new
  dependency, no TLS, chunked bodies, up to 3 redirects,
  non-200 is an error naming the status), and a worker
  thread plus a main-thread poll that inserts through
  `db.zig`. Timeouts do NOT match rust-egui's 10s/30s:
  this Zig release's Threaded Io panics on a non-none
  connect timeout ("TODO implement netConnectIpPosix
  with timeout"), and reads have no timeout knob at all,
  so a dead or stalled server blocks only the worker
  thread until the OS times out — never the UI. No
  timeout is faked: the comment in `fetchOnce` says so.
- `src/imageloader.zig` — asynchronous image loading. One
  worker thread per image path decodes with stb_image (the
  same decoder DVUI uses, via `dvui.c.stbi_load_from_memory`)
  and reports through a mutex-guarded slot; the main thread
  polls each frame, copies finished pixels into the
  app-lifetime arena, and remembers failures. Decoded pixels
  are shown with `dvui.image`'s `.pixels` source, whose
  texture cache keys on the pixel pointer — the arena copy
  keeps that pointer stable across frames.
- `build.zig` — `b.dependency("dvui", .{ .backend = .sdl2 })`
  and imports `dvui_dep.module("dvui_sdl2")` as `"dvui"`.

## DVUI wrinkles

- Text entries own fixed buffers: a `textEntry` with
  `.text = .{ .buffer = buf }` reads the buffer (up to the
  first zero byte) every frame and writes edits into it, so
  the add/edit draft is a struct of fixed buffers that the
  form refills when it opens. Form texts are captured with
  `textGet()` during drawing and used by Save in the same
  frame.
- The fade animation restarts per selection because the
  `AnimateWidget`'s id carries the recipe id
  (`.id_extra = recipe.id`): a new selection is a first
  frame for a new widget id, and `AnimateWidget` starts its
  animation on its first frame.
- Ingredient amount/unit fields use default text-entry
  sizing: overriding `min_size_content` with only a width
  (height defaulting to 0) leaves the entry's text clipped
  out of view, even though `textGet()` reports it correctly
  — the box renders at row height but the text does not show.
  Found by screenshot while debugging the edit form.
- The worker thread never touches the shared arena (arena
  allocators are not thread-safe): it allocates file and
  pixel buffers from the page allocator, and the main thread
  copies finished pixels into the arena and frees the worker
  buffers. stb_image loads are reentrant; its failure-reason
  string is the only shared stb state, and it is only read on
  failure paths here.
- A directly typed image path whose file changes on disk is
  not re-decoded: the loader caches by path, and DVUI's
  `.pixels` texture cache keys on the pixel pointer. Import
  always writes a new (possibly suffixed) file, so imported
  images do not hit this.

## AI-agent VM workaround

`build_ubuntu_ai_agent_vm_hacky.sh` is VM-only and hacky: it
reproduces, with comments, everything that was needed to build
this in the author's AI-agent VM, where Zig's own fetch does not
use the egress proxy, `/tmp` is a 512M tmpfs, and the package
manager computes a different hash for the SDL 3.4.18 tarball
than the SDL3 package's manifest. It clones every DVUI
dependency with git (or downloads its tarball with curl), feeds
them to Zig's cache with local `zig fetch` calls (from a copy
without `.git` for packages with no `build.zig.zon`, or with
`.paths = .{""}`, whose local fetch would otherwise include
`.git` in the hash), builds once, patches the generated
`zig-pkg/` copy of the SDL3 zon with the package manager's
hash, and builds again. With `RUN_WINDOW=1` it also runs the
app under Xvfb and screenshots it. Do not use it on a normal
machine — use `install_ubuntu.sh` + `build_linux.sh` there.
