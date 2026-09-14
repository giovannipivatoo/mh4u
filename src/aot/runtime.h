#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace mh4u::aot {

struct GuestCpuState {
    std::array<std::uint32_t, 16> regs{};
    std::uint32_t cpsr{};
    std::array<std::uint32_t, 64> ext_regs{};
    std::uint32_t fpscr{};
    std::uint32_t fpexc{};
};

struct Callbacks {
    void* context{};
    bool (*read)(void*, std::uint32_t address, unsigned bits, std::uint64_t* value){};
    bool (*write)(void*, std::uint32_t address, unsigned bits, std::uint64_t value){};
    bool (*svc)(void*, GuestCpuState* state, std::uint32_t number, bool* halt){};
    bool (*add_ticks)(void*, std::uint64_t elapsed, std::uint64_t* remaining){};
    bool (*coprocessor_read32)(void*, const std::uint8_t info[8], std::uint32_t* value){};
    bool (*coprocessor_write32)(void*, const std::uint8_t info[8], std::uint32_t value){};
    bool (*exclusive_read32)(void*, std::uint32_t address, std::uint32_t* value){};
    bool (*exclusive_write32)(void*, std::uint32_t address, std::uint32_t value,
                              bool* succeeded){};
    bool (*clear_exclusive)(void*){};
};

enum class BlockExit : std::uint32_t {
    Linked,
    Dispatch,
    SupervisorCall,
    MemoryFault,
    CallbackFault,
    WrongLocation,
    MissingBlock,
    DispatcherLimit,
};

struct BlockResult {
    BlockExit exit{BlockExit::Dispatch};
    std::uint32_t next_pc{};
    std::uint32_t detail{};
    std::uint64_t remaining_ticks{};
};

struct CodeWord {
    std::uint32_t address{};
    std::uint32_t value{};
};

struct ArtifactIdentity {
    const CodeWord* code_words{};
    std::size_t code_word_count{};
    const char* input_sha256{};
};

struct AddResult32 {
    std::uint32_t value{};
    std::uint32_t nzcv{};
};

AddResult32 Add32(std::uint32_t lhs, std::uint32_t rhs, bool carry);
AddResult32 Sub32(std::uint32_t lhs, std::uint32_t rhs, bool carry);
AddResult32 LogicalShiftLeft32(std::uint32_t value, std::uint8_t amount, bool carry);
AddResult32 LogicalShiftRight32(std::uint32_t value, std::uint8_t amount, bool carry);
AddResult32 ArithmeticShiftRight32(std::uint32_t value, std::uint8_t amount, bool carry);
AddResult32 RotateRight32(std::uint32_t value, std::uint8_t amount, bool carry);
AddResult32 RotateRightExtended(std::uint32_t value, bool carry);
bool ConditionPassed(std::uint32_t cpsr, std::uint8_t condition);
bool Read(const Callbacks& callbacks, std::uint32_t address, unsigned bits, std::uint64_t& value);
bool Write(const Callbacks& callbacks, std::uint32_t address, unsigned bits, std::uint64_t value);
bool AddTicks(const Callbacks& callbacks, std::uint64_t elapsed, std::uint64_t& remaining);
bool CallSvc(const Callbacks& callbacks, GuestCpuState& state, std::uint32_t number, bool& halt);
bool CoprocessorRead32(const Callbacks& callbacks, const std::uint8_t info[8], std::uint32_t& value);
bool CoprocessorWrite32(const Callbacks& callbacks, const std::uint8_t info[8], std::uint32_t value);
bool ExclusiveRead32(const Callbacks& callbacks, std::uint32_t address, std::uint32_t& value);
bool ExclusiveWrite32(const Callbacks& callbacks, std::uint32_t address, std::uint32_t value,
                      bool& succeeded);
bool ClearExclusive(const Callbacks& callbacks);
void SetLocation(GuestCpuState& state, std::uint32_t pc, std::uint32_t cpsr_mode,
                 std::uint32_t fpscr_mode);
void BranchExchange(GuestCpuState& state, std::uint32_t address, std::uint32_t cpsr_mode,
                    std::uint32_t fpscr_mode);

}  // namespace mh4u::aot

mh4u::aot::BlockResult mh4u_aot_execute(
    mh4u::aot::GuestCpuState* state, const mh4u::aot::Callbacks* callbacks);
const mh4u::aot::ArtifactIdentity* mh4u_aot_identity();
