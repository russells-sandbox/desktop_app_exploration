# todo

The same recipe-manager test app in each stack, from `README.md` and
`plan.md`. A checked box means that item is done in that project;
an unchecked box means it is still to do in that project.

The checklist is the same for every project so the stacks can be
compared like for like. The shared network-import fixture
(`test-data/recipes.json`) already exists, but no app imports it yet.

Every stack now has a Fedora install script, but none of them
has been tested on Fedora yet.

## Rust Egui (`rust-egui/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## Rust Iced (`rust-iced/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## C/C++ Dear ImGui (`cpp-imgui/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## C/C++ GTK4 (`cpp-gtk4/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## Odin Raylib + Raygui (`odin-raygui/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## Odin microui (`odin-microui/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling

## Zig DVUI (`zig-dvui/`)

- [X] install script for Ubuntu
- [X] install script for Fedora
- [X] hello world, open window
- [X] recipe view with hard-coded data
- [X] recipe view with SQLite integration
- [X] add recipe
- [X] edit recipe
- [X] delete recipe
- [X] recipe list: title, search by title
- [X] recipe detail: description, servings, ingredients, numbered steps, notes
- [X] display images (list thumbnails and detail photo)
- [X] import image from a file and store image files on disk
- [X] display animations: list/detail transitions
- [X] display animations: image loading state
- [X] network request import: recipe JSON from a URL, asynchronously, with loading and error states, without blocking the UI
- [X] raw-file import: recipes as JSON, single recipe
- [X] raw-file import: recipes as JSON, collection
- [X] raw-file export: recipes as JSON, single recipe
- [X] raw-file export: recipes as JSON, collection
- [ ] text encoding import: detect UTF-8 (with and without BOM), UTF-16LE/BE (with BOM), Windows-1252, and Shift_JIS in imported recipe JSON, parse it, and store equivalent UTF-8 in SQLite
- [ ] display complex text: Arabic, emoji, Devanagari, and Simplified Chinese in recipe titles and descriptions
- [ ] text input in add/edit forms: IME input, multiline editing, selection, undo/redo, and validation
- [ ] CPU profiling
- [ ] memory profiling
- [ ] compile time profiling
- [ ] unit tests for recipe data, search, and encoding logic
  - [X] unit tests for recipe data
  - [X] unit tests for search
  - [ ] unit tests for encoding logic
- [ ] UI tests for recipe list/detail, add, edit, and delete
  - [ ] UI test input in Arabic, Devanagari, Simplified Chinese, and emoji
- [ ] Windows build
- [ ] macOS build
- [ ] stretch: OAuth sign-in against a local mock identity provider (not a live account): system-browser flow with PKCE, redirect handling, secure token storage, and refresh/expiry handling
