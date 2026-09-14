#pragma once

#include "aot/runtime.h"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace mh4u::aot::fixture {

struct Fixture {
    GuestCpuState state{};
    std::vector<std::uint8_t> memory;
    std::uint32_t base{};
    bool thumb{};
    std::uint64_t ticks_remaining{};
};

struct Host {
    std::vector<std::uint8_t> memory;
    std::uint64_t ticks_remaining{};
    std::uint64_t ticks_elapsed{};
    std::vector<std::uint32_t> svc_calls;
    std::uint32_t cp15_thread_uprw{};
    std::uint32_t cp15_thread_uro{};
    std::uint64_t coprocessor_reads{};
    std::uint64_t coprocessor_writes{};
    bool exclusive_valid{};
    std::uint32_t exclusive_address{};
    std::uint32_t exclusive_value{};
};

bool Load(const std::filesystem::path& path, Fixture& fixture, std::string& error);
bool MapBinary(const std::filesystem::path& path, std::uint32_t base, Host& host,
               std::string& error);
Callbacks MakeCallbacks(Host& host);
std::string Format(const GuestCpuState& state, const Host& host);
std::string FormatSummary(const GuestCpuState& state, const Host& host,
                          const std::vector<std::uint8_t>& initial_memory);

}  // namespace mh4u::aot::fixture
