mod db;
mod images;
mod json_import;
mod search;
mod seed;

use iced::widget::{
    button, column, container, image, row, scrollable, text, text_input,
};
use iced::widget::image::Handle;
use iced::{
    Alignment, Color, ContentFit, Element, Length, Padding, Subscription, Task,
};
use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

#[derive(Clone)]
struct Ingredient {
    amount: String,
    unit: String,
    name: String,
}

#[derive(Clone)]
struct Recipe {
    // 0 means "not in the database yet"; a real row always has id >= 1.
    id: i64,
    title: String,
    description: String,
    servings: i64,
    image_path: Option<String>,
    ingredients: Vec<Ingredient>,
    steps: Vec<String>,
    notes: String,
}

// The form edits this, not the Recipe in the list. Save converts it
// back to a Recipe (validating the number fields); Cancel discards it.
struct EditDraft {
    id: i64,
    title: String,
    description: String,
    servings_text: String,
    image_path: String,
    ingredients: Vec<Ingredient>,
    steps: Vec<String>,
    notes: String,
}

impl EditDraft {
    fn from_recipe(recipe: &Recipe) -> Self {
        EditDraft {
            id: recipe.id,
            title: recipe.title.clone(),
            description: recipe.description.clone(),
            servings_text: recipe.servings.to_string(),
            image_path: recipe.image_path.clone().unwrap_or_default(),
            ingredients: recipe.ingredients.clone(),
            steps: recipe.steps.clone(),
            notes: recipe.notes.clone(),
        }
    }

    fn empty() -> Self {
        EditDraft {
            id: 0,
            title: String::new(),
            description: String::new(),
            servings_text: String::new(),
            image_path: String::new(),
            ingredients: Vec::new(),
            steps: Vec::new(),
            notes: String::new(),
        }
    }

    // Returns Err(message) instead of a Recipe when validation fails.
    fn to_recipe(&self) -> Result<Recipe, String> {
        let title = self.title.trim();
        if title.is_empty() {
            return Err("Title is required.".to_string());
        }
        let parse_number = |text: &str, field: &str| -> Result<i64, String> {
            text.trim()
                .parse::<i64>()
                .map_err(|_| format!("{} must be a whole number.", field))
        };
        Ok(Recipe {
            id: self.id,
            title: title.to_string(),
            description: self.description.clone(),
            servings: parse_number(&self.servings_text, "Servings")?,
            image_path: {
                let path = self.image_path.trim();
                if path.is_empty() {
                    None
                } else {
                    Some(path.to_string())
                }
            },
            ingredients: self.ingredients.clone(),
            steps: self.steps.clone(),
            notes: self.notes.clone(),
        })
    }
}

enum Mode {
    Viewing,
    Editing { draft: EditDraft, is_new: bool },
}

#[derive(Debug, Clone)]
enum Message {
    SearchChanged(String),
    RecipeSelected(i64),
    AddClicked,
    EditClicked,
    DeleteClicked,
    ConfirmDeleteClicked,
    CancelDeleteClicked,
    SaveClicked,
    CancelEditClicked,
    ChooseImageClicked,
    DraftTitleChanged(String),
    DraftDescriptionChanged(String),
    DraftServingsChanged(String),
    DraftNotesChanged(String),
    DraftIngredientAmountChanged(usize, String),
    DraftIngredientUnitChanged(usize, String),
    DraftIngredientNameChanged(usize, String),
    DraftStepChanged(usize, String),
    ImportUrlChanged(String),
    ImportClicked,
    ImportFileClicked,
    AddIngredientClicked,
    RemoveIngredientClicked(usize),
    AddStepClicked,
    RemoveStepClicked(usize),
    // Fires about every 16ms while an animation is running or an
    // image is loading; drives both, and polls finished decodes.
    // The instant itself is not used: progress is computed from
    // the animation start time in view().
    Tick,
}

// How long a list/detail transition takes, in seconds.
const DETAIL_ANIM_SECONDS: f32 = 0.25;

// Frames of the list/detail spinner, cycled on every tick while an
// image is loading. Iced has no built-in spinner widget, so the
// loading indicator is this rotating character plus "Loading image…".
const SPINNER_FRAMES: [&str; 4] = ["|", "/", "-", "\\"];

