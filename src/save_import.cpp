#include "save_import.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <system_error>
#include <utility>

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace SaveImport {
namespace {

constexpr std::uintmax_t UserBytes = 81408;
constexpr std::uintmax_t SystemBytes = 512;
constexpr char SaveSuffix[] =
    "sdmc/Nintendo 3DS/00000000000000000000000000000000/"
    "00000000000000000000000000000000/title/00040000/00126100/data/00000001";
constexpr std::array<unsigned char, 16> Metadata = {
    0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00};

struct Source {
    fs::path root;
    std::vector<std::string> names;
};

fs::path saveDirectory(const fs::path& stateDir) {
    return fs::absolute(stateDir) / "Azahar" / SaveSuffix;
}

fs::path importDirectory(const fs::path& stateDir) {
    return fs::absolute(stateDir) / "save-import";
}

void rejectSymlink(const fs::path& path) {
    if (fs::is_symlink(fs::symlink_status(path)))
        throw std::runtime_error("Symbolic links are not accepted for save import");
}

void rejectSymlinkChain(const fs::path& path) {
    fs::path cursor;
    for (const auto& component : fs::absolute(path).lexically_normal()) {
        cursor /= component;
        if (fs::exists(cursor) || fs::is_symlink(fs::symlink_status(cursor))) rejectSymlink(cursor);
    }
}

bool hidden(const fs::path& path) {
    const std::string name = path.filename().string();
    return !name.empty() && name.front() == '.';
}

bool isUser(const std::string& name) {
    return name == "user1" || name == "user2" || name == "user3";
}

void validateFile(const fs::path& path, const std::string& name) {
    rejectSymlink(path);
    if (!fs::is_regular_file(path))
        throw std::runtime_error("Save import entries must be regular files");
    const auto expected = isUser(name) ? UserBytes : SystemBytes;
    if (fs::file_size(path) != expected)
        throw std::runtime_error(name + " has the wrong size");
}

Source sourceFor(const fs::path& selected, bool requireUser = true) {
    const fs::path absolute = fs::absolute(selected).lexically_normal();
    if (!fs::exists(absolute)) throw std::runtime_error("The selected save does not exist");
    rejectSymlinkChain(absolute);
    if (fs::is_regular_file(absolute)) {
        const std::string name = absolute.filename().string();
        if (!isUser(name)) throw std::runtime_error("Select user1, user2, user3, or a save folder");
        validateFile(absolute, name);
        return {absolute.parent_path(), {name}};
    }
    if (!fs::is_directory(absolute)) throw std::runtime_error("The selected save is not a file or directory");

    fs::path root = absolute;
    const fs::path nested = absolute / SaveSuffix;
    if (fs::exists(nested)) {
        rejectSymlink(nested);
        if (!fs::is_directory(nested)) throw std::runtime_error("The Azahar MH4U save path is invalid");
        root = nested;
    }
    rejectSymlinkChain(root);
    std::vector<std::string> names;
    for (const fs::directory_entry& entry : fs::directory_iterator(root)) {
        rejectSymlink(entry.path());
        const std::string name = entry.path().filename().string();
        if (hidden(entry.path())) continue;
        if (!isUser(name) && name != "system")
            throw std::runtime_error("Unknown file in save folder: " + name);
        validateFile(entry.path(), name);
        names.push_back(name);
    }
    bool user = false;
    for (const auto& name : names) user |= isUser(name);
    if (requireUser && !user) throw std::runtime_error("No user1, user2, or user3 save was found");
    std::sort(names.begin(), names.end());
    return {root, std::move(names)};
}

Inspection describe(const Source& source) {
    Inspection result;
    result.files = source.names;
    for (const auto& name : source.names) result.bytes += fs::file_size(source.root / name);
    return result;
}

void removeQuietly(const fs::path& path) {
    std::error_code ignored;
    fs::remove_all(path, ignored);
}

void copySave(const fs::path& from, const fs::path& to) {
    validateFile(from, from.filename().string());
    fs::copy_file(from, to, fs::copy_options::none);
}

std::string digest(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    std::array<char, 8192> buffer{};
    while (input) {
        input.read(buffer.data(), buffer.size());
        const auto count = input.gcount();
        if (count) CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(count));
    }
    if (!input.eof()) throw std::runtime_error("Could not read save for verification");
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> bytes{};
    CC_SHA256_Final(bytes.data(), &context);
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(bytes.size() * 2);
    for (unsigned char byte : bytes) { result.push_back(hex[byte >> 4]); result.push_back(hex[byte & 15]); }
    return result;
}

void writeMetadata(const fs::path& path) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(Metadata.data()), Metadata.size());
    if (!output) throw std::runtime_error("Could not write save metadata");
}

