// Dear ImGui recipe manager, using SDL2 + OpenGL3 as the backend.
// SDL is the windowing/drawing backend here; Dear ImGui is the UI layer.
//
// Recipes are loaded from SQLite (recipes.db in the current
// working directory), seeded on first run. See db.h / db.cpp.
//
// Features, matching rust-egui: recipe list with title search,
// detail view, add/edit form (Save writes, Cancel discards, title
// required, servings must be a whole number), delete with inline
// confirmation, images (list thumbnails, detail photo, import via
// a file picker that copies into images/), a list/detail
// transition (detail fades and slides in over ~0.25s when the
// selection changes), asynchronous image loading (decoding on a
// worker thread, spinner while loading, error state on failure),
// and network JSON import from a URL (fetch and parse on a
// worker thread, spinner while in flight, success/error message
// in the list pane).
//
// Notes on the Dear ImGui default font: it does not render the
// bullet character, so ingredients use BulletText (which draws a
// filled circle, not a glyph), and the search hint uses ASCII
// "..." instead of the ellipsis character.

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <SDL.h>
#include <SDL_opengl.h>

#include "db.h"
#include "filepicker.h"
#include "json_import.h"
#include "search.h"
#include "images.h"
#include "imgui.h"
#include "imgui_stdlib.h"
#include "imgui_impl_opengl3.h"
#include "imgui_impl_sdl2.h"

namespace {

// How long a list/detail transition takes, in seconds.
const double kDetailAnimSeconds = 0.25;

std::string trim(const std::string& text) {
    size_t first = 0;
    while (first < text.size() &&
           std::isspace(static_cast<unsigned char>(text[first]))) {
        ++first;
    }
    size_t last = text.size();
    while (last > first &&
           std::isspace(static_cast<unsigned char>(text[last - 1]))) {
        --last;
    }
    return text.substr(first, last - first);
}

// The form edits this, not the Recipe in the list. Save converts it
// back to a Recipe (validating the fields); Cancel discards it.
struct EditDraft {
    long long id = 0;
    std::string title;
    std::string description;
    std::string servings_text;
    std::string image_path;
    std::vector<Ingredient> ingredients;
    std::vector<std::string> steps;
    std::string notes;

    static EditDraft from_recipe(const Recipe& recipe) {
        EditDraft draft;
        draft.id = recipe.id;
        draft.title = recipe.title;
        draft.description = recipe.description;
        draft.servings_text = std::to_string(recipe.servings);
        draft.image_path = recipe.image_path;
        draft.ingredients = recipe.ingredients;
        draft.steps = recipe.steps;
        draft.notes = recipe.notes;
        return draft;
    }

    static EditDraft empty() { return EditDraft(); }

    // Returns false (with error set) when validation fails:
    // title is required, servings must be a whole number.
    bool to_recipe(Recipe& out, std::string& error) const {
        std::string trimmed_title = trim(title);
        if (trimmed_title.empty()) {
            error = "Title is required.";
            return false;
        }
        std::string trimmed_servings = trim(servings_text);
        // A whole number: optional sign, then digits only, all of
        // them (so "8.0" and "8 servings" are rejected, as in
        // rust-egui's integer parse).
        size_t digits_begin = 0;
        if (digits_begin < trimmed_servings.size() &&
            (trimmed_servings[digits_begin] == '+' ||
             trimmed_servings[digits_begin] == '-')) {
            ++digits_begin;
        }
        bool whole_number =
            digits_begin < trimmed_servings.size() &&
            std::all_of(trimmed_servings.begin() + static_cast<long>(digits_begin),
                        trimmed_servings.end(), [](unsigned char c) {
                            return std::isdigit(c) != 0;
                        });
        long long servings = 0;
        if (whole_number) {
            try {
                size_t used = 0;
                servings = std::stoll(trimmed_servings, &used);
                whole_number = used == trimmed_servings.size();
            } catch (...) {
                whole_number = false;
            }
        }
        if (!whole_number) {
            error = "Servings must be a whole number.";
            return false;
        }
        out.id = id;
        out.title = trimmed_title;
        out.description = description;
        out.servings = static_cast<int>(servings);
        out.image_path = trim(image_path);
        out.ingredients = ingredients;
        out.steps = steps;
        out.notes = notes;
        return true;
    }
};

int find_recipe_index(const std::vector<Recipe>& recipes, long long id) {
    for (int i = 0; i < static_cast<int>(recipes.size()); ++i) {
        if (recipes[i].id == id) {
            return i;
        }
    }
    return -1;
}

// A URL import in flight. The fetch and parse run on a worker
// thread (like image decoding), which fills this in and sets
// done under the mutex; the main thread collects it each frame
// below, without blocking, and does the database inserts
// itself. The job is shared with the worker thread, so a
// detached thread can outlive the frame that started it without
// touching freed memory; only the result and flags live in the
// job, never a pointer back to the app state.
struct ImportJob {
    std::mutex mutex;
    bool done = false;
    bool ok = false;
    std::vector<Recipe> recipes;
    std::string error;
};

}  // namespace

