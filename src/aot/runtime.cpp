#include "aot/runtime.h"

#include <limits>

namespace mh4u::aot {
namespace {

std::uint32_t Nz(const std::uint32_t value) {
    return (value & 0x80000000U) | (value == 0 ? 0x40000000U : 0U);
}

}  // namespace

AddResult32 Add32(const std::uint32_t lhs, const std::uint32_t rhs, const bool carry) {
    const std::uint64_t wide = static_cast<std::uint64_t>(lhs) + rhs + (carry ? 1U : 0U);
    const std::uint32_t value = static_cast<std::uint32_t>(wide);
    const bool overflow = ((~(lhs ^ rhs) & (lhs ^ value)) >> 31) != 0;
    return {value, (value & 0x80000000U) | (value == 0 ? 0x40000000U : 0U) |
                       (wide > std::numeric_limits<std::uint32_t>::max() ? 0x20000000U : 0U) |
                       (overflow ? 0x10000000U : 0U)};
}

AddResult32 Sub32(const std::uint32_t lhs, const std::uint32_t rhs, const bool carry) {
    return Add32(lhs, ~rhs, carry);
}

AddResult32 LogicalShiftLeft32(const std::uint32_t value, const std::uint8_t amount,
                               const bool carry) {
    if (amount == 0) return {value, Nz(value) | (carry ? 0x20000000U : 0U)};
    if (amount < 32) {
        const auto result = value << amount;
        return {result, Nz(result) | (((value >> (32 - amount)) & 1U) << 29)};
    }
    if (amount == 32) return {0, 0x40000000U | ((value & 1U) << 29)};
    return {0, 0x40000000U};
}

AddResult32 LogicalShiftRight32(const std::uint32_t value, const std::uint8_t amount,
                                const bool carry) {
    if (amount == 0) return {value, Nz(value) | (carry ? 0x20000000U : 0U)};
    if (amount < 32) {
        const auto result = value >> amount;
        return {result, Nz(result) | (((value >> (amount - 1)) & 1U) << 29)};
    }
    if (amount == 32) return {0, 0x40000000U | (((value >> 31) & 1U) << 29)};
    return {0, 0x40000000U};
}

AddResult32 ArithmeticShiftRight32(const std::uint32_t value, const std::uint8_t amount,
                                   const bool carry) {
    if (amount == 0) return {value, Nz(value) | (carry ? 0x20000000U : 0U)};
    if (amount < 32) {
        const std::uint32_t shifted = static_cast<std::uint32_t>(static_cast<std::int32_t>(value) >> amount);
        return {shifted, Nz(shifted) | (((value >> (amount - 1)) & 1U) << 29)};
    }
    const bool sign = (value >> 31) != 0;
    const auto result = sign ? UINT32_MAX : 0U;
    return {result, Nz(result) | (sign ? 0x20000000U : 0U)};
}

AddResult32 RotateRight32(const std::uint32_t value, const std::uint8_t amount,
                          const bool carry) {
    if (amount == 0) return {value, Nz(value) | (carry ? 0x20000000U : 0U)};
    const unsigned rotate = amount & 31U;
    const std::uint32_t shifted = rotate == 0 ? value : (value >> rotate) | (value << (32 - rotate));
    return {shifted, Nz(shifted) | (((shifted >> 31) & 1U) << 29)};
}

bool ConditionPassed(const std::uint32_t cpsr, const std::uint8_t condition) {
    const bool n = (cpsr & 0x80000000U) != 0;
    const bool z = (cpsr & 0x40000000U) != 0;
    const bool c = (cpsr & 0x20000000U) != 0;
    const bool v = (cpsr & 0x10000000U) != 0;
    switch (condition) {
    case 0: return z;
    case 1: return !z;
    case 2: return c;
    case 3: return !c;
    case 4: return n;
    case 5: return !n;
    case 6: return v;
    case 7: return !v;
    case 8: return c && !z;
    case 9: return !c || z;
    case 10: return n == v;
    case 11: return n != v;
    case 12: return !z && n == v;
    case 13: return z || n != v;
    case 14: return true;
    default: return false;
    }
}

bool Read(const Callbacks& callbacks, const std::uint32_t address, const unsigned bits,
          std::uint64_t& value) {
    return callbacks.read && callbacks.read(callbacks.context, address, bits, &value);
}

bool Write(const Callbacks& callbacks, const std::uint32_t address, const unsigned bits,
           const std::uint64_t value) {
    return callbacks.write && callbacks.write(callbacks.context, address, bits, value);
}

bool AddTicks(const Callbacks& callbacks, const std::uint64_t elapsed, std::uint64_t& remaining) {
    return callbacks.add_ticks && callbacks.add_ticks(callbacks.context, elapsed, &remaining);
}

bool CallSvc(const Callbacks& callbacks, GuestCpuState& state, const std::uint32_t number,
             bool& halt) {
    return callbacks.svc && callbacks.svc(callbacks.context, &state, number, &halt);
}

bool CoprocessorRead32(const Callbacks& callbacks, const std::uint8_t info[8],
                       std::uint32_t& value) {
    return callbacks.coprocessor_read32 &&
           callbacks.coprocessor_read32(callbacks.context, info, &value);
}

bool CoprocessorWrite32(const Callbacks& callbacks, const std::uint8_t info[8],
                        const std::uint32_t value) {
    return callbacks.coprocessor_write32 &&
           callbacks.coprocessor_write32(callbacks.context, info, value);
}

void SetLocation(GuestCpuState& state, const std::uint32_t pc, const std::uint32_t cpsr_mode,
                 const std::uint32_t fpscr_mode) {
    state.regs[15] = pc;
    state.cpsr = (state.cpsr & ~0x0600fe20U) | (cpsr_mode & 0x0600fe20U);
    state.fpscr = (state.fpscr & ~0x07f70000U) | (fpscr_mode & 0x07f70000U);
}

void BranchExchange(GuestCpuState& state, const std::uint32_t address,
                    const std::uint32_t cpsr_mode, const std::uint32_t fpscr_mode) {
    const bool thumb = (address & 1U) != 0;
    SetLocation(state, address & (thumb ? ~1U : ~3U),
                (cpsr_mode & ~0x20U) | (thumb ? 0x20U : 0U), fpscr_mode);
}

}  // namespace mh4u::aot
