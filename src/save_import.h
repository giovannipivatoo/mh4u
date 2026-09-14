#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace SaveImport {

struct Inspection {
    std::vector<std::string> files;
    std::uint64_t bytes = 0;
};

class StateLock {
public:
    explicit StateLock(const std::filesystem::path& stateDir);
    ~StateLock();
    StateLock(StateLock&& other) noexcept;
    StateLock& operator=(StateLock&& other) noexcept;
    StateLock(const StateLock&) = delete;
    StateLock& operator=(const StateLock&) = delete;

private:
    int descriptor_ = -1;
};

Inspection inspect(const std::filesystem::path& selected);
Inspection stage(const std::filesystem::path& selected,
                 const std::filesystem::path& stateDir);
std::filesystem::path activatePending(const std::filesystem::path& stateDir);
std::filesystem::path backupsDirectory(const std::filesystem::path& stateDir);
int selfTest();

} // namespace SaveImport
