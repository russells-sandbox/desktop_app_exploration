// Recipe Manager: C++ with the GTK4 C API (no gtkmm).
//
// Layout: 900x600 window, recipe list on the left (with title
// search), detail on the right. Data lives in recipes.db in the
// current working directory, seeded once on first run.
//
// Two behaviours that must not block the UI:
//  - List/detail transition: when the selection changes, the detail
//    pane fades in over ~0.25s (ease-out cubic), driven by a GLib
//    timeout that steps the detail container's opacity.
//  - Image loading state: images decode on a GThread. While a
//    recipe's image is decoding, the list shows a spinner in place
//    of the thumbnail and the detail shows a spinner plus
//    "Loading image…". The decoded pixels come back to the main
//    thread through an idle callback, which creates the textures
//    (texture creation, like all GTK calls, stays on the main
//    thread). A failed decode is remembered and shows an error
//    label instead of being retried every frame.

#include <gtk/gtk.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "db.h"
#include "images.h"
#include "search.h"

// How long a list/detail transition takes, in seconds.
const double DETAIL_ANIM_SECONDS = 0.25;

struct App {
    GtkApplication* app = nullptr;
    GtkWidget* window = nullptr;
    GtkWidget* list_box = nullptr;
    GtkWidget* search_entry = nullptr;
    GtkWidget* detail_box = nullptr;
    GtkWidget* image_box = nullptr;

    sqlite3* db = nullptr;
    std::vector<Recipe> recipes;
    // Indices into recipes, after applying the search filter.
    std::vector<int> filtered;
    long long selected_id = 0;
    bool has_selection = false;
    std::string search_text;
    std::string last_error;

    // Image state, keyed by image path. Textures are never evicted
    // in this version; fine for a small test app.
    std::map<std::string, GdkTexture*> detail_textures;
    std::map<std::string, GdkTexture*> thumb_textures;
    std::set<std::string> failures;
    std::set<std::string> pending;

    guint anim_timeout = 0;
    gint64 anim_start_us = 0;
    bool alive = false;
};

namespace {

std::string trimmed(const std::string& text) {
    size_t begin = 0;
    while (begin < text.size() &&
           std::isspace(static_cast<unsigned char>(text[begin]))) {
        ++begin;
    }
    size_t end = text.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(text[end - 1]))) {
        --end;
    }
    return text.substr(begin, end - begin);
}

GtkWidget* make_label(const std::string& text, bool wrap) {
    GtkWidget* label = gtk_label_new(text.c_str());
    gtk_label_set_xalign(GTK_LABEL(label), 0.0);
    gtk_label_set_wrap(GTK_LABEL(label), wrap);
    return label;
}

GtkWidget* make_heading(const std::string& text) {
    GtkWidget* label = gtk_label_new(nullptr);
    char* escaped = g_markup_escape_text(text.c_str(), -1);
    std::string markup = "<b>" + std::string(escaped) + "</b>";
    g_free(escaped);
    gtk_label_set_markup(GTK_LABEL(label), markup.c_str());
    gtk_label_set_xalign(GTK_LABEL(label), 0.0);
    return label;
}

void clear_box(GtkWidget* box) {
    GtkWidget* child = nullptr;
    while ((child = gtk_widget_get_first_child(box)) != nullptr) {
        gtk_box_remove(GTK_BOX(box), child);
    }
}

void clear_list_box(GtkWidget* list_box) {
    GtkWidget* child = nullptr;
    while ((child = gtk_widget_get_first_child(list_box)) != nullptr) {
        gtk_list_box_remove(GTK_LIST_BOX(list_box), child);
    }
}

const Recipe* find_recipe(const App* app, long long id) {
    for (const Recipe& recipe : app->recipes) {
        if (recipe.id == id) {
            return &recipe;
        }
    }
    return nullptr;
}

const Recipe* selected_recipe(const App* app) {
    if (!app->has_selection) {
        return nullptr;
    }
    return find_recipe(app, app->selected_id);
}

std::string text_view_text(GtkWidget* view) {
    GtkTextBuffer* buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    GtkTextIter start, end;
    gtk_text_buffer_get_start_iter(buffer, &start);
    gtk_text_buffer_get_end_iter(buffer, &end);
    char* text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    std::string out = text != nullptr ? text : "";
    g_free(text);
    return out;
}

void set_text_view_text(GtkWidget* view, const std::string& text) {
    GtkTextBuffer* buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    gtk_text_buffer_set_text(buffer, text.c_str(), -1);
}