struct RecipeManager {
    recipes: Vec<Recipe>,
    selected_id: Option<i64>,
    search: String,
    load_error: Option<String>,
    mode: Mode,
    form_error: Option<String>,
    detail_error: Option<String>,
    confirming_delete: bool,
    // Decoded image cache, keyed by image path. Images are never
    // evicted in this version; fine for a small test app.
    image_handles: HashMap<String, Handle>,
    image_failures: HashSet<String>,
    // Images still decoding on a worker thread, keyed by image path.
    // Decoding runs off the UI thread, so a large image never blocks
    // the interface: while a path is in this map, the list and detail
    // panes show a loading indicator for it instead of an image.
    pending_images: HashMap<String, Receiver<Result<(u32, u32, Vec<u8>), String>>>,
    // List/detail transition state: which recipe the current slide
    // is for, and when it started. Progress is computed in view()
    // from the elapsed time, and restarted whenever the selection
    // changes (including the first recipe shown at startup).
    detail_anim_start: Option<Instant>,
    detail_anim_for: Option<i64>,
    // Increments on every tick; picks the current spinner frame.
    spinner_frame: usize,
    // URL import, same shape as rust-egui's: the URL text field,
    // a finished-or-failed result waiting on a worker thread, and
    // the last success or error message shown under the button.
    // Fetching and parsing run on the worker thread, so a slow
    // server never blocks the UI; the inserts happen on the UI
    // thread when the result is collected (see poll_imports).
    import_url: String,
    pending_import: Option<Receiver<Result<Vec<Recipe>, String>>>,
    import_message: Option<String>,
    import_error: Option<String>,
}

impl RecipeManager {
    fn new() -> Self {
        let (recipes, load_error) = match db::load_recipes() {
            Ok(recipes) => (recipes, None),
            Err(err) => (Vec::new(), Some(err.to_string())),
        };
        let selected_id = recipes.first().map(|recipe| recipe.id);
        let mut app = RecipeManager {
            recipes,
            selected_id,
            search: String::new(),
            load_error,
            mode: Mode::Viewing,
            form_error: None,
            detail_error: None,
            confirming_delete: false,
            image_handles: HashMap::new(),
            image_failures: HashSet::new(),
            pending_images: HashMap::new(),
            detail_anim_start: None,
            detail_anim_for: None,
            spinner_frame: 0,
            import_url: "http://localhost:8000/recipes.json".to_string(),
            pending_import: None,
            import_message: None,
            import_error: None,
        };
        // The first recipe shown at startup animates in, like a
        // selection change does.
        if let Some(id) = app.selected_id {
            app.detail_anim_for = Some(id);
            app.detail_anim_start = Some(Instant::now());
        }
        app.start_image_loads();
        app
    }

    fn selected_recipe(&self) -> Option<&Recipe> {
        let id = self.selected_id?;
        self.recipes.iter().find(|recipe| recipe.id == id)
    }

    fn editing(&self) -> bool {
        matches!(self.mode, Mode::Editing { .. })
    }

