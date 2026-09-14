#include "fixture.h"

#include <algorithm>
#include <charconv>
#include <CommonCrypto/CommonDigest.h>
#include <fstream>
#include <iomanip>
#include <sstream>

namespace mh4u::aot::fixture {
namespace {

std::string MemorySha256(const std::vector<std::uint8_t>& memory) {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    constexpr std::size_t chunk_size = 1U << 20;
    for (std::size_t offset = 0; offset < memory.size(); offset += chunk_size) {
        const std::size_t count = std::min(chunk_size, memory.size() - offset);
        CC_SHA256_Update(&context, memory.data() + offset, static_cast<CC_LONG>(count));
    }
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256_Final(digest.data(), &context);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (const unsigned char byte : digest) out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

bool ParseNumber(const std::string& text, std::uint64_t& value) {
    const int base = text.starts_with("0x") ? 16 : 10;
    const char* begin = text.data() + (base == 16 ? 2 : 0);
    const auto result = std::from_chars(begin, text.data() + text.size(), value, base);
    return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

bool ReadCallback(void* context, const std::uint32_t address, const unsigned bits,
                  std::uint64_t* value) {
    auto& host = *static_cast<Host*>(context);
    const unsigned bytes = bits / 8;
    if (!value || (bits != 8 && bits != 16 && bits != 32 && bits != 64) ||
        static_cast<std::uint64_t>(address) + bytes > host.memory.size()) {
        return false;
    }
    *value = 0;
    for (unsigned index = 0; index < bytes; ++index) {
        *value |= static_cast<std::uint64_t>(host.memory[address + index]) << (index * 8);
    }
    return true;
}

bool WriteCallback(void* context, const std::uint32_t address, const unsigned bits,
                   const std::uint64_t value) {
    auto& host = *static_cast<Host*>(context);
    const unsigned bytes = bits / 8;
    if ((bits != 8 && bits != 16 && bits != 32 && bits != 64) ||
        static_cast<std::uint64_t>(address) + bytes > host.memory.size()) {
        return false;
    }
    for (unsigned index = 0; index < bytes; ++index) {
        host.memory[address + index] = static_cast<std::uint8_t>(value >> (index * 8));
    }
    return true;
}

bool SvcCallback(void* context, GuestCpuState* state, const std::uint32_t number, bool* halt) {
    auto& host = *static_cast<Host*>(context);
    if (!state || !halt) {
        return false;
    }
    host.svc_calls.push_back(number);
    state->regs[0] ^= 0x13579bdfU;
    *halt = true;
    return true;
}

bool TicksCallback(void* context, const std::uint64_t elapsed, std::uint64_t* remaining) {
    auto& host = *static_cast<Host*>(context);
    if (!remaining) {
        return false;
    }
    host.ticks_elapsed += elapsed;
    host.ticks_remaining = elapsed >= host.ticks_remaining ? 0 : host.ticks_remaining - elapsed;
    *remaining = host.ticks_remaining;
    return true;
}

bool IsCp15OneWord(const std::uint8_t info[8], const std::uint8_t crn,
                   const std::uint8_t crm, const std::uint8_t opc2) {
    return info && info[0] == 15 && info[1] == 0 && info[2] == 0 && info[3] == crn &&
           info[4] == crm && info[5] == opc2 && info[6] == 0 && info[7] == 0;
}

bool CoprocessorReadCallback(void* context, const std::uint8_t info[8], std::uint32_t* value) {
    if (!context || !value) return false;
    auto& host = *static_cast<Host*>(context);
    if (IsCp15OneWord(info, 13, 0, 2)) {
        *value = host.cp15_thread_uprw;
    } else if (IsCp15OneWord(info, 13, 0, 3)) {
        *value = host.cp15_thread_uro;
    } else {
        return false;
    }
    ++host.coprocessor_reads;
    return true;
}

bool CoprocessorWriteCallback(void* context, const std::uint8_t info[8],
                              const std::uint32_t value) {
    if (!context) return false;
    auto& host = *static_cast<Host*>(context);
    if (IsCp15OneWord(info, 13, 0, 2)) {
        host.cp15_thread_uprw = value;
    } else if (!IsCp15OneWord(info, 7, 5, 4) &&
               !IsCp15OneWord(info, 7, 10, 4) &&
               !IsCp15OneWord(info, 7, 10, 5)) {
        return false;
    }
    ++host.coprocessor_writes;
    return true;
}

}  // namespace

bool Load(const std::filesystem::path& path, Fixture& fixture, std::string& error) {
    std::ifstream input(path);
    if (!input) {
        error = "cannot open fixture: " + path.string();
        return false;
    }
    std::string magic;
    std::getline(input, magic);
    if (magic != "mh4u-aot-fixture-v1") {
        error = "invalid fixture header";
        return false;
    }
    fixture.memory.assign(0x4000, 0);
    bool have_pc = false;
    std::uint32_t entry_pc = 0;
    std::uint64_t code_cursor = 0;
    std::string line;
    unsigned line_number = 1;
    while (std::getline(input, line)) {
        ++line_number;
        if (line.empty() || line[0] == '#') {
            continue;
        }
        std::istringstream fields(line);
        std::string key;
        std::string first;
        std::string second;
        fields >> key >> first >> second;
        std::uint64_t a = 0;
        std::uint64_t b = 0;
        auto fail = [&] {
            error = "fixture line " + std::to_string(line_number) + ": " + line;
            return false;
        };
        if (key == "mode") {
            if (first == "arm") fixture.thumb = false;
            else if (first == "thumb") fixture.thumb = true;
            else return fail();
        } else if (key == "base" && ParseNumber(first, a) && a <= UINT32_MAX) {
            fixture.base = static_cast<std::uint32_t>(a);
        } else if (key == "pc" && ParseNumber(first, a) && a <= UINT32_MAX) {
            entry_pc = static_cast<std::uint32_t>(a);
            fixture.state.regs[15] = entry_pc;
            code_cursor = entry_pc;
            have_pc = true;
        } else if (key == "cpsr" && ParseNumber(first, a) && a <= UINT32_MAX) {
            fixture.state.cpsr = static_cast<std::uint32_t>(a);
        } else if (key == "fpscr" && ParseNumber(first, a) && a <= UINT32_MAX) {
            fixture.state.fpscr = static_cast<std::uint32_t>(a);
        } else if (key == "fpexc" && ParseNumber(first, a) && a <= UINT32_MAX) {
            fixture.state.fpexc = static_cast<std::uint32_t>(a);
        } else if (key == "ticks" && ParseNumber(first, a)) {
            fixture.ticks_remaining = a;
        } else if (key == "memory_size" && ParseNumber(first, a) && a <= (1U << 25)) {
            fixture.memory.assign(static_cast<std::size_t>(a), 0);
        } else if (key == "reg" && ParseNumber(first, a) && ParseNumber(second, b) && a < 16 && b <= UINT32_MAX) {
            fixture.state.regs[a] = static_cast<std::uint32_t>(b);
        } else if (key == "ext" && ParseNumber(first, a) && ParseNumber(second, b) && a < 64 && b <= UINT32_MAX) {
            fixture.state.ext_regs[a] = static_cast<std::uint32_t>(b);
        } else if (key == "byte" && ParseNumber(first, a) && ParseNumber(second, b) && a < fixture.memory.size() && b <= UINT8_MAX) {
            fixture.memory[a] = static_cast<std::uint8_t>(b);
        } else if ((key == "word" || key == "halfword") && ParseNumber(first, a) &&
                   a <= (key == "word" ? UINT32_MAX : UINT16_MAX)) {
            const unsigned bytes = key == "word" ? 4 : 2;
            if (!have_pc || code_cursor + bytes > fixture.memory.size()) return fail();
            for (unsigned index = 0; index < bytes; ++index) {
                fixture.memory[code_cursor + index] = static_cast<std::uint8_t>(a >> (index * 8));
            }
            code_cursor += bytes;
        } else {
            return fail();
        }
    }
    if (!have_pc) {
        error = "fixture has no pc";
        return false;
    }
    // Code directives advance the parser cursor; execution starts at the declared base.
    fixture.state.regs[15] = entry_pc;
    fixture.state.cpsr = (fixture.state.cpsr & ~0x20U) | (fixture.thumb ? 0x20U : 0U);
    return true;
}

bool MapBinary(const std::filesystem::path& path, const std::uint32_t base, Host& host,
               std::string& error) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error = "cannot open binary memory: " + path.string();
        return false;
    }
    std::vector<std::uint8_t> bytes(std::istreambuf_iterator<char>(input), {});
    if (input.bad() || static_cast<std::uint64_t>(base) + bytes.size() > host.memory.size()) {
        error = "binary memory does not fit fixture: " + path.string();
        return false;
    }
    std::copy(bytes.begin(), bytes.end(), host.memory.begin() + base);
    return true;
}

Callbacks MakeCallbacks(Host& host) {
    return {&host, ReadCallback, WriteCallback, SvcCallback, TicksCallback,
            CoprocessorReadCallback, CoprocessorWriteCallback};
}

std::string Format(const GuestCpuState& state, const Host& host) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (std::size_t index = 0; index < state.regs.size(); ++index) {
        out << "r" << std::dec << index << '=' << std::hex << std::setw(8) << state.regs[index] << '\n';
    }
    out << "cpsr=" << std::setw(8) << state.cpsr << '\n';
    for (std::size_t index = 0; index < state.ext_regs.size(); ++index) {
        out << "ext" << std::dec << index << '=' << std::hex << std::setw(8) << state.ext_regs[index] << '\n';
    }
    out << "fpscr=" << std::setw(8) << state.fpscr << '\n';
    out << "fpexc=" << std::setw(8) << state.fpexc << '\n';
    out << "ticks_elapsed=" << std::dec << host.ticks_elapsed << '\n';
    out << "ticks_remaining=" << host.ticks_remaining << '\n';
    out << "cp15_thread_uprw=" << std::hex << std::setw(8) << host.cp15_thread_uprw << '\n';
    out << "cp15_thread_uro=" << std::setw(8) << host.cp15_thread_uro << '\n';
    out << "coprocessor_reads=" << std::dec << host.coprocessor_reads << '\n';
    out << "coprocessor_writes=" << host.coprocessor_writes << '\n';
    out << "svc=";
    for (std::size_t index = 0; index < host.svc_calls.size(); ++index) {
        if (index) out << ',';
        out << host.svc_calls[index];
    }
    out << "\nmemory=";
    for (const std::uint8_t byte : host.memory) out << std::hex << std::setw(2) << static_cast<unsigned>(byte);
    out << '\n';
    return out.str();
}