GtkWidget* make_text_view(const std::string& text, int height) {
    GtkWidget* view = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD);
    // Tab moves focus to the next field instead of inserting a
    // tab character: with the default (accepts-tab), keyboard
    // users cannot Tab out of the description/notes fields at all.
    gtk_text_view_set_accepts_tab(GTK_TEXT_VIEW(view), FALSE);
    set_text_view_text(view, text);
    GtkWidget* scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), view);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_size_request(scrolled, -1, height);
    return scrolled;
}

// The text view inside the scrolled window made by make_text_view.
GtkWidget* text_view_of(GtkWidget* scrolled) {
    return gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scrolled));
}

void apply_filter(App* app) {
    app->filtered.clear();
    for (int i = 0; i < static_cast<int>(app->recipes.size()); ++i) {
        if (title_matches_search(app->recipes[i].title, app->search_text)) {
            app->filtered.push_back(i);
        }
    }
}

void start_image_loads(App* app);
void refresh_image_area(App* app);
void rebuild_list(App* app);
void refresh_detail(App* app);
void on_edit_clicked(GtkButton* button, gpointer data);
void on_delete_clicked(GtkButton* button, gpointer data);
void on_import_clicked(GtkButton* button, gpointer data);

// --- Image loading (worker thread + main-thread idle callback) ---

struct LoadJob {
    App* app;
    std::string path;
    GdkPixbuf* pixbuf = nullptr;  // Decoded full-size image, or null.
};

GdkPixbuf* scaled_pixbuf(GdkPixbuf* source, int max_width, int max_height) {
    int width = gdk_pixbuf_get_width(source);
    int height = gdk_pixbuf_get_height(source);
    double scale = std::min({1.0, max_width / static_cast<double>(width),
                             max_height / static_cast<double>(height)});
    int new_width = std::max(1, static_cast<int>(std::round(width * scale)));
    int new_height = std::max(1, static_cast<int>(std::round(height * scale)));
    return gdk_pixbuf_scale_simple(source, new_width, new_height,
                                   GDK_INTERP_BILINEAR);
}

gboolean on_image_loaded(gpointer data) {
    LoadJob* job = static_cast<LoadJob*>(data);
    App* app = job->app;
    app->pending.erase(job->path);
    if (job->pixbuf != nullptr) {
        GdkPixbuf* detail = scaled_pixbuf(job->pixbuf, 400, 300);
        GdkPixbuf* thumb = scaled_pixbuf(job->pixbuf, 32, 32);
        app->detail_textures[job->path] = gdk_texture_new_for_pixbuf(detail);
        app->thumb_textures[job->path] = gdk_texture_new_for_pixbuf(thumb);
        g_object_unref(detail);
        g_object_unref(thumb);
        g_object_unref(job->pixbuf);
    } else {
        app->failures.insert(job->path);
    }
    if (app->alive) {
        const Recipe* selected = selected_recipe(app);
        if (selected != nullptr && selected->image_path == job->path) {
            refresh_image_area(app);
        }
        rebuild_list(app);
    }
    delete job;
    return G_SOURCE_REMOVE;
}

gpointer load_thread(gpointer data) {
    LoadJob* job = static_cast<LoadJob*>(data);
    // Decoding only: no GTK calls here, so the UI thread is never
    // blocked by a large image. The result is handed to the main
    // thread through an idle callback below.
    GError* error = nullptr;
    job->pixbuf = gdk_pixbuf_new_from_file(job->path.c_str(), &error);
    if (error != nullptr) {
        g_error_free(error);
    }
    g_idle_add(on_image_loaded, job);
    return nullptr;
}

void start_image_loads(App* app) {
    bool started_any = false;
    for (const Recipe& recipe : app->recipes) {
        const std::string& path = recipe.image_path;
        if (path.empty() || app->detail_textures.count(path) > 0 ||
            app->failures.count(path) > 0 || app->pending.count(path) > 0) {
            continue;
        }
        LoadJob* job = new LoadJob{app, path, nullptr};
        GError* error = nullptr;
        GThread* thread =
            g_thread_try_new("image-load", load_thread, job, &error);
        if (thread == nullptr) {
            if (error != nullptr) {
                g_error_free(error);
            }
            delete job;
            app->failures.insert(path);
            continue;
        }
        g_thread_unref(thread);
        app->pending.insert(path);
        started_any = true;
    }
    // The detail/list panes may already have been built before
    // these loads started (at startup, and after an image import),
    // and they only show a spinner for paths in the pending set.
    // Refresh them now so the loading state appears immediately
    // instead of waiting for the next rebuild.
    if (started_any && app->image_box != nullptr) {
        refresh_image_area(app);
    }
    if (started_any && app->list_box != nullptr) {
        rebuild_list(app);
    }
}

// --- List ---