    fn spinner_char(&self) -> &'static str {
        SPINNER_FRAMES[self.spinner_frame % SPINNER_FRAMES.len()]
    }

    // Start decoding every recipe image that is not already cached,
    // failed, or loading. Decoding happens on a worker thread; the
    // UI thread only turns finished pixels into an image handle
    // (see poll_image_loads), because handle creation must happen
    // on the UI thread.
    fn start_image_loads(&mut self) {
        let image_paths: Vec<String> = self
            .recipes
            .iter()
            .filter_map(|recipe| recipe.image_path.clone())
            .collect();
        for path in image_paths {
            if self.image_handles.contains_key(&path)
                || self.image_failures.contains(&path)
                || self.pending_images.contains_key(&path)
            {
                continue;
            }
            let (sender, receiver) = channel();
            let thread_path = path.clone();
            std::thread::spawn(move || {
                // The receiver may be gone if the app closed; ignore that.
                let _ = sender.send(images::decode_image(&thread_path));
            });
            self.pending_images.insert(path, receiver);
        }
    }

    // Collect any decodes that have finished (without blocking:
    // try_recv only) and turn them into image handles. A path that
    // fails decoding is remembered as a failure, so it is not
    // retried every frame.
    fn poll_image_loads(&mut self) {
        // Collect finished decodes first, so the map is not mutated
        // while it is being polled.
        let mut finished: Vec<(String, Result<(u32, u32, Vec<u8>), String>)> = Vec::new();
        for (path, receiver) in self.pending_images.iter() {
            match receiver.try_recv() {
                Ok(result) => finished.push((path.clone(), result)),
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    finished.push((
                        path.clone(),
                        Err("Image decoding failed.".to_string()),
                    ));
                }
            }
        }
        for (path, result) in finished {
            self.pending_images.remove(&path);
            match result {
                Ok((width, height, pixels)) => {
                    let handle = Handle::from_rgba(width, height, pixels);
                    self.image_handles.insert(path, handle);
                }
                Err(_) => {
                    self.image_failures.insert(path);
                }
            }
        }
    }

    // Collect a finished URL import, if any, without blocking:
    // try_recv only. The worker thread already fetched and parsed,
    // so this step is just the database inserts, using the same
    // db::insert_recipe the Add form uses. A failed insert stops
    // the import, leaving any recipes already inserted in place.
    // The first imported recipe becomes the selected recipe, so
    // the import is visible in the detail pane right away.
    fn poll_imports(&mut self) {
        let Some(receiver) = &self.pending_import else {
            return;
        };
        let result = match receiver.try_recv() {
            Ok(result) => result,
            Err(std::sync::mpsc::TryRecvError::Empty) => return,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                Err("Import failed.".to_string())
            }
        };
        self.pending_import = None;
        match result {
            Ok(recipes) => {
                let total = recipes.len();
                let mut first_imported_id: Option<i64> = None;
                for mut recipe in recipes {
                    match db::insert_recipe(&recipe) {
                        Ok(id) => {
                            recipe.id = id;
                            if first_imported_id.is_none() {
                                first_imported_id = Some(id);
                            }
                            self.recipes.push(recipe);
                        }
                        Err(err) => {
                            self.import_error = Some(err.to_string());
                            self.import_message = None;
                            return;
                        }
                    }
                }
                if let Some(id) = first_imported_id {
                    self.selected_id = Some(id);
                    self.detail_anim_for = Some(id);
                    self.detail_anim_start = Some(Instant::now());
                }
                self.import_message = Some(if total == 1 {
                    "Imported 1 recipe.".to_string()
                } else {
                    format!("Imported {} recipes.", total)
                });
                self.import_error = None;
            }
            Err(err) => {
                self.import_error = Some(err);
                self.import_message = None;
            }
        }
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::SearchChanged(search) => {
                self.search = search;
            }
            Message::RecipeSelected(id) => {
                // Don't let a list click discard an in-progress edit.
                if !self.editing() {
                    self.selected_id = Some(id);
                    self.confirming_delete = false;
                    self.detail_error = None;
                    self.detail_anim_for = Some(id);
                    self.detail_anim_start = Some(Instant::now());
                }
            }
            Message::AddClicked => {
                if !self.editing() {
                    self.mode = Mode::Editing {
                        draft: EditDraft::empty(),
                        is_new: true,
                    };
                    self.form_error = None;
                }
            }
            Message::EditClicked => {
                if let Some(recipe) = self.selected_recipe().cloned() {
                    self.mode = Mode::Editing {
                        draft: EditDraft::from_recipe(&recipe),
                        is_new: false,
                    };
                    self.form_error = None;
                    self.confirming_delete = false;
                }
            }
            Message::DeleteClicked => {
                self.confirming_delete = true;
            }
            Message::CancelDeleteClicked => {
                self.confirming_delete = false;
            }
            Message::ConfirmDeleteClicked => {
                if let Some(id) = self.selected_id {
                    match db::delete_recipe(id) {
                        Ok(()) => {
                            self.recipes.retain(|recipe| recipe.id != id);
                            self.selected_id = self.recipes.first().map(|recipe| recipe.id);
                            self.confirming_delete = false;
                            self.detail_error = None;
                            if let Some(id) = self.selected_id {
                                self.detail_anim_for = Some(id);
                                self.detail_anim_start = Some(Instant::now());
                            }
                        }
                        Err(err) => {
                            self.detail_error = Some(err.to_string());
                            self.confirming_delete = false;
                        }
                    }
                }
            }
            Message::SaveClicked => {
                let outcome = match &self.mode {
                    Mode::Editing { draft, is_new } => {
                        Some((draft.to_recipe(), *is_new))
                    }
                    _ => None,
                };
                if let Some((result, is_new)) = outcome {
                    match result {
                        Ok(recipe) => {
                            let saved = if is_new {
                                db::insert_recipe(&recipe).map(|id| {
                                    let mut saved_recipe = recipe;
                                    saved_recipe.id = id;
                                    saved_recipe
                                })
                            } else {
                                db::update_recipe(&recipe).map(|_| recipe)
                            };
                            match saved {
                                Ok(recipe) => {
                                    if is_new {
                                        self.recipes.push(recipe.clone());
                                    } else if let Some(existing) = self
                                        .recipes
                                        .iter_mut()
                                        .find(|r| r.id == recipe.id)
                                    {
                                        *existing = recipe.clone();
                                    }
                                    self.selected_id = Some(recipe.id);
                                    self.form_error = None;
                                    self.mode = Mode::Viewing;
                                }
                                Err(err) => {
                                    self.form_error = Some(err.to_string());
                                }
                            }
                        }
                        Err(message) => {
                            self.form_error = Some(message);
                        }
                    }
                }
            }
            Message::CancelEditClicked => {
                self.form_error = None;
                self.mode = Mode::Viewing;
            }
            Message::ChooseImageClicked => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter(
                            "Images",
                            &["png", "jpg", "jpeg", "webp", "gif", "bmp"],
                        )
                        .pick_file()
                    {
                        match images::import_image(&path) {
                            Ok(imported) => {
                                draft.image_path = imported;
                                self.form_error = None;
                            }
                            Err(err) => {
                                self.form_error = Some(err);
                            }
                        }
                    }
                }
            }
            Message::DraftTitleChanged(value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.title = value;
                }
            }
            Message::DraftDescriptionChanged(value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.description = value;
                }
            }
            Message::DraftServingsChanged(value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.servings_text = value;
                }
            }
            Message::DraftNotesChanged(value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.notes = value;
                }
            }
            Message::DraftIngredientAmountChanged(index, value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if let Some(ingredient) = draft.ingredients.get_mut(index) {
                        ingredient.amount = value;
                    }
                }
            }
            Message::DraftIngredientUnitChanged(index, value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if let Some(ingredient) = draft.ingredients.get_mut(index) {
                        ingredient.unit = value;
                    }
                }
            }
            Message::DraftIngredientNameChanged(index, value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if let Some(ingredient) = draft.ingredients.get_mut(index) {
                        ingredient.name = value;
                    }
                }
            }
            Message::DraftStepChanged(index, value) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if let Some(step) = draft.steps.get_mut(index) {
                        *step = value;
                    }
                }
            }
            Message::AddIngredientClicked => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.ingredients.push(Ingredient {
                        amount: String::new(),
                        unit: String::new(),
                        name: String::new(),
                    });
                }
            }
            Message::RemoveIngredientClicked(index) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if index < draft.ingredients.len() {
                        draft.ingredients.remove(index);
                    }
                }
            }
            Message::AddStepClicked => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    draft.steps.push(String::new());
                }
            }
            Message::RemoveStepClicked(index) => {
                if let Mode::Editing { draft, .. } = &mut self.mode {
                    if index < draft.steps.len() {
                        draft.steps.remove(index);
                    }
                }
            }
            Message::ImportUrlChanged(url) => {
                self.import_url = url;
            }
            Message::ImportClicked => {
                // Don't let an import discard an in-progress edit,
                // and don't start a second import while one is in
                // flight. The fetch runs on a worker thread, the
                // same pattern as image decoding, and Tick collects
                // the result (see poll_imports).
                if !self.editing() && self.pending_import.is_none() {
                    let (sender, receiver) = channel();
                    let url = self.import_url.clone();
                    std::thread::spawn(move || {
                        let _ = sender.send(json_import::fetch_and_parse(&url));
                    });
                    self.pending_import = Some(receiver);
                    self.import_message = None;
                    self.import_error = None;
                }
            }
            Message::ImportFileClicked => {
                // Raw-file import: same shapes, defaults, and
                // message/error display as the URL import, and the
                // same worker-thread + poll_imports path, so
                // reading and parsing never block the UI. The file
                // dialog is the same rfd pattern the image
                // chooser uses.
                if !self.editing() && self.pending_import.is_none() {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("JSON", &["json"])
                        .pick_file()
                    {
                        let (sender, receiver) = channel();
                        std::thread::spawn(move || {
                            let _ = sender.send(json_import::import_from_file(&path));
                        });
                        self.pending_import = Some(receiver);
                        self.import_message = None;
                        self.import_error = None;
                    }
                }
            }
            Message::Tick => {
                self.spinner_frame = self.spinner_frame.wrapping_add(1);
                self.poll_image_loads();
                self.poll_imports();
            }
        }
        // Cheap, and catches any image path a save or an import just
        // introduced; paths already cached, failed, or loading are
        // skipped, so nothing is decoded twice.
        self.start_image_loads();
        Task::none()
    }

    fn subscription(&self) -> Subscription<Message> {
        let animating = self
            .detail_anim_start
            .map(|start| start.elapsed().as_secs_f32() < DETAIL_ANIM_SECONDS)
            .unwrap_or(false);
        if animating || !self.pending_images.is_empty() || self.pending_import.is_some() {
            iced::time::every(Duration::from_millis(16)).map(|_| Message::Tick)
        } else {
            Subscription::none()
        }
    }

    fn view(&self) -> Element<'_, Message> {
        let editing = self.editing();

        // Left pane: title, search, Add button, one row per match.
        let mut list = column![
            text("Recipes").size(24.0),
            text("Search recipes:").size(14.0),
            text_input("Type to filter recipes…", &self.search)
                .on_input(Message::SearchChanged)
                .padding(8.0),
            button("Add recipe").on_press_maybe(if editing {
                None
            } else {
                Some(Message::AddClicked)
            }),
        ]
        .spacing(8.0);
        // URL import, below the Add button and above the list:
        // a URL field (defaulting to the local test-data server),
        // an Import button, an "Import from file…" button, a
        // loading indicator while in flight, and the last success
        // or error message.
        list = list.push(text("Import from URL:").size(14.0));
        list = list.push(
            text_input("http://localhost:8000/recipes.json", &self.import_url)
                .on_input(Message::ImportUrlChanged)
                .padding(8.0),
        );
        if self.pending_import.is_some() {
            list = list.push(
                row![
                    text(self.spinner_char()).size(20.0),
                    text("Importing…"),
                ]
                .spacing(8.0)
                .align_y(Alignment::Center),
            );
        } else {
            list = list.push(button("Import").on_press_maybe(if editing {
                None
            } else {
                Some(Message::ImportClicked)
            }));
            list = list.push(button("Import from file…").on_press_maybe(
                if editing {
                    None
                } else {
                    Some(Message::ImportFileClicked)
                },
            ));
        }
        if let Some(message) = &self.import_message {
            list = list.push(text(message.as_str()));
        }
        if let Some(error) = &self.import_error {
            list = list.push(text(error.as_str()).color(Color {
                r: 0.8,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            }));
        }
        for recipe in self.recipes.iter() {
            if !search::recipe_matches_search(&recipe.title, &self.search) {
                continue;
            }
            let thumbnail: Element<Message> =
                if let Some(handle) = recipe
                    .image_path
                    .as_ref()
                    .and_then(|path| self.image_handles.get(path))
                {
                    image(handle.clone())
                        .width(Length::Fixed(32.0))
                        .height(Length::Fixed(32.0))
                        .into()
                } else if recipe
                    .image_path
                    .as_ref()
                    .map_or(false, |path| self.pending_images.contains_key(path))
                {
                    text(self.spinner_char()).size(20.0).into()
                } else {
                    text("").into()
                };
            let selected = self.selected_id == Some(recipe.id);
            let title_button = button(text(recipe.title.as_str()))
                .on_press_maybe(if editing {
                    None
                } else {
                    Some(Message::RecipeSelected(recipe.id))
                })
                .style(if selected {
                    button::primary
                } else {
                    button::text
                })
                .width(Length::Fill);
            list = list.push(
                row![thumbnail, title_button]
                    .spacing(8.0)
                    .align_y(Alignment::Center),
            );
        }
        let list_pane = container(
            scrollable(list)
                .direction(iced::widget::scrollable::Direction::Vertical(Default::default()))
                .height(Length::Fill),
        )
            .width(Length::Fixed(280.0))
            .height(Length::Fill)
            .padding(10.0);

        // Right pane: either the edit form or the selected detail.
        let detail: Element<Message> = if let Some(error) = &self.load_error {
            column![
                text("Could not load recipes").size(24.0),
                text(error.as_str()),
            ]
            .spacing(8.0)
            .into()
        } else if let Mode::Editing { draft, is_new } = &self.mode {
            self.edit_view(draft, *is_new)
        } else if let Some(recipe) = self.selected_recipe() {
            self.detail_view(recipe)
        } else {
            text("No recipe selected.").into()
        };
        let detail_pane = container(
            scrollable(detail)
                .direction(iced::widget::scrollable::Direction::Vertical(Default::default()))
                .height(Length::Fill),
        )
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(10.0);

        row![list_pane, detail_pane]
            .height(Length::Fill)
            .into()
    }

    // List/detail transition progress, 0.0 (just changed) to 1.0
    // (settled), eased so it starts fast and slows into place.
    // The detail slides up into place (12px, shrinking to 0) while
    // its text fades in (alpha rising to 1). Ticks keep the view
    // re-rendering while the transition runs; Iced otherwise only
    // re-renders on input, and the animation would freeze on its
    // first frame.
    fn detail_progress(&self) -> f32 {
        match self.detail_anim_start {
            Some(start) => {
                let t = (start.elapsed().as_secs_f32() / DETAIL_ANIM_SECONDS)
                    .clamp(0.0, 1.0);
                1.0 - (1.0 - t).powi(3) // ease-out cubic
            }
            None => 1.0,
        }
    }

    // Detail text in the transition's current fade. The app pins
    // the Light theme (see main), so black text with a rising
    // alpha is the fade-in, whatever the system theme is.
    fn faded(&self, content: &str) -> iced::widget::Text<'_, iced::Theme> {
        let alpha = self.detail_progress();
        text(content.to_string())
            .color(Color {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: alpha,
            })
    }

    fn detail_view(&self, recipe: &Recipe) -> Element<'_, Message> {
        let progress = self.detail_progress();
        let slide = (1.0 - progress) * 12.0;

        let image_block: Element<Message> =
            if let Some(path) = &recipe.image_path {
                if let Some(handle) = self.image_handles.get(path) {
                    image(handle.clone())
                        .width(Length::Fixed(400.0))
                        .height(Length::Fixed(300.0))
                        .content_fit(ContentFit::Contain)
                        .into()
                } else if self.pending_images.contains_key(path) {
                    row![
                        text(self.spinner_char()).size(20.0),
                        text("Loading image…"),
                    ]
                    .spacing(8.0)
                    .align_y(Alignment::Center)
                    .into()
                } else if self.image_failures.contains(path) {
                    text(format!("[Image could not be loaded: {}]", path)).into()
                } else {
                    text("[No image yet]").into()
                }
            } else {
                text("[No image yet]").into()
            };

        let mut detail = column![
            self.faded(&recipe.title).size(24.0),
            self.faded(&recipe.description),
            self.faded(&format!("Servings: {}", recipe.servings)),
            image_block,
            row![
                button("Edit").on_press(Message::EditClicked),
                button("Delete").on_press(Message::DeleteClicked),
            ]
            .spacing(8.0),
        ]
        .spacing(8.0);
        if let Some(error) = &self.detail_error {
            detail = detail.push(
                text(error.as_str()).color(Color {
                    r: 0.8,
                    g: 0.0,
                    b: 0.0,
                    a: 1.0,
                }),
            );
        }
        if self.confirming_delete {
            detail = detail.push(text(format!(
                "Delete \"{}\" for good?",
                recipe.title
            )));
            detail = detail.push(
                row![
                    button("Confirm delete").on_press(Message::ConfirmDeleteClicked),
                    button("Keep it").on_press(Message::CancelDeleteClicked),
                ]
                .spacing(8.0),
            );
        }
        detail = detail.push(text("Ingredients").size(20.0));
        for ingredient in &recipe.ingredients {
            if ingredient.unit.is_empty() {
                detail = detail.push(self.faded(&format!(
                    "• {} {}",
                    ingredient.amount, ingredient.name
                )));
            } else {
                detail = detail.push(self.faded(&format!(
                    "• {} {} {}",
                    ingredient.amount, ingredient.unit, ingredient.name
                )));
            }
        }
        detail = detail.push(text("Steps").size(20.0));
        for (index, step) in recipe.steps.iter().enumerate() {
            detail = detail.push(self.faded(&format!("{}. {}", index + 1, step)));
        }
        detail = detail.push(text("Notes").size(20.0));
        detail = detail.push(self.faded(&recipe.notes));

        // The slide: top padding that shrinks to 0 as the fade
        // completes. Applies to the viewing detail only, not the
        // edit form.
        container(detail)
            .width(Length::Fill)
            .padding(Padding {
                top: slide,
                right: 0.0,
                bottom: 0.0,
                left: 0.0,
            })
            .into()
    }

    fn edit_view(&self, draft: &EditDraft, is_new: bool) -> Element<'_, Message> {
        let mut form = column![
            text(if is_new { "Add recipe" } else { "Edit recipe" }).size(24.0),
        ]
        .spacing(8.0);
        if let Some(error) = &self.form_error {
            form = form.push(text(error.as_str()).color(Color {
                r: 0.8,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            }));
        }
        form = form.push(text("Title:"));
        form = form.push(
            text_input("Title", &draft.title).on_input(Message::DraftTitleChanged),
        );
        form = form.push(text("Description:"));
        form = form.push(
            text_input("Description", &draft.description)
                .on_input(Message::DraftDescriptionChanged),
        );
        form = form.push(text("Servings:"));
        form = form.push(
            text_input("Servings", &draft.servings_text)
                .on_input(Message::DraftServingsChanged),
        );
        form = form.push(text("Image path:"));
        form = form.push(
            row![
                text_input("Image path", &draft.image_path).width(Length::Fill),
                button("Choose image…").on_press(Message::ChooseImageClicked),
            ]
            .spacing(8.0),
        );
        // The image path above is display-only: typing a path by
        // hand does nothing, because no on-input handler is
        // attached to it here; the path is set by the file picker,
        // which copies the file into images/.

        form = form.push(text("Ingredients").size(20.0));
        for (index, ingredient) in draft.ingredients.iter().enumerate() {
            form = form.push(
                row![
                    text_input("Amount", &ingredient.amount)
                        .on_input(move |value| {
                            Message::DraftIngredientAmountChanged(index, value)
                        })
                        .width(Length::Fixed(60.0)),
                    text_input("Unit", &ingredient.unit)
                        .on_input(move |value| {
                            Message::DraftIngredientUnitChanged(index, value)
                        })
                        .width(Length::Fixed(60.0)),
                    text_input("Name", &ingredient.name)
                        .on_input(move |value| {
                            Message::DraftIngredientNameChanged(index, value)
                        })
                        .width(Length::Fill),
                    button("Remove")
                        .on_press(Message::RemoveIngredientClicked(index)),
                ]
                .spacing(8.0),
            );
        }
        form = form.push(button("Add ingredient").on_press(Message::AddIngredientClicked));

        form = form.push(text("Steps").size(20.0));
        for (index, step) in draft.steps.iter().enumerate() {
            form = form.push(
                row![
                    text_input("Step", step)
                        .on_input(move |value| Message::DraftStepChanged(index, value))
                        .width(Length::Fill),
                    button("Remove").on_press(Message::RemoveStepClicked(index)),
                ]
                .spacing(8.0),
            );
        }
        form = form.push(button("Add step").on_press(Message::AddStepClicked));

        form = form.push(text("Notes:"));
        form = form.push(
            text_input("Notes", &draft.notes).on_input(Message::DraftNotesChanged),
        );
        form = form.push(
            row![
                button("Save").on_press(Message::SaveClicked),
                button("Cancel").on_press(Message::CancelEditClicked),
            ]
            .spacing(8.0),
        );
        form.into()
    }
}

