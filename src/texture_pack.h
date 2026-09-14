#pragma once

#include <cstdint>
#include <filesystem>

namespace TexturePack {

constexpr std::uint64_t titleId = 0x0004000000126100ULL;

struct InstallResult {
    std::uint64_t files = 0;
    std::uint64_t bytes = 0;
    bool hasConfig = false;
};

std::filesystem::path destination(const std::filesystem::path& stateDir);
std::filesystem::path sourceRoot(const std::filesystem::path& selected);
InstallResult install(const std::filesystem::path& selected,
                      const std::filesystem::path& stateDir, bool pending = false);
bool activatePending(const std::filesystem::path& stateDir);
int selfTest();

} // namespace TexturePack