void rebuild_list(App* app) {
    clear_list_box(app->list_box);
    for (int index : app->filtered) {
        const Recipe& recipe = app->recipes[index];
        GtkWidget* row = gtk_list_box_row_new();
        GtkWidget* row_box =
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        if (!recipe.image_path.empty()) {
            auto thumb = app->thumb_textures.find(recipe.image_path);
            if (thumb != app->thumb_textures.end()) {
                GtkWidget* picture =
                    gtk_picture_new_for_paintable(GDK_PAINTABLE(thumb->second));
                // Pin the widget to the texture size: without this,
                // the box/scrolled-window layout can shrink the
                // picture well below its texture (the detail photo
                // rendered at 76x57 instead of 400x300).
                gtk_widget_set_size_request(
                    picture, gdk_texture_get_width(thumb->second),
                    gdk_texture_get_height(thumb->second));
                gtk_box_append(GTK_BOX(row_box), picture);
            } else if (app->pending.count(recipe.image_path) > 0) {
                GtkWidget* spinner = gtk_spinner_new();
                gtk_widget_set_size_request(spinner, 32, 32);
                gtk_spinner_start(GTK_SPINNER(spinner));
                gtk_box_append(GTK_BOX(row_box), spinner);
            }
            // A failed image shows no thumbnail, same as before.
        }
        GtkWidget* label = gtk_label_new(recipe.title.c_str());
        gtk_label_set_xalign(GTK_LABEL(label), 0.0);
        gtk_box_append(GTK_BOX(row_box), label);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), row_box);
        gtk_list_box_append(GTK_LIST_BOX(app->list_box), row);
        if (app->has_selection && recipe.id == app->selected_id) {
            gtk_list_box_select_row(GTK_LIST_BOX(app->list_box),
                                    GTK_LIST_BOX_ROW(row));
        }
    }
}

// --- Detail ---

void refresh_image_area(App* app) {
    clear_box(app->image_box);
    const Recipe* recipe = selected_recipe(app);
    if (recipe == nullptr || recipe->image_path.empty()) {
        gtk_box_append(GTK_BOX(app->image_box),
                       make_label("[No image yet]", false));
        return;
    }
    const std::string& path = recipe->image_path;
    auto texture = app->detail_textures.find(path);
    if (texture != app->detail_textures.end()) {
        GtkWidget* picture =
            gtk_picture_new_for_paintable(GDK_PAINTABLE(texture->second));
        // Pin the widget to the texture size (see rebuild_list:
        // otherwise the layout shrinks the photo, e.g. to 76x57
        // for a 400x300 texture, and the detail pane scrolls).
        gtk_widget_set_size_request(
            picture, gdk_texture_get_width(texture->second),
            gdk_texture_get_height(texture->second));
        gtk_box_append(GTK_BOX(app->image_box), picture);
    } else if (app->pending.count(path) > 0) {
        GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget* spinner = gtk_spinner_new();
        gtk_spinner_start(GTK_SPINNER(spinner));
        gtk_box_append(GTK_BOX(row), spinner);
        gtk_box_append(GTK_BOX(row), make_label("Loading image…", false));
        gtk_box_append(GTK_BOX(app->image_box), row);
    } else if (app->failures.count(path) > 0) {
        gtk_box_append(
            GTK_BOX(app->image_box),
            make_label("[Image could not be loaded: " + path + "]", true));
    } else {
        gtk_box_append(GTK_BOX(app->image_box),
                       make_label("[No image yet]", false));
    }
}

gboolean detail_anim_tick(gpointer data) {
    App* app = static_cast<App*>(data);
    double elapsed =
        (g_get_monotonic_time() - app->anim_start_us) / 1000000.0;
    double t = elapsed / DETAIL_ANIM_SECONDS;
    if (t >= 1.0) {
        gtk_widget_set_opacity(app->detail_box, 1.0);
        app->anim_timeout = 0;
        return G_SOURCE_REMOVE;
    }
    // Ease-out cubic: starts fast, slows into place.
    double eased = 1.0 - std::pow(1.0 - t, 3);
    gtk_widget_set_opacity(app->detail_box, eased);
    return G_SOURCE_CONTINUE;
}

void start_detail_transition(App* app) {
    if (app->anim_timeout != 0) {
        g_source_remove(app->anim_timeout);
        app->anim_timeout = 0;
    }
    gtk_widget_set_opacity(app->detail_box, 0.0);
    app->anim_start_us = g_get_monotonic_time();
    app->anim_timeout = g_timeout_add(16, detail_anim_tick, app);
}

