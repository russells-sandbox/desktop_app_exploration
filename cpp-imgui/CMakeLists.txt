cmake_minimum_required(VERSION 3.20)
project(cpp-imgui CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# Dear ImGui has no CMakeLists, so fetch the source and list the
# files we need explicitly. Pinned to a release tag, not master.
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG v1.93.0
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(imgui)

# stb_image for decoding image files (single header, no build
# step). Shallow fetch of master: stb has no release tags, so
# there is no version to pin to; the API used here
# (stbi_load/stbi_image_free) has been stable for years.
FetchContent_Declare(
    stb
    GIT_REPOSITORY https://github.com/nothings/stb.git
    GIT_TAG master
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(stb)

find_package(SDL2 REQUIRED)
find_package(OpenGL REQUIRED)
find_package(SQLite3 REQUIRED)

# SQLite3::SQLite3 was only added in CMake 4.3; older CMake
# (including the 3.28 in this VM) only provides SQLite::SQLite3.
# Alias the old name so the link line below can use the new,
# non-deprecated name on every supported CMake version.
if(NOT TARGET SQLite3::SQLite3)
    add_library(SQLite3::SQLite3 ALIAS SQLite::SQLite3)
endif()

add_executable(cpp-imgui
    main.cpp
    db.cpp
    images.cpp
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/misc/cpp/imgui_stdlib.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdl2.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_opengl3.cpp
)

target_include_directories(cpp-imgui PRIVATE
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
    ${imgui_SOURCE_DIR}/misc/cpp
    ${stb_SOURCE_DIR}
)

target_link_libraries(cpp-imgui PRIVATE SDL2::SDL2 OpenGL::GL SQLite3::SQLite3 dl)

# Unit tests (plain asserts, no test framework, no new dependency).
# Search tests link nothing but the standard library, so they
# build without SQLite/SDL/Dear ImGui. DB tests use the stack's
# own db.cpp and need SQLite3 only.
enable_testing()

add_executable(cpp-imgui-search-tests tests/test_search.cpp)
target_include_directories(cpp-imgui-search-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
add_test(NAME cpp-imgui-search-tests COMMAND cpp-imgui-search-tests)

add_executable(cpp-imgui-db-tests tests/test_db.cpp db.cpp)
target_include_directories(cpp-imgui-db-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(cpp-imgui-db-tests PRIVATE SQLite3::SQLite3)
add_test(NAME cpp-imgui-db-tests COMMAND cpp-imgui-db-tests)
