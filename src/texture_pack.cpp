#include "texture_pack.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <copyfile.h>

namespace fs = std::filesystem;

namespace TexturePack {
namespace {

constexpr char TitleName[] = "0004000000126100";

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

bool titleLike(const fs::path& path) {
    const std::string name = path.filename().string();
    return name.size() == 16 &&
           std::all_of(name.begin(), name.end(), [](unsigned char c) { return std::isxdigit(c); });
}

bool allowed(const fs::path& path) {
    const std::string name = path.filename().string();
    if (name == "pack.json") return true;
    const std::string ext = path.extension().string();
    return ext == ".png" || ext == ".dds" || ext == ".ktx";
}

fs::path findRoot(const fs::path& selected) {
    if (!fs::is_directory(selected) || fs::is_symlink(fs::symlink_status(selected)))
        throw std::runtime_error("The selected texture-pack location is not a regular directory");
    if (titleLike(selected)) {
        if (lower(selected.filename().string()) != TitleName)
            throw std::runtime_error("This texture pack is for a different regional title; expected 0004000000126100");
        return selected;
    }

    std::vector<fs::path> matches, configs;
    bool otherTitle = false;
    fs::recursive_directory_iterator it(selected), end;
    for (; it != end; ++it) {
        if (it.depth() > 5) { it.disable_recursion_pending(); continue; }
        const fs::file_status status = it->symlink_status();
        if (fs::is_symlink(status))
            throw std::runtime_error("Texture packs containing symbolic links are not accepted");
        if (fs::is_regular_file(status) && it->path().filename() == "pack.json")
            configs.push_back(it->path().parent_path());
        if (!fs::is_directory(status) || !titleLike(it->path())) continue;
        if (lower(it->path().filename().string()) == TitleName) matches.push_back(it->path());
        else otherTitle = true;
        it.disable_recursion_pending();
    }
    if (matches.size() == 1) return matches.front();
    if (matches.size() > 1)
        throw std::runtime_error("More than one European MH4U texture directory was found");
    if (otherTitle)
        throw std::runtime_error("This texture pack is for a different regional title; expected 0004000000126100");
    if (fs::is_regular_file(selected / "pack.json")) return selected;
    if (configs.size() == 1) return configs.front();
    if (configs.size() > 1)
        throw std::runtime_error("More than one texture pack was found; select one pack directory");
    return selected;
}

struct SourceFile { fs::path source, relative; std::uint64_t bytes; };

std::vector<SourceFile> inventory(const fs::path& root, InstallResult& result) {
    std::vector<SourceFile> files;
    std::uint64_t images = 0;
    fs::recursive_directory_iterator it(root), end;
    for (; it != end; ++it) {
        const fs::file_status status = it->symlink_status();
        if (fs::is_symlink(status))
            throw std::runtime_error("Texture packs containing symbolic links are not accepted");
        if (fs::is_directory(status)) {
            if (titleLike(it->path()) && lower(it->path().filename().string()) != TitleName)
                throw std::runtime_error("Texture pack contains a directory for a different regional title");
            continue;
        }
        if (!fs::is_regular_file(status) || !allowed(it->path())) continue;
        fs::path relative = fs::relative(it->path(), root);
        if (relative.empty() || relative.is_absolute() || *relative.begin() == "..")
            throw std::runtime_error("Texture pack contains an invalid path");
        const auto bytes = fs::file_size(it->path());
        files.push_back({it->path(), std::move(relative), bytes});
        result.files++;
        result.bytes += bytes;
        if (lower(it->path().filename().string()) == "pack.json") result.hasConfig = true;
        else images++;
    }
    if (!images)
        throw std::runtime_error("No supported lowercase .png, .dds, or .ktx texture files were found");
    return files;
}

void removeIfPresent(const fs::path& path) {
    std::error_code error;
    fs::remove_all(path, error);
}

} // namespace

fs::path destination(const fs::path& stateDir) {
    return stateDir / "Azahar" / "load" / "textures" / TitleName;
}

fs::path sourceRoot(const fs::path& selected) {
    return findRoot(fs::absolute(selected));
}

InstallResult install(const fs::path& selected, const fs::path& stateDir, bool pending) {
    const fs::path root = findRoot(fs::absolute(selected));
    InstallResult result;
    const auto files = inventory(root, result);
    const fs::path active = destination(fs::absolute(stateDir));
    const fs::path target = pending ? active.parent_path() / (std::string(".") + TitleName + ".pending") : active;
    fs::create_directories(target.parent_path());
    for (fs::path cursor = target.parent_path(); !cursor.empty(); cursor = cursor.parent_path()) {
        if (fs::exists(cursor) && fs::is_symlink(fs::symlink_status(cursor)))
            throw std::runtime_error("The texture destination must not pass through symbolic links");
        if (cursor == cursor.root_path()) break;
    }
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path staging = target.parent_path() / (std::string(".") + TitleName + ".install-" + std::to_string(nonce));
    const fs::path backup = target.parent_path() / (std::string(".") + TitleName + ".backup-" + std::to_string(nonce));
    try {
        fs::create_directory(staging);
        for (const auto& file : files) {
            const fs::path output = staging / file.relative;
            fs::create_directories(output.parent_path());
            if (copyfile(file.source.c_str(), output.c_str(), nullptr, COPYFILE_DATA | COPYFILE_CLONE) != 0) {
                std::error_code ignored; fs::remove(output, ignored);
                fs::copy_file(file.source, output, fs::copy_options::none);
            }
        }
        if (fs::exists(target)) fs::rename(target, backup);
        try {
            fs::rename(staging, target);
        } catch (...) {
            if (fs::exists(backup)) fs::rename(backup, target);
            throw;
        }
        removeIfPresent(backup);
    } catch (...) {
        removeIfPresent(staging);
        throw;
    }
    return result;
}

bool activatePending(const fs::path& stateDir) {
    const fs::path target = destination(fs::absolute(stateDir));
    const fs::path pending = target.parent_path() / (std::string(".") + TitleName + ".pending");
    if (!fs::exists(pending)) return false;
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path backup = target.parent_path() / (std::string(".") + TitleName + ".backup-" + std::to_string(nonce));
    if (fs::exists(target)) fs::rename(target, backup);
    try { fs::rename(pending, target); }
    catch (...) { if (fs::exists(backup)) fs::rename(backup, target); throw; }
    removeIfPresent(backup);
    return true;
}

int selfTest() {
    const fs::path base = fs::current_path() / ".local" /
        ("mh4u-texture-pack-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        const fs::path source = base / "Citra" / "load" / "textures" / TitleName;
        fs::create_directories(source / "nested");
        std::ofstream(source / "pack.json") << R"({"options":{"skip_mipmap":false,"flip_png_files":true,"use_new_hash":true}})";
        std::ofstream(source / "nested" / "tex1_8x8_ABCD_0.png") << "png";
        std::ofstream(source / "nested" / "texture.dds") << "dds";
        std::ofstream(source / "nested" / "texture.ktx") << "ktx";
        std::ofstream(source / "unrelated.txt") << "ignore";
        const InstallResult result = install(base / "Citra", base / "state", true);
        const fs::path target = destination(base / "state");
        if (fs::exists(target) || !activatePending(base / "state") ||
            result.files != 4 || !result.hasConfig || fs::exists(target / "unrelated.txt") ||
            !fs::exists(target / "nested" / "texture.ktx"))
            throw std::runtime_error("filtered recursive installation failed");

        const fs::path wrong = base / "0004000000126300";
        fs::create_directory(wrong);
        bool rejected = false;
        try { install(wrong, base / "wrong-state"); } catch (...) { rejected = true; }
        if (!rejected) throw std::runtime_error("wrong regional title was accepted");

        const fs::path linked = base / "linked";
        fs::create_directory(linked);
        fs::create_symlink(source / "pack.json", linked / "pack.json");
        rejected = false;
        try { install(linked, base / "linked-state"); } catch (...) { rejected = true; }
        if (!rejected) throw std::runtime_error("symbolic link was accepted");
        const fs::path wrapper = base / "wrapper";
        fs::create_directories(wrapper / "pack-name");
        std::ofstream(wrapper / "pack-name" / "pack.json") << "{}";
        if (sourceRoot(wrapper) != wrapper / "pack-name")
            throw std::runtime_error("wrapped pack configuration was not located");
        removeIfPresent(base);
        return 0;
    } catch (...) {
        removeIfPresent(base);
        throw;
    }
}

} // namespace TexturePack