void refresh_detail(App* app) {
    clear_box(app->detail_box);
    if (!app->last_error.empty()) {
        gtk_box_append(GTK_BOX(app->detail_box),
                       make_label(app->last_error, true));
    }
    const Recipe* recipe = selected_recipe(app);
    if (recipe == nullptr) {
        gtk_box_append(GTK_BOX(app->detail_box),
                       make_label("Select a recipe.", false));
        return;
    }

    GtkWidget* title = gtk_label_new(nullptr);
    char* escaped = g_markup_escape_text(recipe->title.c_str(), -1);
    std::string markup =
        "<big><b>" + std::string(escaped) + "</b></big>";
    g_free(escaped);
    gtk_label_set_markup(GTK_LABEL(title), markup.c_str());
    gtk_label_set_xalign(GTK_LABEL(title), 0.0);
    gtk_box_append(GTK_BOX(app->detail_box), title);
    gtk_box_append(GTK_BOX(app->detail_box),
                   make_label(recipe->description, true));
    gtk_box_append(
        GTK_BOX(app->detail_box),
        make_label("Servings: " + std::to_string(recipe->servings), false));

    // The image area is rebuilt in place by refresh_image_area,
    // so a finished load swaps the spinner for the image without
    // rebuilding the whole detail pane.
    app->image_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(app->detail_box), app->image_box);
    refresh_image_area(app);

    GtkWidget* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* edit_button = gtk_button_new_with_label("Edit");
    GtkWidget* delete_button = gtk_button_new_with_label("Delete");
    GtkWidget* import_button = gtk_button_new_with_label("Import image…");
    g_signal_connect(edit_button, "clicked", G_CALLBACK(on_edit_clicked), app);
    g_signal_connect(delete_button, "clicked", G_CALLBACK(on_delete_clicked),
                     app);
    g_signal_connect(import_button, "clicked", G_CALLBACK(on_import_clicked),
                     app);
    gtk_box_append(GTK_BOX(buttons), edit_button);
    gtk_box_append(GTK_BOX(buttons), delete_button);
    gtk_box_append(GTK_BOX(buttons), import_button);
    gtk_box_append(GTK_BOX(app->detail_box), buttons);

    gtk_box_append(GTK_BOX(app->detail_box), make_heading("Ingredients"));
    for (const Ingredient& ingredient : recipe->ingredients) {
        std::string line = "•";
        for (const std::string& part :
             {ingredient.amount, ingredient.unit, ingredient.name}) {
            if (!part.empty()) {
                line += " " + part;
            }
        }
        gtk_box_append(GTK_BOX(app->detail_box), make_label(line, true));
    }

    gtk_box_append(GTK_BOX(app->detail_box), make_heading("Steps"));
    for (size_t i = 0; i < recipe->steps.size(); ++i) {
        gtk_box_append(GTK_BOX(app->detail_box),
                       make_label(std::to_string(i + 1) + ". " + recipe->steps[i],
                                  true));
    }

    gtk_box_append(GTK_BOX(app->detail_box), make_heading("Notes"));
    gtk_box_append(GTK_BOX(app->detail_box), make_label(recipe->notes, true));
}


// --- Reload / selection ---

void select_recipe(App* app, long long id, bool animate) {
    app->selected_id = id;
    app->has_selection = true;
    refresh_detail(app);
    if (animate) {
        start_detail_transition(app);
    } else {
        gtk_widget_set_opacity(app->detail_box, 1.0);
    }
}

void reload_recipes(App* app, long long select_id, bool has_select) {
    std::string error;
    if (!load_recipes(app->db, app->recipes, error)) {
        app->last_error = "Could not load recipes: " + error;
    }
    apply_filter(app);
    if (has_select && find_recipe(app, select_id) != nullptr) {
        app->selected_id = select_id;
        app->has_selection = true;
    } else if (!app->recipes.empty()) {
        app->selected_id = app->recipes.front().id;
        app->has_selection = true;
    } else {
        app->has_selection = false;
    }
    rebuild_list(app);
    refresh_detail(app);
}

void on_row_selected(GtkListBox* /*box*/, GtkListBoxRow* row, gpointer data) {
    App* app = static_cast<App*>(data);
    if (row == nullptr) {
        return;
    }
    int index = gtk_list_box_row_get_index(row);
    if (index < 0 || index >= static_cast<int>(app->filtered.size())) {
        return;
    }
    long long id = app->recipes[app->filtered[index]].id;
    if (app->has_selection && id == app->selected_id) {
        return;
    }
    select_recipe(app, id, true);
}

void on_search_changed(GtkSearchEntry* entry, gpointer data) {
    App* app = static_cast<App*>(data);
    const char* text = gtk_editable_get_text(GTK_EDITABLE(entry));
    app->search_text = text != nullptr ? text : "";
    apply_filter(app);
    rebuild_list(app);
}

