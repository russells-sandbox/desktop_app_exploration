#pragma once

// A small in-app file picker, drawn with Dear ImGui.
//
// Why not a native dialog (tinyfiledialogs, zenity, ...)? On Linux
// those need an external helper (zenity/kdialog/dialog) to show
// anything, and this VM has none of them installed, so a native
// dialog would silently fall back to terminal input and be
// unusable from the GUI. This picker needs no helper: it lists
// directories and files, navigates with mouse clicks, and works
// under Xvfb. It is used for choosing a recipe image (image
// files only) and for choosing a recipe JSON file to import
// (JSON files only); the filter is picked when the picker is
// opened.
//
// Usage: call open() to show it, then draw() every frame while it
// is open. draw() returns true exactly once, on the frame the user
// confirms a file; selected() then holds the chosen full path.
//
// Save mode: call open_save() instead, with the default file
// name (for example "recipes.json", or a name derived from a
// recipe title). The picker then shows the same folder list,
// plus a file-name field the user can type in: the user
// navigates to a folder and types (or picks an existing file
// to fill in) the name, and confirming writes to that name in
// that folder — including a name that does not exist yet, which
// is what pick mode cannot do. A name with no extension gets
// ".json" appended on confirm, so a typed name still produces
// a file the JSON picker can find again later. Cancelling, in
// either mode, confirms nothing and writes nothing.

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "imgui.h"

namespace fs = std::filesystem;

class FilePicker {
public:
    enum class FileFilter { Images, Json };

    void open(FileFilter filter = FileFilter::Images) {
        std::error_code ec;
        current_dir_ = fs::current_path(ec).string();
        if (ec || current_dir_.empty()) {
            current_dir_ = ".";
        }
        selected_.clear();
        confirmed_ = false;
        show_ = true;
        save_mode_ = false;
        filter_ = filter;
        // The popup title is also its id, so the image and JSON
        // pickers are distinct popups even though only one is
        // ever open at a time.
        title_ = filter == FileFilter::Json ? "Choose JSON file" : "Choose image";
        ImGui::OpenPopup(title_.c_str());
    }

    // Save mode (see the header comment). The default name is
    // copied into the file-name field, so the caller does not
    // have to keep it alive after this call.
    void open_save(const std::string& default_name) {
        std::error_code ec;
        current_dir_ = fs::current_path(ec).string();
        if (ec || current_dir_.empty()) {
            current_dir_ = ".";
        }
        selected_.clear();
        confirmed_ = false;
        show_ = true;
        save_mode_ = true;
        filter_ = FileFilter::Json;
        title_ = "Save JSON file";
        std::snprintf(filename_, sizeof(filename_), "%s", default_name.c_str());
        ImGui::OpenPopup(title_.c_str());
    }

    bool is_open() const { return show_; }

    const std::string& selected() const { return selected_; }

    // Draws the picker popup. Returns true on the frame the user
    // confirms a file (Select button or double-click on a file).
    bool draw() {
        bool confirmed_this_frame = false;
        if (ImGui::BeginPopupModal(title_.c_str(), nullptr,
                                   ImGuiWindowFlags_AlwaysAutoResize)) {
            ImGui::Text("Folder: %s", current_dir_.c_str());
            if (save_mode_) {
                // A plain char buffer, not a std::string: the
                // core ImGui InputText takes a char buffer, and
                // this header does not depend on imgui_stdlib.
                ImGui::InputText("File name:", filename_, sizeof(filename_));
            }
            ImGui::Separator();

            // Entries: directories first, then image files, each
            // group sorted alphabetically (case-insensitive).
            struct Entry {
                std::string name;
                std::string full_path;
                bool is_dir;
            };
            std::vector<Entry> entries;
            std::error_code ec;
            if (current_dir_ != "/" && current_dir_ != ".") {
                fs::path parent = fs::path(current_dir_).parent_path();
                entries.push_back({"..", parent.string(), true});
            }
            for (const auto& item : fs::directory_iterator(current_dir_, ec)) {
                std::error_code item_ec;
                bool is_dir = item.is_directory(item_ec);
                std::string name = item.path().filename().string();
                if (name.empty()) {
                    continue;
                }
                if (is_dir) {
                    entries.push_back({name, item.path().string(), true});
                } else if (is_visible_file(name)) {
                    entries.push_back({name, item.path().string(), false});
                }
            }
            std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
                if (a.is_dir != b.is_dir) {
                    return a.is_dir > b.is_dir;
                }
                return lower(a.name) < lower(b.name);
            });

            ImGui::BeginChild("PickerList", ImVec2(500, 300), true);
            for (const Entry& entry : entries) {
                std::string label = entry.is_dir ? entry.name + "/" : entry.name;
                bool is_selected = selected_ == entry.full_path;
                if (ImGui::Selectable(label.c_str(), is_selected,
                                      ImGuiSelectableFlags_AllowDoubleClick)) {
                    if (entry.is_dir) {
                        if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                            current_dir_ = entry.full_path;
                            selected_.clear();
                        } else {
                            selected_.clear();
                        }
                    } else if (save_mode_) {
                        // Picking an existing file fills in its
                        // name (to overwrite it); double-click
                        // confirms with that name.
                        std::snprintf(filename_, sizeof(filename_), "%s",
                                      entry.name.c_str());
                        selected_ = entry.full_path;
                        if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                            confirmed_this_frame = true;
                            confirmed_ = true;
                        }
                    } else {
                        selected_ = entry.full_path;
                        if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                            confirmed_this_frame = true;
                            confirmed_ = true;
                        }
                    }
                }
            }
            ImGui::EndChild();

            if (save_mode_) {
                // Confirming in save mode uses the typed name,
                // not a previously picked file: the name may not
                // exist yet, and navigating folders must not
                // leave a stale picked path behind.
                if (ImGui::Button("Save") && filename_[0] != '\0') {
                    std::string name = filename_;
                    if (fs::path(name).extension().empty()) {
                        name += ".json";
                    }
                    selected_ = (fs::path(current_dir_) / name).string();
                    confirmed_this_frame = true;
                    confirmed_ = true;
                }
            } else if (ImGui::Button("Select") && !selected_.empty()) {
                confirmed_this_frame = true;
                confirmed_ = true;
            }
            ImGui::SameLine();
            if (ImGui::Button("Cancel")) {
                ImGui::CloseCurrentPopup();
                show_ = false;
            }
            if (confirmed_this_frame) {
                ImGui::CloseCurrentPopup();
                show_ = false;
            }
            ImGui::EndPopup();
        } else if (show_) {
            // Popup was closed some other way (e.g. Escape).
            show_ = false;
        }
        return confirmed_this_frame;
    }

private:
    static std::string lower(const std::string& text) {
        std::string lowered = text;
        std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        return lowered;
    }

    static bool is_image_file(const std::string& name) {
        std::string ext = lower(fs::path(name).extension().string());
        return ext == ".png" || ext == ".jpg" || ext == ".jpeg" ||
               ext == ".webp" || ext == ".gif" || ext == ".bmp";
    }

    bool is_visible_file(const std::string& name) const {
        if (filter_ == FileFilter::Json) {
            return lower(fs::path(name).extension().string()) == ".json";
        }
        return is_image_file(name);
    }

    std::string current_dir_;
    std::string selected_;
    bool confirmed_ = false;
    bool show_ = false;
    bool save_mode_ = false;
    // File name typed in save mode. A char buffer, so the
    // draw() code can use core ImGui::InputText (see above).
    char filename_[1024] = "";
    FileFilter filter_ = FileFilter::Images;
    std::string title_ = "Choose image";
};