void syncFile(const fs::path& path) {
    const int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) throw std::system_error(errno, std::generic_category(), "Could not open staged save");
    const int result = ::fsync(fd);
    const int saved = errno;
    ::close(fd);
    if (result != 0) throw std::system_error(saved, std::generic_category(), "Could not sync staged save");
}

void syncDirectory(const fs::path& path) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY);
    if (fd < 0) throw std::system_error(errno, std::generic_category(), "Could not open save directory");
    const int result = ::fsync(fd);
    const int saved = errno;
    ::close(fd);
    if (result != 0) throw std::system_error(saved, std::generic_category(), "Could not sync save directory");
}

void validatePackage(const fs::path& data, bool requireUser = true) {
    rejectSymlinkChain(data);
    rejectSymlink(data);
    const fs::path raw = data / "00000001";
    const fs::path metadata = data / "00000001.metadata";
    if (!fs::is_directory(raw) || !fs::is_regular_file(metadata) || fs::file_size(metadata) != Metadata.size())
        throw std::runtime_error("The staged save package is incomplete");
    rejectSymlink(metadata);
    std::ifstream input(metadata, std::ios::binary);
    std::array<unsigned char, 16> bytes{};
    input.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
    if (!input || bytes != Metadata) throw std::runtime_error("The staged save metadata is invalid");
    const Source source = sourceFor(raw, requireUser);
    bool system = false;
    for (const auto& name : source.names) system |= name == "system";
    if (!system) throw std::runtime_error("The staged save has no system file");
}

Source validatePending(const fs::path& pending) {
    rejectSymlinkChain(pending);
    const fs::path raw = pending / "data" / "00000001";
    const Source source = sourceFor(raw);
    const fs::path manifest = pending / "manifest";
    rejectSymlink(manifest);
    std::ifstream input(manifest);
    std::string line;
    if (!std::getline(input, line) || line != "MH4USAVE1")
        throw std::runtime_error("The staged save manifest is invalid");
    std::vector<std::string> listed;
    while (std::getline(input, line)) {
        const auto space = line.find(' ');
        if (space == std::string::npos) throw std::runtime_error("The staged save manifest is invalid");
        const std::string name = line.substr(0, space), hash = line.substr(space + 1);
        if ((!isUser(name) && name != "system") || hash.size() != 64 || digest(raw / name) != hash)
            throw std::runtime_error("The staged save failed checksum validation");
        listed.push_back(name);
    }
    if (!input.eof() || listed != source.names)
        throw std::runtime_error("The staged save manifest does not match its files");
    return source;
}

std::string nonce() {
    return std::to_string(std::chrono::system_clock::now().time_since_epoch().count()) + "-" +
           std::to_string(static_cast<long long>(::getpid()));
}

} // namespace