// --- Add / edit ---

struct IngredientRowWidgets {
    GtkWidget* box = nullptr;
    GtkWidget* amount = nullptr;
    GtkWidget* unit = nullptr;
    GtkWidget* name = nullptr;
};

struct StepRowWidgets {
    GtkWidget* box = nullptr;
    GtkWidget* entry = nullptr;
};

struct EditForm {
    App* app = nullptr;
    GtkWidget* window = nullptr;
    GtkWidget* title_entry = nullptr;
    GtkWidget* servings_spin = nullptr;
    GtkWidget* description_view = nullptr;
    GtkWidget* notes_view = nullptr;
    GtkWidget* error_label = nullptr;
    GtkWidget* ingredient_box = nullptr;
    GtkWidget* step_box = nullptr;
    std::vector<IngredientRowWidgets> ingredient_rows;
    std::vector<StepRowWidgets> step_rows;
    bool is_new = true;
    long long edit_id = 0;
    std::string image_path;  // Kept unchanged by editing.
};

EditForm* form_of(GtkWidget* widget) {
    GtkWidget* root = GTK_WIDGET(gtk_widget_get_root(widget));
    return static_cast<EditForm*>(g_object_get_data(G_OBJECT(root), "edit-form"));
}

void add_ingredient_row(EditForm* form, const std::string& amount,
                        const std::string& unit, const std::string& name) {
    GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* amount_entry = gtk_entry_new();
    GtkWidget* unit_entry = gtk_entry_new();
    GtkWidget* name_entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(amount_entry), amount.c_str());
    gtk_editable_set_text(GTK_EDITABLE(unit_entry), unit.c_str());
    gtk_editable_set_text(GTK_EDITABLE(name_entry), name.c_str());
    gtk_widget_set_size_request(amount_entry, 70, -1);
    gtk_widget_set_size_request(unit_entry, 70, -1);
    gtk_widget_set_hexpand(name_entry, TRUE);
    GtkWidget* remove = gtk_button_new_with_label("Remove");
    gtk_box_append(GTK_BOX(row), amount_entry);
    gtk_box_append(GTK_BOX(row), unit_entry);
    gtk_box_append(GTK_BOX(row), name_entry);
    gtk_box_append(GTK_BOX(row), remove);
    gtk_box_append(GTK_BOX(form->ingredient_box), row);
    form->ingredient_rows.push_back(
        IngredientRowWidgets{row, amount_entry, unit_entry, name_entry});
    g_signal_connect(remove, "clicked",
                     G_CALLBACK(+[](GtkButton* button, gpointer /*data*/) {
                         EditForm* form = form_of(GTK_WIDGET(button));
                         GtkWidget* row =
                             gtk_widget_get_parent(GTK_WIDGET(button));
                         auto& rows = form->ingredient_rows;
                         rows.erase(std::remove_if(rows.begin(), rows.end(),
                                                   [row](const IngredientRowWidgets& r) {
                                                       return r.box == row;
                                                   }),
                                    rows.end());
                         gtk_box_remove(GTK_BOX(form->ingredient_box), row);
                     }),
                     nullptr);
}

void add_step_row(EditForm* form, const std::string& text) {
    GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(entry), text.c_str());
    gtk_widget_set_hexpand(entry, TRUE);
    GtkWidget* remove = gtk_button_new_with_label("Remove");
    gtk_box_append(GTK_BOX(row), entry);
    gtk_box_append(GTK_BOX(row), remove);
    gtk_box_append(GTK_BOX(form->step_box), row);
    form->step_rows.push_back(StepRowWidgets{row, entry});
    g_signal_connect(remove, "clicked",
                     G_CALLBACK(+[](GtkButton* button, gpointer /*data*/) {
                         EditForm* form = form_of(GTK_WIDGET(button));
                         GtkWidget* row =
                             gtk_widget_get_parent(GTK_WIDGET(button));
                         auto& rows = form->step_rows;
                         rows.erase(std::remove_if(rows.begin(), rows.end(),
                                                   [row](const StepRowWidgets& r) {
                                                       return r.box == row;
                                                   }),
                                    rows.end());
                         gtk_box_remove(GTK_BOX(form->step_box), row);
                     }),
                     nullptr);
}