fn main() -> iced::Result {
    iced::application(
        RecipeManager::new,
        RecipeManager::update,
        RecipeManager::view,
    )
    .title("Recipe Manager")
    .window_size(iced::Size::new(900.0, 600.0))
    // Pinned to Light so the detail fade (black text with a
    // rising alpha) reads the same whatever the system theme is.
    .theme(iced::Theme::Light)
    .subscription(RecipeManager::subscription)
    .run()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard};

    // Same pattern as db's tests: poll_imports inserts through
    // db::insert_recipe, which opens recipes.db in the current
    // directory, so these tests run in a throwaway directory.
    // The lock serializes them; the README runs cargo test
    // single-threaded for the same reason.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    struct TempDirGuard {
        original: PathBuf,
        dir: PathBuf,
        _lock: MutexGuard<'static, ()>,
    }

    impl TempDirGuard {
        fn new(name: &str) -> Self {
            let lock = TEST_LOCK.lock().unwrap();
            let dir = env::temp_dir()
                .join(format!("recipe-import-test-{}-{}", std::process::id(), name));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let original = env::current_dir().unwrap();
            env::set_current_dir(&dir).unwrap();
            TempDirGuard {
                original,
                dir,
                _lock: lock,
            }
        }
    }

    impl Drop for TempDirGuard {
        fn drop(&mut self) {
            let _ = env::set_current_dir(&self.original);
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    // An app with no recipes and a finished import result already
    // waiting on its channel, as if the worker thread just sent it.
    fn app_with_finished_import(
        result: Result<Vec<Recipe>, String>,
    ) -> RecipeManager {
        let (sender, receiver) = channel();
        let _ = sender.send(result);
        RecipeManager {
            recipes: Vec::new(),
            selected_id: None,
            search: String::new(),
            load_error: None,
            mode: Mode::Viewing,
            form_error: None,
            detail_error: None,
            confirming_delete: false,
            image_handles: HashMap::new(),
            image_failures: HashSet::new(),
            pending_images: HashMap::new(),
            detail_anim_start: None,
            detail_anim_for: None,
            spinner_frame: 0,
            import_url: "http://localhost:8000/recipes.json".to_string(),
            pending_import: Some(receiver),
            import_message: None,
            import_error: None,
        }
    }

    #[test]
    fn poll_imports_inserts_and_reports() {
        let _guard = TempDirGuard::new("inserts");
        let imported = json_import::parse_recipes(
            r#"{"title": "Toast", "servings": 1, "steps": ["Toast it."]}"#,
        )
        .unwrap();
        let mut app = app_with_finished_import(Ok(imported));
        app.poll_imports();
        assert!(app.pending_import.is_none());
        assert_eq!(app.recipes.len(), 1);
        assert_eq!(app.recipes[0].title, "Toast");
        assert_eq!(app.selected_id, Some(app.recipes[0].id));
        assert_eq!(
            app.import_message.as_deref(),
            Some("Imported 1 recipe.")
        );
        assert!(app.import_error.is_none());
        // The insert really reached SQLite, not just the list.
        assert_eq!(db::load_recipes().unwrap().len(), 1);
    }

    #[test]
    fn poll_imports_error_reports_without_inserting() {
        let _guard = TempDirGuard::new("error");
        let mut app =
            app_with_finished_import(Err("Server returned HTTP 404.".to_string()));
        app.poll_imports();
        assert!(app.pending_import.is_none());
        assert!(app.recipes.is_empty());
        assert!(app.import_message.is_none());
        assert_eq!(
            app.import_error.as_deref(),
            Some("Server returned HTTP 404.")
        );
    }

    #[test]
    fn poll_imports_empty_collection_reports_zero() {
        let _guard = TempDirGuard::new("empty");
        let imported = json_import::parse_recipes(r#"{"recipes": []}"#).unwrap();
        let mut app = app_with_finished_import(Ok(imported));
        app.poll_imports();
        assert!(app.recipes.is_empty());
        assert!(app.selected_id.is_none());
        assert_eq!(
            app.import_message.as_deref(),
            Some("Imported 0 recipes.")
        );
        assert!(app.import_error.is_none());
    }
}
