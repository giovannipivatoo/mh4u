#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

#include <boost/archive/binary_iarchive.hpp>
#include <boost/archive/binary_oarchive.hpp>
#include <boost/serialization/unique_ptr.hpp>

#include "common/file_util.h"
#include "core/file_sys/archive_backend.h"
#include "core/file_sys/file_backend.h"
#include "core/file_sys/savedata_archive.h"

int main(int argc, char** argv) {
    const bool saving = argc == 4 && std::string(argv[1]) == "save";
    const bool loading = argc == 5 && std::string(argv[1]) == "load";
    if (!saving && !loading) {
        std::cerr << "usage: savestate-path-probe save SOURCE_USER_DIR ARCHIVE\n"
                     "       savestate-path-probe load CURRENT_USER_DIR SOURCE_USER_DIR ARCHIVE\n";
        return 2;
    }

    const std::filesystem::path current = std::filesystem::absolute(argv[2]);
    const std::filesystem::path source = std::filesystem::absolute(saving ? argv[2] : argv[3]);
    const std::filesystem::path archive_path = std::filesystem::absolute(argv[saving ? 3 : 4]);
    FileUtil::SetUserPath(current.string() + '/');

    std::unique_ptr<FileSys::ArchiveBackend> backend;
    if (saving) {
        backend = std::make_unique<FileSys::SaveDataArchive>(
            FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) + "probe/");
        std::ofstream output(archive_path, std::ios::binary | std::ios::trunc);
        boost::archive::binary_oarchive archive(output);
        archive << backend;
        return output ? 0 : 1;
    }

    std::ifstream input(archive_path, std::ios::binary);
    boost::archive::binary_iarchive archive(input);
    archive >> backend;
    FileSys::Mode mode{};
    mode.write_flag.Assign(1);
    mode.create_flag.Assign(1);
    auto opened = backend->OpenFile(FileSys::Path("/written-by-load"), mode);
    if (opened.Failed()) {
        std::cerr << "restored SaveDataArchive could not open a writable file\n";
        return 1;
    }
    auto file = std::move(opened).Unwrap();
    constexpr unsigned char contents[] = "destination\n";
    auto written = file->Write(0, sizeof(contents) - 1, true, false, contents);
    if (written.Failed() || written.Unwrap() != sizeof(contents) - 1) {
        std::cerr << "restored SaveDataArchive could not write the test file\n";
        return 1;
    }

    const auto relative = std::filesystem::path("sdmc/probe/written-by-load");
    if (std::filesystem::exists(source / relative) || !std::filesystem::exists(current / relative)) {
        std::cerr << "restored SaveDataArchive retained its original user-directory path\n";
        return 1;
    }
    return 0;
}
