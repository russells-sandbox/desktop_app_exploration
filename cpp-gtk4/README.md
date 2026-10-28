# cpp-gtk4

C++ version of the recipe manager test app, using the plain GTK4
C API (via pkg-config, built with CMake and g++ — no gtkmm), the
same toolchain approach as `cpp-imgui`.

Current state: complete through "display animations: image loading
state" — the same point `rust-egui` is at. That covers: install
scripts, hello-world window, recipe list/detail, SQLite storage,
add/edit/delete, title search, images (thumbnails, detail photo,
file import), a list/detail fade transition, and asynchronous
image loading with a spinner state.

Recipes are stored in `recipes.db` in the current working directory,
created on first run and seeded with 3 recipes (19 ingredients,
13 steps). `recipes.db` and `images/` are git-ignored.

## Build

Ubuntu (this VM):

```sh
./install_dependencies_ubuntu.sh
./build_linux.sh
./build/cpp-gtk4
```

Fedora (not yet tested here — `install_dependencies_fedora.sh`
is the Fedora equivalent of `install_dependencies_ubuntu.sh`):

```sh
./install_dependencies_fedora.sh
./build_linux.sh
./build/cpp-gtk4
```

`build/` is git-ignored.

## Tests

Recipe-data and search unit tests only (no encoding, UI,
network, or end-to-end tests). Plain check mains, no test
framework. The DB tests use a throwaway database under `/tmp`
and never open the real `recipes.db`.

```sh
cmake -S . -B build
cmake --build build --target cpp-gtk4-test-search cpp-gtk4-test-db
./build/cpp-gtk4-test-search
./build/cpp-gtk4-test-db
```

The search test links nothing but `search.h`, so it also builds
without GTK or SQLite installed:

```sh
g++ -std=c++17 -Wall -Wextra test_search.cpp -o /tmp/test_search
/tmp/test_search
```

## How it works

- `db.cpp` / `db.h` — SQLite storage via the system SQLite3 C API.
  Foreign keys are on, so deleting a recipe cascades to its
  ingredients and steps. The seed is inserted once, in a
  transaction, only when the recipes table is empty.
- `seed.cpp` / `seed.h` — the seed recipes, kept separate from the
  database code the way `rust-egui` does it.
- `images.cpp` / `images.h` — importing copies a chosen file into
  `images/`, with a `_1`, `_2` suffix on filename collision.
- `main.cpp` — the GTK4 UI. The list is a `GtkListBox` with a
  `GtkSearchEntry` filter; the detail pane is rebuilt on selection
  change and fades in over 0.25s (ease-out cubic) via a GLib
  timeout stepping the detail container's opacity.

## Stack-specific wrinkles

- Images decode on a `GThread` (GdkPixbuf loading only — no GTK
  calls off the main thread) and hand the decoded pixbuf to the
  main thread through an idle callback, which creates the
  `GdkTexture`s. While decoding, the list row shows a 32px
  `GtkSpinner` and the detail shows a spinner plus
  "Loading image…". A failed decode is remembered in a failure
  set and shows "[Image could not be loaded: …]" instead of
  being retried every frame.
- Add/edit uses a modal window (not `GtkDialog`), with dynamic
  ingredient rows (amount/unit/name) and step rows, each with a
  Remove button. Title is required; servings is a spin button,
  so it is always a whole number. Editing keeps the recipe's
  image path unchanged; images are imported from the detail
  pane's "Import image…" button, which uses the GTK 4.10+
  `GtkFileDialog` async API.
- Delete uses a small modal confirmation window, not a stock
  dialog, for the same reason as add/edit.
- The description/notes fields are `GtkTextView`s with
  accepts-tab off, so Tab moves focus to the next field instead
  of inserting a tab character (the default would trap
  keyboard-only users in those fields).
- The add/edit window scrolls: with several ingredient/step rows
  the Save/Cancel buttons fall below the fold and must be
  scrolled into view. That is the scrolled window working as
  intended, not a layout bug.
- The detail fade applies to the detail container only, not to
  the window, so the list stays fully opaque during the
  transition.
- Pictures are pinned to their texture size with
  `gtk_widget_set_size_request`: without this, the
  box/scrolled-window layout shrinks the detail photo (a
  400x300 texture rendered at 76x57 in testing).
- Image loads refresh the list and detail panes when they
  start, not just when they finish: the panes are built
  before the loads start at startup, so without that refresh
  the spinner state would never display.
- GTK deprecation note: `GtkDialog` and `GtkFileChooserDialog`
  are deprecated in GTK 4.10+; this stack avoids both (custom
  windows, `GtkFileDialog`).
