# rust-iced

Rust + Iced version of the recipe manager test app, currently
at the same point as `rust-egui/`: a 900x600 window titled
"Recipe Manager", through the "display animations: image
loading state" todo item.

Iced 0.14.0 is pinned in `Cargo.toml` (and `Cargo.lock`),
built and verified with Rust 1.99.1 on Oct 28, 2026. Rust
1.99.1 is pinned in `install_ubuntu.sh` and
`install_fedora.sh`, like the other stacks pin their
toolchains, rather than tracking the moving stable channel.

## Build

Ubuntu:

```sh
./install_ubuntu.sh
./build_linux.sh
./target/debug/rust-iced
```

Fedora (not yet tested here — `install_fedora.sh` is the Fedora
equivalent of `install_ubuntu.sh`):

```sh
./install_fedora.sh
./build_linux.sh
./target/debug/rust-iced
```

`target/`, `recipes.db`, and `images/` are git-ignored.
`recipes.db` is created in the current working directory on
first run.

## Tests

```sh
PATH=$HOME/.cargo/bin:$PATH cargo test -- --test-threads=1
```

Single-threaded because the DB and image tests switch the
process working directory to a throwaway temp directory
(the DB layer opens `recipes.db` in the current directory),
and that directory is process-wide. Tests cover recipe data
and title search only; they never touch the real
`recipes.db`.

## Recipe manager

Recipes load from SQLite (`recipes.db` in the current working
directory, git-ignored), seeded once on first run with the
same seed the other stacks use: Banana Bread, Tomato Basil
Pasta, and Chicken Stir Fry (19 ingredients, 13 steps total).
A second run loads from the database and does not re-seed.
A load failure is shown in the detail pane instead of
crashing. No prep/cook fields anywhere: they were removed
from the spec. No network yet.

- Left pane: "Recipes", a title search box, an "Add recipe"
  button, and one row per matching recipe (32x32 thumbnail
  when the recipe has an image). The selected recipe is the
  highlighted button. The search filters the list only; the
  detail keeps showing the selected recipe even if it no
  longer matches the filter. While a recipe is being edited,
  the list buttons are disabled so a click cannot discard
  the in-progress edit.
- Right pane (scrollable): detail for the selected recipe —
  description, servings, image (up to 400x300, or
  "[No image yet]", or an error line), Edit/Delete buttons,
  ingredients, numbered steps, and notes.
- Add/edit form: title (required), description, servings
  (must be a whole number), image path with a "Choose
  image…" file picker, ingredients (amount/unit/name rows
  with Add/Remove), steps (rows with Add/Remove), notes.
  Save writes to SQLite, Cancel discards. Validation and
  database errors are shown in red at the top of the form.
- Delete asks inline ("Delete … for good?" with "Confirm
  delete" / "Keep it") before removing the recipe and its
  ingredients and steps from SQLite.
- Images: picking a file copies it into `images/`
  (git-ignored), with a `_1`/`_2` suffix on collision; a file
  already inside `images/` is used as-is. A missing or
  undecodable image shows "[Image could not be loaded: …]"
  and is not retried every frame.

## Animations

- List/detail transition: when the selection changes
  (including the first recipe at startup), the detail text
  fades in while the detail slides up 12px into place, over
  0.25s with an ease-out cubic. Headings and buttons are not
  faded, only the body text. Driven by a ~16ms tick
  subscription that is only active while a transition is
  running or an image is loading.
- Image loading state: images decode on a worker thread
  (one thread per path, pixels sent back over a channel)
  and the texture handle is created on the UI thread, so a
  large image never blocks the interface. While decoding,
  the detail shows a rotating indicator plus "Loading
  image…" and the list shows the same rotating indicator
  where the thumbnail will go. Iced has no built-in spinner
  widget, so the indicator is a rotating `| / - \` character.

## Code

- `src/main.rs` — the Iced application: `iced::application`
  with `RecipeManager::new` / `update` / `view` /
  `subscription`, the message enum, the edit draft and its
  validation, the worker-thread image loading, and the
  transition animation. The theme is pinned to Light so the
  detail fade (black text with a rising alpha) reads the
  same whatever the system theme is.
- `src/db.rs` — SQLite storage via rusqlite 0.41.0
  (bundled SQLite), same schema as `rust-egui/`
  (recipes, ingredients, steps, foreign keys on). Each
  function opens its own connection; the seed is inserted
  once in a transaction only when the recipes table is
  empty.
- `src/seed.rs` — the seed data, identical to `rust-egui/`.
- `src/search.rs` — the title search predicate (case-insensitive
  substring match on the title only, empty query matches
  everything), extracted from the list in `main.rs` so it can be
  unit-tested; its tests live with it.
- `src/images.rs` — image import (copy into `images/`)
  and decoding to raw RGBA pixels (via the `image` crate:
  png/jpeg/gif/webp/bmp).

## Wrinkles

- Iced 0.14's default async backend is a thread pool whose
  time module is empty, so `iced::time::every` does not
  exist without an executor feature. This app enables the
  `tokio` feature on Iced solely so the tick subscription
  exists; no async task code is used otherwise.
- Iced's `text_input` is single-line, so the description
  and notes fields are single-line inputs (the multi-line
  `text_editor` widget would need stateful content, not a
  plain string draft). The data model is unchanged.
- The image-path field in the form is display-only: typing
  a path by hand does nothing, because no input handler is
  attached to it; the path is set by the file picker, which
  copies the file into `images/`.
- Scrollables default to scrolling in both directions,
  which gives their content an unbounded width and defeats
  text wrapping. Both panes are set to vertical-only
  scrolling, so long lines wrap inside the pane.
- The detail scroll position is kept across selection
  changes (Iced scrollables keep their offset), so after a
  delete the newly selected recipe can start scrolled down;
  scrolling up shows the top. Same behaviour as the other
  stacks' scroll areas.
- The file picker is `rfd`'s XDG desktop portal backend.
  In a plain Xvfb session with no portal service running,
  picking returns immediately with no dialog (verified
  Oct 28, 2026: clicking "Choose image…" shows no dialog
  and the app stays responsive). The copy/rename logic
  itself is unit-tested. The picker needs a real desktop
  session to be exercised end to end.
- Running under Xvfb in this VM needs `libxkbcommon-x11`
  and `mesa-vulkan-drivers`, both in the install scripts:
  without them the app panics at startup ("Library
  libxkbcommon-x11.so could not be loaded"). They were
  installed from the local apt archive cache on Oct 28,
  2026, because the VM's apt index did not list them yet
  (a system package-replay process was holding the dpkg
  lock and running its own `apt-get update` at the time).
- Keyboard input from `xdotool` does not reach apps under
  Xvfb here (no window manager), so search typing was not
  exercised through the UI; the filter predicate itself is
  unit-tested in `src/search.rs`.
  Mouse clicks and wheel scrolling do work and were used
  for all other UI verification.