void on_edit_save(GtkButton* button, gpointer /*data*/) {
    EditForm* form = form_of(GTK_WIDGET(button));
    App* app = form->app;

    Recipe recipe;
    recipe.id = form->edit_id;
    recipe.image_path = form->image_path;
    const char* title_text =
        gtk_editable_get_text(GTK_EDITABLE(form->title_entry));
    recipe.title = trimmed(title_text != nullptr ? title_text : "");
    recipe.servings =
        gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(form->servings_spin));
    recipe.description = text_view_text(form->description_view);
    recipe.notes = text_view_text(form->notes_view);
    for (const IngredientRowWidgets& row : form->ingredient_rows) {
        Ingredient ingredient;
        const char* amount = gtk_editable_get_text(GTK_EDITABLE(row.amount));
        const char* unit = gtk_editable_get_text(GTK_EDITABLE(row.unit));
        const char* name = gtk_editable_get_text(GTK_EDITABLE(row.name));
        ingredient.amount = amount != nullptr ? amount : "";
        ingredient.unit = unit != nullptr ? unit : "";
        ingredient.name = name != nullptr ? name : "";
        recipe.ingredients.push_back(ingredient);
    }
    for (const StepRowWidgets& row : form->step_rows) {
        const char* text = gtk_editable_get_text(GTK_EDITABLE(row.entry));
        recipe.steps.push_back(text != nullptr ? text : "");
    }

    if (recipe.title.empty()) {
        gtk_label_set_text(GTK_LABEL(form->error_label),
                           "Title is required.");
        return;
    }

    std::string error;
    bool ok = false;
    long long saved_id = 0;
    if (form->is_new) {
        ok = insert_recipe(app->db, recipe, error);
        saved_id = recipe.id;
    } else {
        ok = update_recipe(app->db, recipe, error);
        saved_id = recipe.id;
    }
    if (!ok) {
        gtk_label_set_text(GTK_LABEL(form->error_label),
                           ("Could not save recipe: " + error).c_str());
        return;
    }
    app->last_error.clear();
    // Destroys the window, which deletes the form (see the destroy
    // handler in open_edit_window); do not touch form after this.
    gtk_window_destroy(GTK_WINDOW(form->window));
    reload_recipes(app, saved_id, true);
    refresh_detail(app);
}

void open_edit_window(App* app, const Recipe* recipe) {
    bool is_new = recipe == nullptr;
    EditForm* form = new EditForm();
    form->app = app;
    form->is_new = is_new;
    form->edit_id = is_new ? 0 : recipe->id;
    form->image_path = is_new ? "" : recipe->image_path;

    GtkWidget* window = gtk_window_new();
    form->window = window;
    gtk_window_set_title(GTK_WINDOW(window),
                         is_new ? "Add recipe" : "Edit recipe");
    gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(app->window));
    gtk_window_set_modal(GTK_WINDOW(window), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(window), 520, 620);
    g_object_set_data(G_OBJECT(window), "edit-form", form);
    // The destroy handler owns the form: it runs synchronously
    // inside gtk_window_destroy, so Save/Cancel just destroy the
    // window and must not touch the form afterwards.
    g_signal_connect(window, "destroy",
                     G_CALLBACK(+[](GtkWidget* /*widget*/, gpointer data) {
                         delete static_cast<EditForm*>(data);
                     }),
                     form);

    GtkWidget* scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    GtkWidget* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(content, 12);
    gtk_widget_set_margin_end(content, 12);
    gtk_widget_set_margin_top(content, 12);
    gtk_widget_set_margin_bottom(content, 12);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), content);
    gtk_window_set_child(GTK_WINDOW(window), scrolled);

    gtk_box_append(GTK_BOX(content), make_label("Title:", false));
    form->title_entry = gtk_entry_new();
    if (!is_new) {
        gtk_editable_set_text(GTK_EDITABLE(form->title_entry), recipe->title.c_str());
    }
    gtk_box_append(GTK_BOX(content), form->title_entry);

    gtk_box_append(GTK_BOX(content), make_label("Servings:", false));
    form->servings_spin = gtk_spin_button_new_with_range(1, 1000, 1);
    if (!is_new) {
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(form->servings_spin),
                                  recipe->servings);
    }
    gtk_box_append(GTK_BOX(content), form->servings_spin);

    gtk_box_append(GTK_BOX(content), make_label("Description:", false));
    GtkWidget* desc_scrolled =
        make_text_view(is_new ? "" : recipe->description, 80);
    form->description_view = text_view_of(desc_scrolled);
    gtk_box_append(GTK_BOX(content), desc_scrolled);

    gtk_box_append(GTK_BOX(content), make_heading("Ingredients"));
    form->ingredient_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(content), form->ingredient_box);
    if (!is_new) {
        for (const Ingredient& ingredient : recipe->ingredients) {
            add_ingredient_row(form, ingredient.amount, ingredient.unit,
                               ingredient.name);
        }
    }
    GtkWidget* add_ingredient = gtk_button_new_with_label("Add ingredient");
    g_signal_connect(add_ingredient, "clicked",
                     G_CALLBACK(+[](GtkButton* /*button*/, gpointer data) {
                         add_ingredient_row(static_cast<EditForm*>(data), "",
                                            "", "");
                     }),
                     form);
    gtk_box_append(GTK_BOX(content), add_ingredient);

    gtk_box_append(GTK_BOX(content), make_heading("Steps"));
    form->step_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(content), form->step_box);
    if (!is_new) {
        for (const std::string& step : recipe->steps) {
            add_step_row(form, step);
        }
    }
    GtkWidget* add_step = gtk_button_new_with_label("Add step");
    g_signal_connect(add_step, "clicked",
                     G_CALLBACK(+[](GtkButton* /*button*/, gpointer data) {
                         add_step_row(static_cast<EditForm*>(data), "");
                     }),
                     form);
    gtk_box_append(GTK_BOX(content), add_step);

    gtk_box_append(GTK_BOX(content), make_label("Notes:", false));
    GtkWidget* notes_scrolled =
        make_text_view(is_new ? "" : recipe->notes, 80);
    form->notes_view = text_view_of(notes_scrolled);
    gtk_box_append(GTK_BOX(content), notes_scrolled);

    form->error_label = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(form->error_label), 0.0);
    gtk_box_append(GTK_BOX(content), form->error_label);

    GtkWidget* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* cancel = gtk_button_new_with_label("Cancel");
    GtkWidget* save = gtk_button_new_with_label("Save");
    g_signal_connect(cancel, "clicked",
                     G_CALLBACK(+[](GtkButton* button, gpointer /*data*/) {
                         GtkWidget* root = GTK_WIDGET(gtk_widget_get_root(GTK_WIDGET(button)));
                         gtk_window_destroy(GTK_WINDOW(root));
                     }),
                     nullptr);
    g_signal_connect(save, "clicked", G_CALLBACK(on_edit_save), nullptr);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), save);
    gtk_box_append(GTK_BOX(content), buttons);

    gtk_window_present(GTK_WINDOW(window));
}