StateLock::StateLock(const fs::path& stateDir) {
    const fs::path directory = importDirectory(stateDir);
    rejectSymlinkChain(fs::absolute(stateDir));
    fs::create_directories(directory);
    rejectSymlinkChain(directory);
    const fs::path path = directory / "session.lock";
    descriptor_ = ::open(path.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (descriptor_ < 0) throw std::system_error(errno, std::generic_category(), "Could not open state lock");
    if (::flock(descriptor_, LOCK_EX | LOCK_NB) != 0) {
        const int saved = errno;
        ::close(descriptor_); descriptor_ = -1;
        throw std::system_error(saved, std::generic_category(), "Another MH4U Runtime session is using this state directory");
    }
}

StateLock::~StateLock() { if (descriptor_ >= 0) ::close(descriptor_); }
StateLock::StateLock(StateLock&& other) noexcept : descriptor_(std::exchange(other.descriptor_, -1)) {}
StateLock& StateLock::operator=(StateLock&& other) noexcept {
    if (this != &other) { if (descriptor_ >= 0) ::close(descriptor_); descriptor_ = std::exchange(other.descriptor_, -1); }
    return *this;
}

Inspection inspect(const fs::path& selected) { return describe(sourceFor(selected)); }

Inspection stage(const fs::path& selected, const fs::path& stateDir) {
    const Source source = sourceFor(selected);
    const Inspection result = describe(source);
    const fs::path imports = importDirectory(stateDir);
    const fs::path pending = imports / "pending";
    const fs::path temporary = imports / (".staging-" + nonce());
    const fs::path raw = temporary / "data" / "00000001";
    try {
        rejectSymlinkChain(fs::absolute(stateDir));
        rejectSymlinkChain(imports);
        if (fs::exists(pending)) rejectSymlinkChain(pending);
        fs::create_directories(raw);
        for (const auto& name : source.names) {
            copySave(source.root / name, raw / name);
        }
        std::ofstream manifest(temporary / "manifest", std::ios::binary);
        manifest << "MH4USAVE1\n";
        for (const auto& name : source.names) manifest << name << ' ' << digest(raw / name) << '\n';
        manifest.close();
        if (!manifest) throw std::runtime_error("Could not write staged save manifest");
        validatePending(temporary);
        for (const fs::directory_entry& entry : fs::directory_iterator(raw)) syncFile(entry.path());
        syncFile(temporary / "manifest");
        syncDirectory(raw); syncDirectory(temporary / "data"); syncDirectory(temporary);
        const fs::path oldPending = imports / (".old-pending-" + nonce());
        if (fs::exists(pending)) fs::rename(pending, oldPending);
        try { fs::rename(temporary, pending); syncDirectory(imports); }
        catch (...) {
            std::error_code ignored;
            if (fs::exists(pending)) fs::rename(pending, temporary, ignored);
            if (fs::exists(oldPending)) fs::rename(oldPending, pending, ignored);
            throw;
        }
        removeQuietly(oldPending);
        return result;
    } catch (...) {
        removeQuietly(temporary);
        throw;
    }
}

fs::path backupsDirectory(const fs::path& stateDir) { return importDirectory(stateDir) / "backups"; }

fs::path activatePending(const fs::path& stateDir) {
    const fs::path imports = importDirectory(stateDir);
    rejectSymlinkChain(imports);
    const fs::path pending = imports / "pending";
    if (!fs::exists(pending)) return {};
    const Source imported = validatePending(pending);
    const fs::path liveData = saveDirectory(stateDir).parent_path();
    fs::create_directories(liveData.parent_path());
    rejectSymlinkChain(liveData.parent_path());
    const fs::path backupData = backupsDirectory(stateDir) / nonce() / "data";
    const fs::path mergedRoot = imports / (".merged-" + nonce());
    const fs::path mergedData = mergedRoot / "data";
    const fs::path mergedRaw = mergedData / "00000001";
    bool hadLive = fs::exists(liveData);
    try {
        fs::create_directories(mergedRaw);
        if (hadLive) {
            validatePackage(liveData, false);
            const Source current = sourceFor(liveData / "00000001", false);
            for (const auto& name : current.names) copySave(current.root / name, mergedRaw / name);
        }
        for (const auto& name : imported.names) {
            std::error_code ignored; fs::remove(mergedRaw / name, ignored);
            copySave(imported.root / name, mergedRaw / name);
        }
        if (!fs::exists(mergedRaw / "system"))
            throw std::runtime_error("A fresh import must include the 512-byte system file");
        writeMetadata(mergedData / "00000001.metadata");
        validatePackage(mergedData);
        for (const fs::directory_entry& entry : fs::directory_iterator(mergedRaw)) syncFile(entry.path());
        syncFile(mergedData / "00000001.metadata"); syncDirectory(mergedRaw); syncDirectory(mergedData);

        if (hadLive) {
            fs::create_directories(backupData / "00000001");
            const Source current = sourceFor(liveData / "00000001", false);
            for (const auto& name : current.names) copySave(current.root / name, backupData / "00000001" / name);
            fs::copy_file(liveData / "00000001.metadata", backupData / "00000001.metadata");
            for (const fs::directory_entry& entry : fs::directory_iterator(backupData / "00000001")) syncFile(entry.path());
            syncFile(backupData / "00000001.metadata"); syncDirectory(backupData / "00000001"); syncDirectory(backupData);
            syncDirectory(backupData.parent_path());
            syncDirectory(backupsDirectory(stateDir));
            if (::renamex_np(liveData.c_str(), mergedData.c_str(), RENAME_SWAP) != 0)
                throw std::system_error(errno, std::generic_category(), "Could not atomically activate staged save");
            try { syncDirectory(liveData.parent_path()); }
            catch (...) {
                if (::renamex_np(liveData.c_str(), mergedData.c_str(), RENAME_SWAP) == 0) {
                    try { syncDirectory(liveData.parent_path()); } catch (...) {}
                }
                throw;
            }
        } else {
            fs::rename(mergedData, liveData);
            try { syncDirectory(liveData.parent_path()); }
            catch (...) {
                std::error_code ignored; fs::rename(liveData, mergedData, ignored);
                throw;
            }
        }
    } catch (...) { removeQuietly(mergedRoot); throw; }
    removeQuietly(mergedRoot);
    std::error_code removalError;
    fs::remove_all(pending, removalError);
    if (removalError) throw std::system_error(removalError, "Save activated, but could not clear pending import");
    syncDirectory(imports);
    return hadLive ? backupData / "00000001" : fs::path{};
}

int selfTest() {
    const fs::path base = fs::current_path() / ".local" / ("save-import-test-" + nonce());
    auto bytes = [](const fs::path& path, std::uintmax_t count, char value) {
        std::ofstream output(path, std::ios::binary); std::array<char, 4096> chunk{}; chunk.fill(value);
        while (count) { const auto n = std::min<std::uintmax_t>(count, chunk.size()); output.write(chunk.data(), n); count -= n; }
    };
    auto rejected = [](auto action) { try { action(); } catch (...) { return true; } return false; };
    try {
        const fs::path state = base / "state", existing = saveDirectory(state), incoming = base / "incoming";
        fs::create_directories(existing); fs::create_directories(incoming);
        bytes(existing / "system", SystemBytes, 's'); bytes(existing / "user2", UserBytes, '2');
        writeMetadata(existing.parent_path() / "00000001.metadata");
        bytes(incoming / "user1", UserBytes, '1'); bytes(incoming / "system", SystemBytes, 'n');
        StateLock lock(state);
        if (!rejected([&] { StateLock second(state); }))
            throw std::runtime_error("concurrent state lock was accepted");
        if (stage(incoming, state).files.size() != 2 || !fs::exists(importDirectory(state) / "pending") || fs::exists(existing / "user1"))
            throw std::runtime_error("staging changed live saves");
        bytes(existing / "user2", UserBytes, 'z');
        const fs::path backup = activatePending(state);
        std::ifstream preserved(existing / "user2", std::ios::binary); char preservedByte = 0; preserved.get(preservedByte);
        if (!fs::exists(existing / "user1") || preservedByte != 'z' || !fs::exists(backup / "user2"))
            throw std::runtime_error("activation did not merge or back up saves");
        const fs::path bad = base / "bad"; fs::create_directory(bad); bytes(bad / "user1", 7, 'x');
        if (!rejected([&] { inspect(bad); })) throw std::runtime_error("wrong-sized save accepted");
        const fs::path unknown = base / "unknown"; fs::create_directory(unknown); bytes(unknown / "user1", UserBytes, 'x'); bytes(unknown / "notes.txt", 1, 'x');
        if (!rejected([&] { inspect(unknown); })) throw std::runtime_error("unknown save file accepted");
        const fs::path linked = base / "linked"; fs::create_directory(linked); fs::create_symlink(incoming / "user1", linked / "user1");
        if (!rejected([&] { inspect(linked); })) throw std::runtime_error("symbolic save accepted");
        stage(incoming, state); bytes(importDirectory(state) / "pending" / "data" / "00000001" / "user1", UserBytes, 'x');
        if (!rejected([&] { activatePending(state); }) || !fs::exists(existing / "user1"))
            throw std::runtime_error("corrupt pending save reached live data");
        removeQuietly(importDirectory(state) / "pending");
        const fs::path external = base / "external-pending";
        stage(incoming, base / "external-state");
        fs::rename(importDirectory(base / "external-state") / "pending", external);
        fs::create_symlink(external, importDirectory(state) / "pending");
        if (!rejected([&] { activatePending(state); }))
            throw std::runtime_error("symbolic pending package was accepted");
        removeQuietly(importDirectory(state) / "pending");
        const fs::path fresh = base / "fresh";
        if (stage(incoming, fresh).files.size() != 2 || !activatePending(fresh).empty() ||
            !fs::exists(saveDirectory(fresh) / "system"))
            throw std::runtime_error("fresh full-folder import failed");
        const fs::path emptyState = base / "empty-state", emptyRaw = saveDirectory(emptyState);
        fs::create_directories(emptyRaw); bytes(emptyRaw / "system", SystemBytes, 's');
        writeMetadata(emptyRaw.parent_path() / "00000001.metadata");
        if (stage(incoming / "user1", emptyState).files.size() != 1 ||
            activatePending(emptyState).empty() || !fs::exists(emptyRaw / "user1"))
            throw std::runtime_error("system-only current archive import failed");
        removeQuietly(base); return 0;
    } catch (...) { removeQuietly(base); throw; }
}

} // namespace SaveImport
