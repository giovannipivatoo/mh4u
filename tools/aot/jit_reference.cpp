#include "fixture.h"

#include <dynarmic/interface/A32/a32.h>
#include <dynarmic/interface/A32/config.h>
#include <dynarmic/interface/exclusive_monitor.h>

#include "core/arm/dynarmic/arm_tick_counts.h"
#include "core/arm/dynarmic/arm_dynarmic_cp15.h"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>

namespace {

class Callbacks final : public Dynarmic::A32::UserCallbacks {
public:
    explicit Callbacks(mh4u::aot::fixture::Host& host_) : host(host_) {}

    Dynarmic::A32::Jit* jit{};

    std::uint8_t MemoryRead8(const std::uint32_t address) override {
        if (address >= host.memory.size()) throw std::runtime_error("JIT read8 outside fixture");
        return host.memory[address];
    }
    std::uint16_t MemoryRead16(const std::uint32_t address) override {
        return static_cast<std::uint16_t>(MemoryRead8(address)) |
               static_cast<std::uint16_t>(MemoryRead8(address + 1)) << 8;
    }
    std::uint32_t MemoryRead32(const std::uint32_t address) override {
        return static_cast<std::uint32_t>(MemoryRead16(address)) |
               static_cast<std::uint32_t>(MemoryRead16(address + 2)) << 16;
    }
    std::uint64_t MemoryRead64(const std::uint32_t address) override {
        return static_cast<std::uint64_t>(MemoryRead32(address)) |
               static_cast<std::uint64_t>(MemoryRead32(address + 4)) << 32;
    }
    void MemoryWrite8(const std::uint32_t address, const std::uint8_t value) override {
        if (address >= host.memory.size()) throw std::runtime_error("JIT write8 outside fixture");
        host.memory[address] = value;
    }
    void MemoryWrite16(const std::uint32_t address, const std::uint16_t value) override {
        MemoryWrite8(address, static_cast<std::uint8_t>(value));
        MemoryWrite8(address + 1, static_cast<std::uint8_t>(value >> 8));
    }
    void MemoryWrite32(const std::uint32_t address, const std::uint32_t value) override {
        MemoryWrite16(address, static_cast<std::uint16_t>(value));
        MemoryWrite16(address + 2, static_cast<std::uint16_t>(value >> 16));
    }
    void MemoryWrite64(const std::uint32_t address, const std::uint64_t value) override {
        MemoryWrite32(address, static_cast<std::uint32_t>(value));
        MemoryWrite32(address + 4, static_cast<std::uint32_t>(value >> 32));
    }
    bool MemoryWriteExclusive32(const std::uint32_t address, const std::uint32_t value,
                                const std::uint32_t expected) override {
        if (MemoryRead32(address) != expected) return false;
        MemoryWrite32(address, value);
        return true;
    }
    void InterpreterFallback(std::uint32_t pc, std::size_t) override {
        throw std::runtime_error("unexpected interpreter fallback at " + std::to_string(pc));
    }
    void CallSVC(const std::uint32_t number) override {
        host.svc_calls.push_back(number);
        jit->Regs()[0] ^= 0x13579bdfU;
        jit->HaltExecution();
    }
    void ExceptionRaised(std::uint32_t pc, Dynarmic::A32::Exception) override {
        throw std::runtime_error("unexpected guest exception at " + std::to_string(pc));
    }
    void AddTicks(const std::uint64_t ticks) override {
        host.ticks_elapsed += ticks;
        host.ticks_remaining = ticks >= host.ticks_remaining ? 0 : host.ticks_remaining - ticks;
    }
    std::uint64_t GetTicksRemaining() override { return host.ticks_remaining; }
    std::uint64_t GetTicksForCode(const bool thumb, std::uint32_t,
                                  const std::uint32_t instruction) override {
        return Core::TicksForInstruction(thumb, instruction);
    }

private:
    mh4u::aot::fixture::Host& host;
};

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2 && argc != 3) {
            std::cerr << "usage: aot-jit-reference FIXTURE [CODE_BIN]\n";
            return 2;
        }
        mh4u::aot::fixture::Fixture fixture;
        std::string error;
        if (!mh4u::aot::fixture::Load(argv[1], fixture, error)) throw std::runtime_error(error);
        mh4u::aot::fixture::Host host;
        host.memory = fixture.memory;
        host.ticks_remaining = fixture.ticks_remaining;
        if (argc == 3 && !mh4u::aot::fixture::MapBinary(argv[2], fixture.base, host, error)) {
            throw std::runtime_error(error);
        }
        const auto initial_memory = host.memory;
        Callbacks callbacks{host};
        Dynarmic::A32::UserConfig config;
        config.callbacks = &callbacks;
        Dynarmic::ExclusiveMonitor exclusive_monitor{1};
        config.global_monitor = &exclusive_monitor;
        config.arch_version = Dynarmic::A32::ArchVersion::v6K;
        config.define_unpredictable_behaviour = true;
        CP15State cp15_state{host.cp15_thread_uprw, host.cp15_thread_uro};
        config.coprocessors[15] = std::make_shared<DynarmicCP15>(cp15_state);
        Dynarmic::A32::Jit jit{config};
        callbacks.jit = &jit;
        jit.Regs() = fixture.state.regs;
        jit.ExtRegs() = fixture.state.ext_regs;
        jit.SetCpsr(fixture.state.cpsr);
        jit.SetFpscr(fixture.state.fpscr);
        jit.Run();
        fixture.state.regs = jit.Regs();
        fixture.state.ext_regs = jit.ExtRegs();
        fixture.state.cpsr = jit.Cpsr();
        fixture.state.fpscr = jit.Fpscr();
        host.cp15_thread_uprw = cp15_state.cp15_thread_uprw;
        host.cp15_thread_uro = cp15_state.cp15_thread_uro;
        std::cout << (argc == 3 ? mh4u::aot::fixture::FormatSummary(fixture.state, host, initial_memory)
                               : mh4u::aot::fixture::Format(fixture.state, host));
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "aot-jit-reference: " << error.what() << '\n';
        return 1;
    }
}