int main(int, char**) {
    // Load from SQLite first. On failure the app still opens and
    // shows the error in the detail pane instead of crashing.
    std::vector<Recipe> recipes;
    std::string db_error;
    sqlite3* db = nullptr;
    if (!open_database("recipes.db", &db, db_error) ||
        !init_and_seed(db, db_error) || !load_recipes(db, recipes, db_error)) {
        if (db != nullptr) {
            sqlite3_close(db);
            db = nullptr;
        }
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        if (db != nullptr) {
            sqlite3_close(db);
        }
        return 1;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    SDL_Window* window = SDL_CreateWindow(
        "Recipe Manager", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 900, 600,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN);
    if (window == nullptr) {
        if (db != nullptr) {
            sqlite3_close(db);
        }
        SDL_Quit();
        return 1;
    }

    SDL_GLContext gl_context = SDL_GL_CreateContext(window);
    SDL_GL_MakeCurrent(window, gl_context);
    SDL_GL_SetSwapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplSDL2_InitForOpenGL(window, gl_context);
    ImGui_ImplOpenGL3_Init("#version 130");

    // Reloads recipes from the database after a save or delete.
    auto reload_recipes = [&]() {
        std::string error;
        if (db != nullptr && !load_recipes(db, recipes, error)) {
            db_error = error;
        }
    };

    long long selected_id = recipes.empty() ? -1 : recipes[0].id;
    std::string search;
    bool editing = false;
    bool is_new = false;
    EditDraft draft;
    std::string form_error;
    std::string detail_error;
    bool confirming_delete = false;
    FilePicker picker;
    ImageLoader loader;
    // URL import state. The URL field defaults to the local
    // test-data server, as in rust-egui. import_job is non-null
    // while a fetch is in flight; import_message/import_error
    // hold the last finished import's status.
    std::string import_url = "http://localhost:8000/recipes.json";
    std::string import_message;
    std::string import_error;
    std::shared_ptr<ImportJob> import_job;
    // Set when "Choose image..." is clicked in the form. The picker
    // popup must be opened from the main window (see below), not
    // from inside the detail child where the button lives.
    bool open_picker = false;

    // List/detail transition state: which recipe the current fade
    // is for, and the time it started at. Dear ImGui has no
    // built-in view transition, so the progress is tracked here
    // from the frame time and restarted whenever the selection
    // changes (including the first recipe shown at startup).
    // -1 means no transition has started yet.
    long long detail_anim_for = -1;
    double detail_anim_start = 0.0;

    bool running = true;
    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) {
                running = false;
            }
        }

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui::NewFrame();

        // Advance image loading: turn finished decodes into
        // textures, and start decoding any recipe image that is
        // not already cached, failed, or loading.
        loader.poll();
        for (const Recipe& recipe : recipes) {
            if (!recipe.image_path.empty()) {
                loader.request(recipe.image_path);
            }
        }

        // Collect a finished URL import, if any, without
        // blocking: the worker thread already fetched and
        // parsed, so this step is just the database inserts,
        // using the same insert_recipe the Add form uses. A
        // failed insert stops the import, leaving any recipes
        // already inserted in place (as in rust-egui), and the
        // selection only moves when every insert succeeded.
        // Runs before drawing, so reload_recipes cannot dangle
        // the recipe reference the detail pane uses below.
        if (import_job != nullptr) {
            bool done = false;
            bool ok = false;
            std::vector<Recipe> imported;
            std::string import_job_error;
            {
                std::lock_guard<std::mutex> lock(import_job->mutex);
                done = import_job->done;
                ok = import_job->ok;
                imported = import_job->recipes;
                import_job_error = import_job->error;
            }
            if (done) {
                import_job = nullptr;
                if (!ok) {
                    import_error = import_job_error;
                    import_message.clear();
                } else if (db == nullptr) {
                    import_error = "No database open.";
                    import_message.clear();
                } else {
                    long long first_imported_id = 0;
                    bool insert_ok = true;
                    for (const Recipe& recipe : imported) {
                        long long new_id = 0;
                        std::string error;
                        if (!insert_recipe(db, recipe, new_id, error)) {
                            import_error = error;
                            import_message.clear();
                            insert_ok = false;
                            break;
                        }
                        if (first_imported_id == 0) {
                            first_imported_id = new_id;
                        }
                    }
                    reload_recipes();
                    if (insert_ok) {
                        if (first_imported_id != 0) {
                            selected_id = first_imported_id;
                        }
                        import_message =
                            imported.size() == 1
                                ? "Imported 1 recipe."
                                : "Imported " + std::to_string(imported.size()) +
                                      " recipes.";
                        import_error.clear();
                    }
                }
            }
        }

        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize, ImGuiCond_Always);
        ImGui::Begin("Recipe Manager", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                         ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse);

        ImGui::BeginChild("RecipeList", ImVec2(250, 0), true);
        ImGui::Text("Recipes");
        ImGui::Text("Search recipes:");
        ImGui::InputTextWithHint("##search", "Type to filter recipes...", &search);
        // Capture the editing state up front: clicking "Add recipe"
        // sets editing below, and EndDisabled must only run when
        // BeginDisabled ran this frame.
        bool list_disabled = editing;
        if (list_disabled) {
            ImGui::BeginDisabled();
        }
        if (ImGui::Button("Add recipe") && !editing) {
            draft = EditDraft::empty();
            is_new = true;
            editing = true;
            form_error.clear();
        }
        if (list_disabled) {
            ImGui::EndDisabled();
        }
        ImGui::Separator();
        const float now = static_cast<float>(ImGui::GetTime());
        const ImU32 spinner_color = ImGui::GetColorU32(ImGuiCol_Text);
        ImGui::Text("Import from URL:");
        ImGui::InputTextWithHint("##importurl", "http://localhost:8000/recipes.json",
                                 &import_url);
        if (import_job != nullptr) {
            // Spinner + text, like rust-egui's Spinner with
            // "Importing..." beside it. The button is replaced
            // while a fetch is in flight, so a second import
            // cannot start on top of the first.
            ImVec2 cursor = ImGui::GetCursorScreenPos();
            ImGui::Dummy(ImVec2(20.0f, 20.0f));
            draw_spinner(ImGui::GetWindowDrawList(), cursor.x + 10.0f,
                         cursor.y + 10.0f, 8.0f, now, spinner_color);
            ImGui::SameLine();
            ImGui::Text("Importing...");
        } else {
            // Disabled while editing, as in rust-egui: starting
            // an import must not race an in-progress edit.
            bool import_disabled = editing;
            if (import_disabled) {
                ImGui::BeginDisabled();
            }
            if (ImGui::Button("Import")) {
                // Fetch and parse on a worker thread; the poll
                // above collects the result. A previous message
                // or error is cleared so the spinner is the only
                // status shown while the fetch is in flight.
                import_message.clear();
                import_error.clear();
                auto job = std::make_shared<ImportJob>();
                import_job = job;
                std::string url = import_url;
                std::thread([job, url]() {
                    std::vector<Recipe> recipes;
                    std::string error;
                    bool ok = fetch_and_parse(url, recipes, error);
                    std::lock_guard<std::mutex> lock(job->mutex);
                    job->done = true;
                    job->ok = ok;
                    job->recipes = std::move(recipes);
                    job->error = std::move(error);
                }).detach();
            }
            if (import_disabled) {
                ImGui::EndDisabled();
            }
        }
        if (!import_message.empty()) {
            ImGui::Text("%s", import_message.c_str());
        }
        if (!import_error.empty()) {
            ImGui::TextColored(ImVec4(1.0f, 0.3f, 0.3f, 1.0f), "%s",
                               import_error.c_str());
        }
        ImGui::Separator();
        for (const Recipe& recipe : recipes) {
            if (!recipe_title_matches_search(recipe.title, search)) {
                continue;
            }
            // List thumbnail: the image at 32x32 (aspect-preserving
            // fit), a spinner while it is still decoding, nothing
            // for a failed image or a recipe with no image.
            if (!recipe.image_path.empty()) {
                ImageLoader::State state = loader.state(recipe.image_path);
                if (state == ImageLoader::State::Ready) {
                    int width = 0;
                    int height = 0;
                    if (loader.texture_size(recipe.image_path, width, height)) {
                        float draw_width = 0.0f;
                        float draw_height = 0.0f;
                        fit_image_size(width, height, 32.0f, 32.0f, draw_width, draw_height);
                        ImGui::Image(
                            static_cast<ImTextureID>(loader.texture(recipe.image_path)),
                            ImVec2(draw_width, draw_height));
                        ImGui::SameLine();
                    }
                } else if (state == ImageLoader::State::Loading) {
                    ImGui::Dummy(ImVec2(32.0f, 32.0f));
                    ImVec2 min = ImGui::GetItemRectMin();
                    ImVec2 max = ImGui::GetItemRectMax();
                    draw_spinner(ImGui::GetWindowDrawList(), (min.x + max.x) * 0.5f,
                                 (min.y + max.y) * 0.5f, 12.0f, now, spinner_color);
                    ImGui::SameLine();
                }
            }
            if (editing) {
                // Don't let a list click discard an in-progress edit.
                ImGui::Text("%s", recipe.title.c_str());
            } else if (ImGui::Selectable(recipe.title.c_str(), selected_id == recipe.id)) {
                selected_id = recipe.id;
                confirming_delete = false;
                detail_error.clear();
            }
        }
        ImGui::EndChild();

        ImGui::SameLine();

        ImGui::BeginChild("RecipeDetail", ImVec2(0, 0), true);
        if (!db_error.empty()) {
            ImGui::Text("Database error:");
            ImGui::TextWrapped("%s", db_error.c_str());
        } else if (editing) {
            // The edit form takes over the whole detail pane.
            ImGui::Text("%s", is_new ? "Add recipe" : "Edit recipe");
            if (!form_error.empty()) {
                ImGui::TextColored(ImVec4(1.0f, 0.3f, 0.3f, 1.0f), "%s",
                                   form_error.c_str());
            }
            ImGui::Text("Title:");
            ImGui::InputText("##title", &draft.title);
            ImGui::Text("Description:");
            ImGui::InputTextMultiline("##description", &draft.description,
                                      ImVec2(0, 60));
            ImGui::Text("Servings:");
            ImGui::InputText("##servings", &draft.servings_text);
            ImGui::Text("Image path:");
            ImGui::InputText("##imagepath", &draft.image_path);
            ImGui::SameLine();
            if (ImGui::Button("Choose image...")) {
                open_picker = true;
            }
            ImGui::Separator();

            ImGui::Text("Ingredients");
            int remove_ingredient = -1;
            for (int i = 0; i < static_cast<int>(draft.ingredients.size()); ++i) {
                ImGui::PushID(i);
                // Fixed-width rows, so the Remove button stays
                // visible however long the name field gets.
                ImGui::SetNextItemWidth(50);
                ImGui::InputText("##amount", &draft.ingredients[i].amount);
                ImGui::SameLine();
                ImGui::SetNextItemWidth(50);
                ImGui::InputText("##unit", &draft.ingredients[i].unit);
                ImGui::SameLine();
                ImGui::SetNextItemWidth(200);
                ImGui::InputText("##name", &draft.ingredients[i].name);
                ImGui::SameLine();
                if (ImGui::Button("Remove")) {
                    remove_ingredient = i;
                }
                ImGui::PopID();
            }
            if (remove_ingredient >= 0) {
                draft.ingredients.erase(draft.ingredients.begin() + remove_ingredient);
            }
            if (ImGui::Button("Add ingredient")) {
                draft.ingredients.push_back(Ingredient());
            }
            ImGui::Separator();

            ImGui::Text("Steps");
            int remove_step = -1;
            for (int i = 0; i < static_cast<int>(draft.steps.size()); ++i) {
                ImGui::PushID(i);
                ImGui::SetNextItemWidth(400);
                ImGui::InputText("##step", &draft.steps[i]);
                ImGui::SameLine();
                if (ImGui::Button("Remove")) {
                    remove_step = i;
                }
                ImGui::PopID();
            }
            if (remove_step >= 0) {
                draft.steps.erase(draft.steps.begin() + remove_step);
            }
            if (ImGui::Button("Add step")) {
                draft.steps.push_back(std::string());
            }
            ImGui::Separator();

            ImGui::Text("Notes:");
            ImGui::InputTextMultiline("##notes", &draft.notes, ImVec2(0, 60));
            ImGui::Separator();

            bool saved = false;
            if (ImGui::Button("Save")) {
                Recipe recipe;
                std::string error;
                if (!draft.to_recipe(recipe, error)) {
                    form_error = error;
                } else if (db == nullptr) {
                    form_error = "No database open.";
                } else {
                    bool ok = false;
                    if (is_new) {
                        long long new_id = 0;
                        ok = insert_recipe(db, recipe, new_id, error);
                        if (ok) {
                            recipe.id = new_id;
                        }
                    } else {
                        ok = update_recipe(db, recipe, error);
                    }
                    if (ok) {
                        reload_recipes();
                        selected_id = recipe.id;
                        form_error.clear();
                        saved = true;
                    } else {
                        form_error = error;
                    }
                }
            }
            ImGui::SameLine();
            if (ImGui::Button("Cancel")) {
                form_error.clear();
                saved = true;
            }
            if (saved) {
                editing = false;
            }
        } else {
            int index = find_recipe_index(recipes, selected_id);
            if (index < 0) {
                ImGui::Text("No recipe selected.");
            } else {
                const Recipe& recipe = recipes[index];

                // List/detail transition progress, 0.0 (just
                // changed) to 1.0 (settled), eased so it starts
                // fast and slows into place. Restarted whenever
                // the selection changes. The app renders every
                // frame anyway, so no explicit repaint request is
                // needed to keep the animation moving.
                double time_now = ImGui::GetTime();
                if (detail_anim_for != selected_id) {
                    detail_anim_for = selected_id;
                    detail_anim_start = time_now;
                }
                double raw =
                    (time_now - detail_anim_start) / kDetailAnimSeconds;
                double progress = raw < 0.0 ? 0.0 : (raw > 1.0 ? 1.0 : raw);
                double eased = 1.0 - std::pow(1.0 - progress, 3.0);
                float fade = static_cast<float>(eased);

                ImGui::PushStyleVar(ImGuiStyleVar_Alpha, fade);
                // Slide up into place: 12px offset, shrinking to
                // 0 as the detail fades in.
                ImGui::SetCursorPosY(ImGui::GetCursorPosY() +
                                     static_cast<float>(1.0 - eased) * 12.0f);

                ImGui::Text("%s", recipe.title.c_str());
                ImGui::TextWrapped("%s", recipe.description.c_str());
                ImGui::Text("Servings: %d", recipe.servings);
                ImGui::Separator();
                if (recipe.image_path.empty()) {
                    ImGui::Text("[No image yet]");
                } else {
                    ImageLoader::State state = loader.state(recipe.image_path);
                    if (state == ImageLoader::State::Ready) {
                        int width = 0;
                        int height = 0;
                        if (loader.texture_size(recipe.image_path, width, height)) {
                            float draw_width = 0.0f;
                            float draw_height = 0.0f;
                            fit_image_size(width, height, 400.0f, 300.0f,
                                           draw_width, draw_height);
                            ImGui::Image(
                                static_cast<ImTextureID>(loader.texture(recipe.image_path)),
                                ImVec2(draw_width, draw_height));
                        }
                    } else if (state == ImageLoader::State::Loading) {
                        // Spinner + text, like rust-egui's Spinner
                        // with "Loading image..." beside it.
                        ImVec2 cursor = ImGui::GetCursorScreenPos();
                        ImGui::Dummy(ImVec2(20.0f, 20.0f));
                        draw_spinner(ImGui::GetWindowDrawList(), cursor.x + 10.0f,
                                     cursor.y + 10.0f, 8.0f, now, spinner_color);
                        ImGui::SameLine();
                        ImGui::Text("Loading image...");
                    } else {
                        ImGui::Text("[Image could not be loaded: %s]",
                                    recipe.image_path.c_str());
                    }
                }
                ImGui::Separator();

                if (ImGui::Button("Edit")) {
                    draft = EditDraft::from_recipe(recipe);
                    is_new = false;
                    editing = true;
                    form_error.clear();
                    confirming_delete = false;
                }
                ImGui::SameLine();
                if (ImGui::Button("Delete")) {
                    confirming_delete = true;
                }
                if (!detail_error.empty()) {
                    ImGui::TextColored(ImVec4(1.0f, 0.3f, 0.3f, 1.0f), "%s",
                                       detail_error.c_str());
                }
                // Set when the delete succeeds below: reload_recipes
                // replaces the recipes vector, so the recipe
                // reference above dangles after that point and the
                // rest of the detail must not be drawn this frame.
                bool detail_gone = false;
                if (confirming_delete) {
                    ImGui::Text("Delete \"%s\" for good?", recipe.title.c_str());
                    if (ImGui::Button("Confirm delete")) {
                        std::string error;
                        if (db != nullptr && delete_recipe(db, recipe.id, error)) {
                            reload_recipes();
                            selected_id = recipes.empty() ? -1 : recipes[0].id;
                            confirming_delete = false;
                            detail_error.clear();
                            detail_gone = true;
                        } else {
                            detail_error = error;
                            confirming_delete = false;
                        }
                    }
                    ImGui::SameLine();
                    if (ImGui::Button("Keep it")) {
                        confirming_delete = false;
                    }
                }
                if (!detail_gone) {
                    ImGui::Separator();

                    ImGui::Text("Ingredients");
                    for (const Ingredient& ingredient : recipe.ingredients) {
                        if (ingredient.unit.empty()) {
                            ImGui::BulletText("%s %s", ingredient.amount.c_str(),
                                              ingredient.name.c_str());
                        } else {
                            ImGui::BulletText("%s %s %s", ingredient.amount.c_str(),
                                              ingredient.unit.c_str(),
                                              ingredient.name.c_str());
                        }
                    }
                    ImGui::Separator();

                    ImGui::Text("Steps");
                    for (int i = 0; i < static_cast<int>(recipe.steps.size()); ++i) {
                        ImGui::Text("%d. %s", i + 1, recipe.steps[i].c_str());
                    }
                    ImGui::Separator();

                    ImGui::Text("Notes");
                    ImGui::TextWrapped("%s", recipe.notes.c_str());
                }

                ImGui::PopStyleVar();
            }
        }
        ImGui::EndChild();

        // The file picker is a modal popup. It is opened and drawn
        // here, inside the main window: ImGui popup ids are scoped
        // to the current window, so opening it from inside the
        // detail child (where the button lives) and drawing it
        // from outside any window never matched, and the popup
        // silently never appeared. On confirmation, import the
        // chosen file into images/ and put the stored path in the
        // draft being edited.
        if (open_picker) {
            picker.open();
            open_picker = false;
        }
        if (picker.is_open()) {
            if (picker.draw()) {
                std::string error;
                std::string imported = import_image(picker.selected(), error);
                if (imported.empty()) {
                    form_error = error;
                } else {
                    draft.image_path = imported;
                    form_error.clear();
                }
            }
        }

        ImGui::End();

        ImGui::Render();
        glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        SDL_GL_SwapWindow(window);
    }

    loader.clear();
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
    SDL_GL_DeleteContext(gl_context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    if (db != nullptr) {
        sqlite3_close(db);
    }
    return 0;
}