std::string FormatSummary(const GuestCpuState& state, const Host& host,
                          const std::vector<std::uint8_t>& initial_memory) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (std::size_t index = 0; index < state.regs.size(); ++index) {
        out << "r" << std::dec << index << '=' << std::hex << std::setw(8)
            << state.regs[index] << '\n';
    }
    out << "cpsr=" << std::setw(8) << state.cpsr << '\n';
    for (std::size_t index = 0; index < state.ext_regs.size(); ++index) {
        out << "ext" << std::dec << index << '=' << std::hex << std::setw(8)
            << state.ext_regs[index] << '\n';
    }
    out << "fpscr=" << std::setw(8) << state.fpscr << '\n';
    out << "fpexc=" << std::setw(8) << state.fpexc << '\n';
    out << "ticks_elapsed=" << std::dec << host.ticks_elapsed << '\n';
    out << "ticks_remaining=" << host.ticks_remaining << '\n';
    out << "cp15_thread_uprw=" << std::hex << std::setw(8) << host.cp15_thread_uprw << '\n';
    out << "cp15_thread_uro=" << std::setw(8) << host.cp15_thread_uro << '\n';
    out << "svc=";
    for (std::size_t index = 0; index < host.svc_calls.size(); ++index) {
        if (index) out << ',';
        out << std::dec << host.svc_calls[index];
    }
    out << "\nmemory_sha256=" << MemorySha256(host.memory) << '\n';
    std::size_t changed = 0;
    if (initial_memory.size() == host.memory.size()) {
        for (std::size_t index = 0; index < host.memory.size(); ++index) {
            changed += initial_memory[index] != host.memory[index];
        }
    } else {
        changed = std::max(initial_memory.size(), host.memory.size());
    }
    out << "memory_changed_bytes=" << std::dec << changed << '\n';
    return out.str();
}

}  // namespace mh4u::aot::fixture