void on_add_clicked(GtkButton* /*button*/, gpointer data) {
    open_edit_window(static_cast<App*>(data), nullptr);
}

void on_edit_clicked(GtkButton* /*button*/, gpointer data) {
    App* app = static_cast<App*>(data);
    const Recipe* recipe = selected_recipe(app);
    if (recipe != nullptr) {
        open_edit_window(app, recipe);
    }
}

// --- Delete ---

void on_delete_confirm(GtkButton* button, gpointer data) {
    App* app = static_cast<App*>(data);
    GtkWidget* root = GTK_WIDGET(gtk_widget_get_root(GTK_WIDGET(button)));
    long long id = app->selected_id;
    std::string error;
    if (!delete_recipe(app->db, id, error)) {
        app->last_error = "Could not delete recipe: " + error;
    } else {
        app->last_error.clear();
    }
    gtk_window_destroy(GTK_WINDOW(root));
    reload_recipes(app, 0, false);
    refresh_detail(app);
}

void on_delete_clicked(GtkButton* /*button*/, gpointer data) {
    App* app = static_cast<App*>(data);
    const Recipe* recipe = selected_recipe(app);
    if (recipe == nullptr) {
        return;
    }
    GtkWidget* window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window), "Delete recipe");
    gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(app->window));
    gtk_window_set_modal(GTK_WINDOW(window), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(window), 360, 140);
    GtkWidget* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(content, 12);
    gtk_widget_set_margin_end(content, 12);
    gtk_widget_set_margin_top(content, 12);
    gtk_widget_set_margin_bottom(content, 12);
    gtk_window_set_child(GTK_WINDOW(window), content);
    gtk_box_append(GTK_BOX(content),
                   make_label("Delete “" + recipe->title + "”?", true));
    gtk_box_append(GTK_BOX(content),
                   make_label("This cannot be undone.", false));
    GtkWidget* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* cancel = gtk_button_new_with_label("Cancel");
    GtkWidget* confirm = gtk_button_new_with_label("Delete");
    g_signal_connect(cancel, "clicked",
                     G_CALLBACK(+[](GtkButton* button, gpointer /*data*/) {
                         GtkWidget* root = GTK_WIDGET(gtk_widget_get_root(GTK_WIDGET(button)));
                         gtk_window_destroy(GTK_WINDOW(root));
                     }),
                     nullptr);
    g_signal_connect(confirm, "clicked", G_CALLBACK(on_delete_confirm), app);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), confirm);
    gtk_box_append(GTK_BOX(content), buttons);
    gtk_window_present(GTK_WINDOW(window));
}

// --- Image import ---

