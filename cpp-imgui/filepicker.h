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

#include <algorithm>
#include <cctype>
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
        filter_ = filter;
        // The popup title is also its id, so the image and JSON
        // pickers are distinct popups even though only one is
        // ever open at a time.
        title_ = filter == FileFilter::Json ? "Choose JSON file" : "Choose image";
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

            if (ImGui::Button("Select") && !selected_.empty()) {
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
    FileFilter filter_ = FileFilter::Images;
    std::string title_ = "Choose image";
};