void on_import_file_chosen(GObject* source, GAsyncResult* result,
                           gpointer data) {
    App* app = static_cast<App*>(data);
    GtkFileDialog* dialog = GTK_FILE_DIALOG(source);
    GError* error = nullptr;
    GFile* file = gtk_file_dialog_open_finish(dialog, result, &error);
    if (error != nullptr) {
        g_error_free(error);
    }
    if (file == nullptr) {
        g_object_unref(dialog);
        return;
    }
    char* path = g_file_get_path(file);
    long long id = app->selected_id;
    if (path != nullptr) {
        std::string dest, import_error;
        if (!import_image(path, dest, import_error)) {
            app->last_error = "Could not import image: " + import_error;
            refresh_detail(app);
        } else if (!set_recipe_image(app->db, id, dest, import_error)) {
            app->last_error = "Could not save image: " + import_error;
            refresh_detail(app);
        } else {
            app->last_error.clear();
            reload_recipes(app, id, true);
            start_image_loads(app);
            refresh_detail(app);
        }
        g_free(path);
    }
    g_object_unref(file);
    g_object_unref(dialog);
}

void on_import_clicked(GtkButton* /*button*/, gpointer data) {
    App* app = static_cast<App*>(data);
    if (!app->has_selection) {
        return;
    }
    GtkFileDialog* dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Import image");
    gtk_file_dialog_open(dialog, GTK_WINDOW(app->window), nullptr,
                         on_import_file_chosen, app);
}

}  // namespace

// --- Application setup ---

namespace {

void on_window_destroy(GtkWidget* /*widget*/, gpointer data) {
    App* app = static_cast<App*>(data);
    app->alive = false;
}

void on_activate(GtkApplication* gtk_app, gpointer /*data*/) {
    static App app;
    app.app = gtk_app;
    app.alive = true;

    std::string error;
    if (!open_database("recipes.db", &app.db, error) ||
        !init_and_seed(app.db, error) ||
        !load_recipes(app.db, app.recipes, error)) {
        app.last_error = "Database error: " + error;
    }
    apply_filter(&app);
    if (!app.recipes.empty()) {
        app.selected_id = app.recipes.front().id;
        app.has_selection = true;
    }

    GtkWidget* window = gtk_application_window_new(gtk_app);
    app.window = window;
    gtk_window_set_title(GTK_WINDOW(window), "Recipe Manager");
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 600);
    g_signal_connect(window, "destroy", G_CALLBACK(on_window_destroy), &app);

    GtkWidget* main_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_window_set_child(GTK_WINDOW(window), main_box);

    // Left pane: search, add button, recipe list.
    GtkWidget* left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(left, 6);
    gtk_widget_set_margin_end(left, 6);
    gtk_widget_set_margin_top(left, 6);
    gtk_widget_set_margin_bottom(left, 6);
    gtk_widget_set_size_request(left, 280, -1);
    app.search_entry = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(
        GTK_SEARCH_ENTRY(app.search_entry), "Type to filter recipes…");
    g_signal_connect(app.search_entry, "search-changed",
                     G_CALLBACK(on_search_changed), &app);
    gtk_box_append(GTK_BOX(left), app.search_entry);
    GtkWidget* add_button = gtk_button_new_with_label("Add recipe");
    g_signal_connect(add_button, "clicked", G_CALLBACK(on_add_clicked), &app);
    gtk_box_append(GTK_BOX(left), add_button);

    app.list_box = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(app.list_box),
                                    GTK_SELECTION_SINGLE);
    g_signal_connect(app.list_box, "row-selected",
                     G_CALLBACK(on_row_selected), &app);
    GtkWidget* list_scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list_scrolled),
                                  app.list_box);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(list_scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(list_scrolled, TRUE);
    gtk_box_append(GTK_BOX(left), list_scrolled);
    gtk_box_append(GTK_BOX(main_box), left);

    // Right pane: detail, scrollable.
    GtkWidget* detail_scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(detail_scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_hexpand(detail_scrolled, TRUE);
    app.detail_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(app.detail_box, 12);
    gtk_widget_set_margin_end(app.detail_box, 12);
    gtk_widget_set_margin_top(app.detail_box, 12);
    gtk_widget_set_margin_bottom(app.detail_box, 12);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scrolled),
                                  app.detail_box);
    gtk_box_append(GTK_BOX(main_box), detail_scrolled);

    rebuild_list(&app);
    refresh_detail(&app);
    if (app.has_selection) {
        start_detail_transition(&app);
    }
    start_image_loads(&app);

    gtk_window_present(GTK_WINDOW(window));
}

}  // namespace

int main(int argc, char** argv) {
    GtkApplication* app = gtk_application_new(
        "org.example.recipe-manager", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
