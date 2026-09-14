#include "fixture.h"

#include <dynarmic/frontend/A32/FPSCR.h>
#include <dynarmic/frontend/A32/PSR.h>
#include <dynarmic/frontend/A32/a32_location_descriptor.h>
#include <dynarmic/frontend/A32/a32_types.h>
#include <dynarmic/frontend/A32/translate/a32_translate.h>
#include <dynarmic/frontend/A32/translate/translate_callbacks.h>
#include <dynarmic/ir/basic_block.h>
#include <dynarmic/ir/opcodes.h>

#include "core/arm/dynarmic/arm_tick_counts.h"

#include <boost/variant/get.hpp>
#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

namespace A32 = Dynarmic::A32;
namespace IR = Dynarmic::IR;
using mh4u::aot::fixture::Fixture;

std::string Hex(std::uint64_t value);

struct EntryDescriptor {
    std::uint32_t pc{};
    std::uint32_t cpsr{};
    std::uint32_t fpscr{};
};

struct Options {
    std::filesystem::path fixture;
    std::filesystem::path binary;
    std::filesystem::path output;
    std::filesystem::path manifest;
    std::filesystem::path artifact_root;
    std::string input_sha256;
    std::uint32_t base{};
    std::uint32_t pc{};
    std::uint32_t cpsr{0x10};
    std::uint32_t fpscr{};
    std::size_t max_blocks{1};
    std::size_t max_instructions{1024};
    std::size_t max_dispatch_steps{1000000};
    bool continue_after_svc{};
    std::vector<EntryDescriptor> extra_entries;
};

std::uint64_t ParseNumber(const std::string& text) {
    if (text.empty() || text.front() == '-') throw std::runtime_error("invalid number: " + text);
    std::size_t end = 0;
    const auto result = std::stoull(text, &end, 0);
    if (end != text.size()) throw std::runtime_error("invalid number: " + text);
    return result;
}

std::uint32_t ParseU32(const std::string& text) {
    const auto value = ParseNumber(text);
    if (value > UINT32_MAX) throw std::runtime_error("32-bit value out of range: " + text);
    return static_cast<std::uint32_t>(value);
}

EntryDescriptor ParseEntryDescriptor(const std::string& text) {
    const auto first = text.find(',');
    const auto second = first == std::string::npos ? first : text.find(',', first + 1);
    if (first == std::string::npos || second == std::string::npos ||
        text.find(',', second + 1) != std::string::npos) {
        throw std::runtime_error("entry descriptor must be PC,CPSR,FPSCR: " + text);
    }
    return {ParseU32(text.substr(0, first)),
            ParseU32(text.substr(first + 1, second - first - 1)),
            ParseU32(text.substr(second + 1))};
}

Options ParseOptions(const int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string key = argv[index];
        if (index + 1 >= argc) throw std::runtime_error("missing value for " + key);
        const std::string value = argv[++index];
        if (key == "--fixture") options.fixture = value;
        else if (key == "--binary") options.binary = value;
        else if (key == "--output") options.output = value;
        else if (key == "--manifest") options.manifest = value;
        else if (key == "--artifact-root") options.artifact_root = value;
        else if (key == "--input-sha256") options.input_sha256 = value;
        else if (key == "--base") options.base = ParseU32(value);
        else if (key == "--pc") options.pc = ParseU32(value);
        else if (key == "--cpsr") options.cpsr = ParseU32(value);
        else if (key == "--fpscr") options.fpscr = ParseU32(value);
        else if (key == "--max-blocks") options.max_blocks = ParseNumber(value);
        else if (key == "--max-instructions") options.max_instructions = ParseNumber(value);
        else if (key == "--max-dispatch-steps") options.max_dispatch_steps = ParseNumber(value);
        else if (key == "--entry-descriptor") {
            options.extra_entries.push_back(ParseEntryDescriptor(value));
        }
        else if (key == "--continue-after-svc") {
            const auto enabled = ParseNumber(value);
            if (enabled > 1) throw std::runtime_error("--continue-after-svc must be 0 or 1");
            options.continue_after_svc = enabled != 0;
        }
        else throw std::runtime_error("unknown option: " + key);
    }
    if ((options.fixture.empty() == options.binary.empty()) || options.output.empty() ||
        options.manifest.empty() || options.artifact_root.empty() || options.input_sha256.empty()) {
        throw std::runtime_error(
            "usage: aot-generator (--fixture FILE | --binary FILE --base N --pc N --cpsr N) "
            "--input-sha256 SHA256 --artifact-root DIR --output CPP --manifest JSON "
            "[--fpscr N] [--entry-descriptor PC,CPSR,FPSCR]");
    }
    if (options.max_blocks == 0 || options.max_instructions == 0 || options.max_dispatch_steps == 0) {
        throw std::runtime_error("translation limits must be positive");
    }
    return options;
}

struct Source final : A32::TranslateCallbacks {
    std::vector<std::uint8_t> bytes;
    std::uint32_t mapped_base{};
    bool absolute_addresses{};
    std::size_t code_reads{};
    std::size_t max_code_reads{1024};
    std::map<std::uint32_t, std::uint32_t> code_words;

    std::optional<std::uint32_t> MemoryReadCode(const std::uint32_t address) override {
        if (!absolute_addresses && address < mapped_base) return std::nullopt;
        const std::uint64_t offset = absolute_addresses ? address : address - mapped_base;
        if (offset > bytes.size() || bytes.size() - offset < 4) return std::nullopt;
        const std::uint32_t value = static_cast<std::uint32_t>(bytes[offset]) |
                                    (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
                                    (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
                                    (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
        code_words[address] = value;
        return value;
    }
    bool PreCodeReadHook(bool, const std::uint32_t pc, A32::IREmitter&) override {
        if (code_reads >= max_code_reads) {
            throw std::runtime_error("AOT guest instruction fetch limit reached at PC " + Hex(pc));
        }
        ++code_reads;
        return true;
    }
    void PreCodeTranslationHook(bool, std::uint32_t, A32::IREmitter&) override {}
    std::uint64_t GetTicksForCode(const bool thumb, std::uint32_t,
                                  const std::uint32_t instruction) override {
        return Core::TicksForInstruction(thumb, instruction);
    }
};

std::string Hex(const std::uint64_t value) {
    std::ostringstream out;
    out << "0x" << std::hex << value;
    return out.str();
}

struct Emission {
    std::string source;
    std::vector<std::string> opcodes;
    std::uint32_t next_pc{};
};

class Emitter {
public:
    explicit Emitter(const IR::Block& block_, std::string function_name_ = "mh4u_aot_execute",
                     const bool internal_ = false)
            : block(block_), function_name(std::move(function_name_)), internal(internal_) {
        unsigned id = 0;
        for (const IR::Inst& inst : block) {
            names.emplace(&inst, id++);
            has_bx |= inst.GetOpcode() == IR::Opcode::A32BXWritePC;
        }
    }

    Emission Emit() {
        out << "#include \"aot/runtime.h\"\n\n";
        if (internal) out << "static ";
        out << "mh4u::aot::BlockResult " << function_name << "(\n"
               "    mh4u::aot::GuestCpuState* state, const mh4u::aot::Callbacks* callbacks) {\n"
               "  using namespace mh4u::aot;\n"
               "  if (!state || !callbacks || !callbacks->read || !callbacks->write ||\n"
               "      !callbacks->svc || !callbacks->add_ticks || !callbacks->coprocessor_read32 ||\n"
               "      !callbacks->coprocessor_write32 || !callbacks->exclusive_read32 ||\n"
               "      !callbacks->exclusive_write32 || !callbacks->clear_exclusive)\n"
               "    return {BlockExit::CallbackFault, state ? state->regs[15] : 0, 0, 0};\n"
               "  std::uint64_t remaining = 0;\n";
        const A32::LocationDescriptor entry{block.Location()};
        out << "  if (state->regs[15] != " << Hex(entry.PC())
            << "U || (state->cpsr & 0x0600fe20U) != "
            << Hex(entry.CPSR().Value() & 0x0600fe20U)
            << "U || (state->fpscr & 0x07f70000U) != "
            << Hex(entry.FPSCR().Value() & 0x07f70000U)
            << "U) return {BlockExit::WrongLocation, state->regs[15], " << Hex(entry.PC())
            << "U, 0};\n"
            << "  if (!AddTicks(*callbacks, 0, remaining)) return {BlockExit::CallbackFault, state->regs[15], 0, 0};\n"
            << "  if (remaining == 0) return {BlockExit::Dispatch, state->regs[15], 0, 0};\n";
        if (block.GetCondition() != IR::Cond::AL) {
            if (!block.HasConditionFailedLocation()) {
                throw Unsupported("conditional block has no failure location at guest PC " + Hex(entry.PC()));
            }
            const A32::LocationDescriptor failed{block.ConditionFailedLocation()};
            out << "  if (!ConditionPassed(state->cpsr, "
                << static_cast<unsigned>(block.GetCondition()) << "U)) {\n"
                << "    if (!AddTicks(*callbacks, " << block.ConditionFailedCycleCount()
                << "U, remaining)) return {BlockExit::CallbackFault, state->regs[15], 0, remaining};\n"
                << "    SetLocation(*state, " << Hex(failed.PC()) << "U, "
                << Hex(failed.CPSR().Value() & 0x0600fe20U) << "U, "
                << Hex(failed.FPSCR().Value() & 0x07f70000U) << "U);\n"
                << "    return {BlockExit::Linked, state->regs[15], 0, remaining};\n  }\n";
        }
        for (const IR::Inst& inst : block) EmitInst(inst);
        EmitTerminal(block.GetTerminal());
        out << "}\n";
        return {out.str(), opcodes, next_pc};
    }

private:
    class Unsupported final : public std::runtime_error {
    public:
        using std::runtime_error::runtime_error;
    };

    const IR::Block& block;
    std::ostringstream out;
    std::unordered_map<const IR::Inst*, unsigned> names;
    std::unordered_map<const IR::Inst*, bool> arithmetic;
    std::vector<std::string> opcodes;
    std::uint32_t next_pc{};
    bool ticks_added{};
    bool has_bx{};
    std::string function_name;
    bool internal{};

    [[noreturn]] void Fail(const IR::Inst& inst) const {
        throw Unsupported("unsupported IR opcode at guest PC " + Hex(block.Location().Value() & 0xffffffffU) +
                          ": " + IR::GetNameOf(inst.GetOpcode()) + " (IR " +
                          std::to_string(names.at(&inst)) + ")");
    }

    std::string Expr(const IR::Value& value) const {
        if (value.IsImmediate()) return Hex(value.GetImmediateAsU64()) + "U";
        const IR::Inst* inst = value.GetInst();
        const auto found = names.find(inst);
        if (found == names.end()) throw Unsupported("IR value refers outside block");
        const auto arithmetic_result = arithmetic.find(inst);
        return "v" + std::to_string(found->second) +
               (arithmetic_result != arithmetic.end() && arithmetic_result->second ? ".value" : "");
    }

    std::string Name(const IR::Inst& inst) const { return "v" + std::to_string(names.at(&inst)); }

    void EmitInst(const IR::Inst& inst) {
        const auto op = inst.GetOpcode();
        opcodes.push_back(IR::GetNameOf(op));
        const std::string name = Name(inst);
        switch (op) {
        case IR::Opcode::PushRSB:
            out << "  // PushRSB is a dispatcher cache hint.\n";
            return;
        case IR::Opcode::A32GetRegister:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = state->regs["
                << static_cast<unsigned>(inst.GetArg(0).GetA32RegRef()) << "];\n";
            return;
        case IR::Opcode::A32SetRegister:
            out << "  state->regs[" << static_cast<unsigned>(inst.GetArg(0).GetA32RegRef())
                << "] = " << Expr(inst.GetArg(1)) << ";\n";
            return;
        case IR::Opcode::A32GetCFlag:
            out << "  [[maybe_unused]] const bool " << name << " = ((state->cpsr >> 29) & 1U) != 0;\n";
            return;
        case IR::Opcode::A32GetFpscr:
            out << "  [[maybe_unused]] const std::uint32_t " << name
                << " = state->fpscr;\n";
            return;
        case IR::Opcode::A32SetFpscr:
            out << "  state->fpscr = static_cast<std::uint32_t>(" << Expr(inst.GetArg(0))
                << ") & 0xfff7009fU;\n";
            return;
        case IR::Opcode::Not32:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = ~static_cast<std::uint32_t>("
                << Expr(inst.GetArg(0)) << ");\n";
            return;
        case IR::Opcode::And32:
        case IR::Opcode::Eor32:
        case IR::Opcode::Or32: {
            const char* symbol = op == IR::Opcode::And32 ? "&" : op == IR::Opcode::Eor32 ? "^" : "|";
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = " << Expr(inst.GetArg(0)) << ' '
                << symbol << ' ' << Expr(inst.GetArg(1)) << ";\n";
            return;
        }
        case IR::Opcode::AndNot32:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = "
                << Expr(inst.GetArg(0)) << " & ~static_cast<std::uint32_t>("
                << Expr(inst.GetArg(1)) << ");\n";
            return;
        case IR::Opcode::Add32:
        case IR::Opcode::Sub32:
            arithmetic[&inst] = true;
            out << "  [[maybe_unused]] const auto " << name << " = "
                << (op == IR::Opcode::Add32 ? "Add32" : "Sub32") << "("
                << Expr(inst.GetArg(0)) << ", " << Expr(inst.GetArg(1)) << ", "
                << Expr(inst.GetArg(2)) << " != 0);\n";
            return;
        case IR::Opcode::LogicalShiftLeft32:
        case IR::Opcode::LogicalShiftRight32:
        case IR::Opcode::ArithmeticShiftRight32:
        case IR::Opcode::RotateRight32: {
            arithmetic[&inst] = true;
            const char* function = op == IR::Opcode::LogicalShiftLeft32 ? "LogicalShiftLeft32" :
                                   op == IR::Opcode::LogicalShiftRight32 ? "LogicalShiftRight32" :
                                   op == IR::Opcode::ArithmeticShiftRight32 ? "ArithmeticShiftRight32" :
                                   "RotateRight32";
            out << "  [[maybe_unused]] const auto " << name << " = " << function << "("
                << Expr(inst.GetArg(0)) << ", static_cast<std::uint8_t>(" << Expr(inst.GetArg(1))
                << "), " << Expr(inst.GetArg(2)) << " != 0);\n";
            return;
        }
        case IR::Opcode::RotateRightExtended:
            arithmetic[&inst] = true;
            out << "  [[maybe_unused]] const auto " << name << " = RotateRightExtended("
                << Expr(inst.GetArg(0)) << ", " << Expr(inst.GetArg(1)) << " != 0);\n";
            return;
        case IR::Opcode::GetNZCVFromOp:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = "
                << "v" << names.at(inst.GetArg(0).GetInst()) << ".nzcv;\n";
            return;
        case IR::Opcode::GetNZFromOp:
            if (inst.GetArg(0).IsImmediate()) {
                const auto value = static_cast<std::uint32_t>(inst.GetArg(0).GetImmediateAsU64());
                out << "  [[maybe_unused]] const std::uint32_t " << name << " = "
                    << Hex((value & 0x80000000U) | (value == 0 ? 0x40000000U : 0U)) << "U;\n";
            } else {
                const IR::Inst* parent = inst.GetArg(0).GetInst();
                if (arithmetic.contains(parent)) {
                    out << "  [[maybe_unused]] const std::uint32_t " << name << " = v"
                        << names.at(parent) << ".nzcv & 0xc0000000U;\n";
                } else {
                    const std::string value = Expr(inst.GetArg(0));
                    out << "  [[maybe_unused]] const std::uint32_t " << name << " = ("
                        << value << " & 0x80000000U) | (" << value << " == 0 ? 0x40000000U : 0U);\n";
                }
            }
            return;
        case IR::Opcode::A32UpdateUpperLocationDescriptor:
            if (!has_bx) {
                const A32::LocationDescriptor end{block.EndLocation()};
                out << "  SetLocation(*state, state->regs[15], "
                    << Hex(end.CPSR().Value() & 0x0600fe20U) << "U, "
                    << Hex(end.FPSCR().Value() & 0x07f70000U) << "U);\n";
            }
            return;
        case IR::Opcode::A32BXWritePC: {
            const A32::LocationDescriptor end{block.EndLocation()};
            out << "  BranchExchange(*state, " << Expr(inst.GetArg(0)) << ", "
                << Hex(end.CPSR().Value() & 0x0600fe20U) << "U, "
                << Hex(end.FPSCR().Value() & 0x07f70000U) << "U);\n";
            return;
        }
        case IR::Opcode::GetCarryFromOp:
            out << "  [[maybe_unused]] const bool " << name << " = (v" << names.at(inst.GetArg(0).GetInst())
                << ".nzcv & 0x20000000U) != 0;\n";
            return;
        case IR::Opcode::GetOverflowFromOp:
            out << "  [[maybe_unused]] const bool " << name << " = (v" << names.at(inst.GetArg(0).GetInst())
                << ".nzcv & 0x10000000U) != 0;\n";
            return;
        case IR::Opcode::MostSignificantBit:
            out << "  [[maybe_unused]] const bool " << name << " = (" << Expr(inst.GetArg(0)) << " >> 31) != 0;\n";
            return;
        case IR::Opcode::IsZero32:
            out << "  [[maybe_unused]] const bool " << name << " = " << Expr(inst.GetArg(0)) << " == 0;\n";
            return;
        case IR::Opcode::LeastSignificantByte:
        case IR::Opcode::ZeroExtendByteToWord:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = static_cast<std::uint8_t>("
                << Expr(inst.GetArg(0)) << ");\n";
            return;
        case IR::Opcode::SignExtendByteToWord:
            out << "  [[maybe_unused]] const std::uint32_t " << name
                << " = static_cast<std::uint32_t>(static_cast<std::int32_t>("
                   "static_cast<std::int8_t>("
                << Expr(inst.GetArg(0)) << ")));\n";
            return;
        case IR::Opcode::LeastSignificantHalf:
        case IR::Opcode::ZeroExtendHalfToWord:
            out << "  [[maybe_unused]] const std::uint32_t " << name << " = static_cast<std::uint16_t>("
                << Expr(inst.GetArg(0)) << ");\n";
            return;
        case IR::Opcode::Pack2x32To1x64:
            out << "  [[maybe_unused]] const std::uint64_t " << name
                << " = static_cast<std::uint64_t>(" << Expr(inst.GetArg(0))
                << ") | (static_cast<std::uint64_t>(" << Expr(inst.GetArg(1)) << ") << 32);\n";
            return;
        case IR::Opcode::LeastSignificantWord:
            out << "  [[maybe_unused]] const std::uint32_t " << name
                << " = static_cast<std::uint32_t>(" << Expr(inst.GetArg(0)) << ");\n";
            return;
        case IR::Opcode::MostSignificantWord:
            arithmetic[&inst] = true;
            out << "  [[maybe_unused]] const std::uint32_t " << name
                << "Value = static_cast<std::uint32_t>(" << Expr(inst.GetArg(0)) << " >> 32);\n"
                << "  [[maybe_unused]] const AddResult32 " << name << "{" << name << "Value, ("
                << name << "Value & 0x80000000U) | (" << name
                << "Value == 0 ? 0x40000000U : 0U) | "
                << "static_cast<std::uint32_t>(((" << Expr(inst.GetArg(0))
                << " >> 31) & 1U) << 29)};\n";
            return;
        case IR::Opcode::A32SetCpsrNZCV:
        case IR::Opcode::A32SetCpsrNZCVRaw:
            out << "  state->cpsr = (state->cpsr & 0x0fffffffU) | (static_cast<std::uint32_t>("
                << Expr(inst.GetArg(0)) << ") & 0xf0000000U);\n";
            return;
        case IR::Opcode::A32SetCpsrNZ:
            out << "  state->cpsr = (state->cpsr & 0x3fffffffU) | (static_cast<std::uint32_t>("
                << Expr(inst.GetArg(0)) << ") & 0xc0000000U);\n";
            return;
        case IR::Opcode::A32SetCpsrNZC:
            out << "  state->cpsr = (state->cpsr & 0x1fffffffU) | (static_cast<std::uint32_t>("
                << Expr(inst.GetArg(0)) << ") & 0xc0000000U) | ("
                << Expr(inst.GetArg(1)) << " ? 0x20000000U : 0U);\n";
            return;
        case IR::Opcode::A32ReadMemory8:
        case IR::Opcode::A32ReadMemory16:
        case IR::Opcode::A32ReadMemory32:
        case IR::Opcode::A32ReadMemory64: {
            const unsigned bits = op == IR::Opcode::A32ReadMemory8 ? 8 :
                                  op == IR::Opcode::A32ReadMemory16 ? 16 :
                                  op == IR::Opcode::A32ReadMemory32 ? 32 : 64;
            out << "  std::uint64_t raw" << names.at(&inst) << " = 0;\n"
                << "  if (!Read(*callbacks, " << Expr(inst.GetArg(1)) << ", " << bits << ", raw"
                << names.at(&inst) << ")) return {BlockExit::MemoryFault, state->regs[15], "
                << Expr(inst.GetArg(1)) << ", remaining};\n"
                << "  const std::uint" << bits << "_t " << name
                << " = static_cast<std::uint" << bits << "_t>(raw" << names.at(&inst) << ");\n";
            return;
        }
        case IR::Opcode::A32WriteMemory8:
        case IR::Opcode::A32WriteMemory16:
        case IR::Opcode::A32WriteMemory32:
        case IR::Opcode::A32WriteMemory64: {
            const unsigned bits = op == IR::Opcode::A32WriteMemory8 ? 8 :
                                  op == IR::Opcode::A32WriteMemory16 ? 16 :
                                  op == IR::Opcode::A32WriteMemory32 ? 32 : 64;
            out << "  if (!Write(*callbacks, " << Expr(inst.GetArg(1)) << ", " << bits << ", "
                << Expr(inst.GetArg(2)) << ")) return {BlockExit::MemoryFault, state->regs[15], "
                << Expr(inst.GetArg(1)) << ", remaining};\n";
            return;
        }
        case IR::Opcode::A32ExclusiveReadMemory32:
            out << "  std::uint32_t " << name << " = 0;\n"
                << "  if (!ExclusiveRead32(*callbacks, " << Expr(inst.GetArg(1)) << ", " << name
                << ")) return {BlockExit::MemoryFault, state->regs[15], "
                << Expr(inst.GetArg(1)) << ", remaining};\n";
            return;
        case IR::Opcode::A32ExclusiveWriteMemory32:
            out << "  bool succeeded" << names.at(&inst) << " = false;\n"
                << "  if (!ExclusiveWrite32(*callbacks, " << Expr(inst.GetArg(1)) << ", "
                << Expr(inst.GetArg(2)) << ", succeeded" << names.at(&inst)
                << ")) return {BlockExit::MemoryFault, state->regs[15], "
                << Expr(inst.GetArg(1)) << ", remaining};\n"
                << "  const std::uint32_t " << name << " = succeeded" << names.at(&inst)
                << " ? 0U : 1U;\n";
            return;
        case IR::Opcode::A32ClearExclusive:
            out << "  if (!ClearExclusive(*callbacks)) return {BlockExit::CallbackFault, "
                   "state->regs[15], 0, remaining};\n";
            return;
        case IR::Opcode::A32CallSupervisor:
            EmitTicks();
            out << "  bool halt" << names.at(&inst) << " = false;\n"
                << "  if (!CallSvc(*callbacks, *state, static_cast<std::uint32_t>("
                << Expr(inst.GetArg(0)) << "), halt" << names.at(&inst)
                << ")) return {BlockExit::CallbackFault, state->regs[15], 0, remaining};\n"
                << "  if (halt" << names.at(&inst) << ") return {BlockExit::SupervisorCall, state->regs[15], "
                << Expr(inst.GetArg(0)) << ", remaining};\n";
            return;
        case IR::Opcode::A32CoprocGetOneWord: {
            const auto info = inst.GetArg(0).GetCoprocInfo();
            out << "  const std::uint8_t info" << names.at(&inst) << "[8] = {";
            for (std::size_t index = 0; index < info.size(); ++index) {
                if (index) out << ", ";
                out << static_cast<unsigned>(info[index]) << "U";
            }
            out << "};\n  std::uint32_t " << name << " = 0;\n"
                << "  if (!CoprocessorRead32(*callbacks, info" << names.at(&inst) << ", " << name
                << ")) return {BlockExit::CallbackFault, state->regs[15], 0, remaining};\n";
            return;
        }
        case IR::Opcode::A32CoprocSendOneWord: {
            const auto info = inst.GetArg(0).GetCoprocInfo();
            out << "  const std::uint8_t info" << names.at(&inst) << "[8] = {";
            for (std::size_t index = 0; index < info.size(); ++index) {
                if (index) out << ", ";
                out << static_cast<unsigned>(info[index]) << "U";
            }
            out << "};\n  if (!CoprocessorWrite32(*callbacks, info" << names.at(&inst) << ", "
                << Expr(inst.GetArg(1))
                << ")) return {BlockExit::CallbackFault, state->regs[15], 0, remaining};\n";
            return;
        }
        default:
            Fail(inst);
        }
    }

    void EmitTicks() {
        if (ticks_added) return;
        ticks_added = true;
        out << "  if (!AddTicks(*callbacks, " << block.CycleCount()
            << "U, remaining)) return {BlockExit::CallbackFault, state->regs[15], 0, remaining};\n";
    }

    void EmitLocation(const IR::LocationDescriptor& descriptor, const char* exit) {
        const A32::LocationDescriptor location{descriptor};
        next_pc = location.PC();
        EmitTicks();
        out << "  SetLocation(*state, " << Hex(location.PC()) << "U, "
            << Hex(location.CPSR().Value() & 0x0600fe20U) << "U, "
            << Hex(location.FPSCR().Value() & 0x07f70000U) << "U);\n"
            << "  return {BlockExit::" << exit << ", state->regs[15], 0, remaining};\n";
    }

    void EmitTerminal(const IR::Terminal& terminal) {
        if (const auto* link = boost::get<IR::Term::LinkBlock>(&terminal)) {
            EmitLocation(link->next, "Linked");
        } else if (const auto* link = boost::get<IR::Term::LinkBlockFast>(&terminal)) {
            EmitLocation(link->next, "Linked");
        } else if (boost::get<IR::Term::ReturnToDispatch>(&terminal) ||
                   boost::get<IR::Term::PopRSBHint>(&terminal) ||
                   boost::get<IR::Term::FastDispatchHint>(&terminal)) {
            EmitTicks();
            out << "  return {BlockExit::Dispatch, state->regs[15], 0, remaining};\n";
        } else if (const auto* branch = boost::get<IR::Term::If>(&terminal)) {
            EmitTicks();
            out << "  if (ConditionPassed(state->cpsr, " << static_cast<unsigned>(branch->if_)
                << "U)) {\n";
            EmitTerminal(branch->then_);
            out << "  } else {\n";
            EmitTerminal(branch->else_);
            out << "  }\n";
        } else if (const auto* halt = boost::get<IR::Term::CheckHalt>(&terminal)) {
            EmitTerminal(halt->else_);
        } else {
            throw Unsupported("unsupported IR terminal at guest PC " +
                              Hex(block.Location().Value() & 0xffffffffU));
        }
    }
};

void CollectTerminalTargets(const IR::Terminal& terminal,
                            std::vector<A32::LocationDescriptor>& targets) {
    if (const auto* link = boost::get<IR::Term::LinkBlock>(&terminal)) {
        targets.emplace_back(link->next);
    } else if (const auto* link = boost::get<IR::Term::LinkBlockFast>(&terminal)) {
        targets.emplace_back(link->next);
    } else if (const auto* branch = boost::get<IR::Term::If>(&terminal)) {
        CollectTerminalTargets(branch->then_, targets);
        CollectTerminalTargets(branch->else_, targets);
    } else if (const auto* halt = boost::get<IR::Term::CheckHalt>(&terminal)) {
        CollectTerminalTargets(halt->else_, targets);
    }
}

std::vector<A32::LocationDescriptor> DirectTargets(const IR::Block& block) {
    std::vector<A32::LocationDescriptor> targets;
    CollectTerminalTargets(block.GetTerminal(), targets);
    if (block.HasConditionFailedLocation()) targets.emplace_back(block.ConditionFailedLocation());
    for (const IR::Inst& inst : block) {
        if (inst.GetOpcode() == IR::Opcode::PushRSB && inst.GetArg(0).IsImmediate()) {
            targets.emplace_back(IR::LocationDescriptor{inst.GetArg(0).GetU64()});
        }
    }
    return targets;
}

bool HasSupervisorCall(const IR::Block& block) {
    for (const IR::Inst& inst : block) {
        if (inst.GetOpcode() == IR::Opcode::A32CallSupervisor) return true;
    }
    return false;
}

bool TerminalHasUnresolvedIndirect(const IR::Terminal& terminal) {
    if (boost::get<IR::Term::ReturnToDispatch>(&terminal) ||
        boost::get<IR::Term::PopRSBHint>(&terminal) ||
        boost::get<IR::Term::FastDispatchHint>(&terminal)) {
        return true;
    }
    if (const auto* branch = boost::get<IR::Term::If>(&terminal)) {
        return TerminalHasUnresolvedIndirect(branch->then_) ||
               TerminalHasUnresolvedIndirect(branch->else_);
    }
    if (const auto* halt = boost::get<IR::Term::CheckHalt>(&terminal)) {
        return TerminalHasUnresolvedIndirect(halt->else_);
    }
    return false;
}

bool HasUnresolvedIndirect(const IR::Block& block) {
    if (TerminalHasUnresolvedIndirect(block.GetTerminal())) return true;
    for (const IR::Inst& inst : block) {
        if (inst.GetOpcode() == IR::Opcode::A32BXWritePC) return true;
    }
    return false;
}

std::string EmitIdentity(const Source& source, const std::string& input_sha256) {
    std::ostringstream out;
    out << "\nnamespace {\nconstexpr mh4u::aot::CodeWord mh4u_aot_code_words[] = {\n";
    for (const auto& [address, value] : source.code_words) {
        out << "  {" << Hex(address) << "U, " << Hex(value) << "U},\n";
    }
    out << "};\nconstexpr mh4u::aot::ArtifactIdentity mh4u_aot_artifact_identity{\n"
        << "  mh4u_aot_code_words, " << source.code_words.size() << "U, \""
        << input_sha256 << "\"};\n}\n"
        << "const mh4u::aot::ArtifactIdentity* mh4u_aot_identity() {\n"
        << "  return &mh4u_aot_artifact_identity;\n}\n";
    return out.str();
}

std::string EmitDispatcher(const std::vector<IR::Block>& blocks,
                           const std::size_t max_dispatch_steps) {
    std::ostringstream out;
    out << "\nmh4u::aot::BlockResult mh4u_aot_execute(\n"
           "    mh4u::aot::GuestCpuState* state, const mh4u::aot::Callbacks* callbacks) {\n"
           "  using namespace mh4u::aot;\n"
           "  if (!state) return {BlockExit::CallbackFault, 0, 0, 0};\n"
           "  for (std::size_t step = 0; step < " << max_dispatch_steps << "U; ++step) {\n"
           "    BlockResult result{};\n"
           "    bool matched = false;\n";
    for (std::size_t index = 0; index < blocks.size(); ++index) {
        const A32::LocationDescriptor location{blocks[index].Location()};
        out << "    if (!matched && state->regs[15] == " << Hex(location.PC())
            << "U && (state->cpsr & 0x0600fe20U) == "
            << Hex(location.CPSR().Value() & 0x0600fe20U)
            << "U && (state->fpscr & 0x07f70000U) == "
            << Hex(location.FPSCR().Value() & 0x07f70000U) << "U) { result = mh4u_aot_block_"
            << index << "(state, callbacks); matched = true; }\n";
    }
    out << "    if (!matched) return {BlockExit::MissingBlock, state->regs[15], state->regs[15], 0};\n"
           "    if (result.exit != BlockExit::Linked && result.exit != BlockExit::Dispatch) return result;\n"
           "    if (result.remaining_ticks == 0) return {BlockExit::Dispatch, state->regs[15], 0, 0};\n"
           "  }\n"
           "  return {BlockExit::DispatcherLimit, state->regs[15], 0, 0};\n"
           "}\n";
    return out.str();
}

std::string JsonEscape(const std::string& value) {
    std::string result;
    for (const char c : value) {
        if (c == '\\' || c == '"') result += '\\';
        result += c;
    }
    return result;
}

void WriteFile(const std::filesystem::path& path, const std::string& contents) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream output(path);
    if (!output || !(output << contents)) throw std::runtime_error("cannot write " + path.string());
}

bool IsWithin(const std::filesystem::path& path, const std::filesystem::path& root) {
    const auto normalized_path = std::filesystem::weakly_canonical(path);
    const auto normalized_root = std::filesystem::weakly_canonical(root);
    auto path_it = normalized_path.begin();
    for (auto root_it = normalized_root.begin(); root_it != normalized_root.end(); ++root_it, ++path_it) {
        if (path_it == normalized_path.end() || *path_it != *root_it) return false;
    }
    return true;
}

std::string Sha256(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open input: " + path.string());
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    std::array<char, 64 * 1024> buffer{};
    while (input) {
        input.read(buffer.data(), buffer.size());
        if (input.gcount() > 0) {
            CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(input.gcount()));
        }
    }
    if (input.bad()) throw std::runtime_error("cannot read input: " + path.string());
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256_Final(digest.data(), &context);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (const unsigned char byte : digest) out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = ParseOptions(argc, argv);
        if (!IsWithin(options.output, options.artifact_root) ||
            !IsWithin(options.manifest, options.artifact_root)) {
            throw std::runtime_error("generated artifacts must remain under " + options.artifact_root.string());
        }
        const auto input_path = options.fixture.empty() ? options.binary : options.fixture;
        const std::string actual_sha256 = Sha256(input_path);
        if (actual_sha256 != options.input_sha256) {
            throw std::runtime_error("input SHA-256 mismatch: expected " + options.input_sha256 +
                                     ", got " + actual_sha256);
        }
        Source source;
        source.max_code_reads = options.max_instructions;
        std::uint32_t pc = options.pc;
        std::uint32_t cpsr = options.cpsr;
        std::uint32_t fpscr = options.fpscr;
        std::string input_kind;
        if (!options.fixture.empty()) {
            Fixture fixture;
            std::string error;
            if (!mh4u::aot::fixture::Load(options.fixture, fixture, error)) throw std::runtime_error(error);
            source.bytes = fixture.memory;
            source.absolute_addresses = true;
            pc = fixture.state.regs[15];
            cpsr = fixture.state.cpsr;
            fpscr = fixture.state.fpscr;
            input_kind = "synthetic-fixture";
        } else {
            std::ifstream input(options.binary, std::ios::binary);
            if (!input) throw std::runtime_error("cannot open binary: " + options.binary.string());
            source.bytes.assign(std::istreambuf_iterator<char>(input), {});
            if (input.bad()) throw std::runtime_error("cannot read binary: " + options.binary.string());
            source.mapped_base = options.base;
            input_kind = "title-code";
        }
        A32::TranslationOptions translation_options{A32::ArchVersion::v6K, true, false};
        if ((cpsr & 0x0600fc00U) != 0) {
            throw std::runtime_error("Thumb IT state is not supported by this AOT slice");
        }
        if (((cpsr & 0x20U) == 0 && (pc & 3U) != 0) ||
            ((cpsr & 0x20U) != 0 && (pc & 1U) != 0)) {
            throw std::runtime_error("entry PC is not aligned for its ARM/Thumb mode");
        }
        const A32::LocationDescriptor descriptor{pc, A32::PSR{cpsr}, A32::FPSCR{fpscr}};
        std::deque<A32::LocationDescriptor> pending{descriptor};
        std::unordered_set<std::uint64_t> discovered{descriptor.UniqueHash()};
        std::vector<A32::LocationDescriptor> entry_descriptors{descriptor};
        for (const EntryDescriptor& entry : options.extra_entries) {
            if ((entry.cpsr & 0x0600fc00U) != 0) {
                throw std::runtime_error("Thumb IT state is not supported by this AOT slice");
            }
            if (((entry.cpsr & 0x20U) == 0 && (entry.pc & 3U) != 0) ||
                ((entry.cpsr & 0x20U) != 0 && (entry.pc & 1U) != 0)) {
                throw std::runtime_error("entry PC is not aligned for its ARM/Thumb mode");
            }
            A32::LocationDescriptor extra{entry.pc, A32::PSR{entry.cpsr}, A32::FPSCR{entry.fpscr}};
            if (discovered.insert(extra.UniqueHash()).second) {
                pending.push_back(extra);
                entry_descriptors.push_back(extra);
            }
        }
        std::vector<IR::Block> blocks;
        std::vector<std::string> emitted_sources;
        std::vector<std::string> opcodes;
        std::vector<A32::LocationDescriptor> unresolved_indirect;
        std::size_t ir_instruction_count = 0;
        bool reached_svc = false;
        std::uint32_t first_next_pc = 0;
        while (!pending.empty() && blocks.size() < options.max_blocks &&
               (!reached_svc || options.continue_after_svc)) {
            A32::LocationDescriptor location = pending.front();
            pending.pop_front();
            IR::Block block = A32::Translate(location, &source, translation_options);
            ir_instruction_count += block.size();
            const std::string name = options.max_blocks == 1
                                         ? "mh4u_aot_execute"
                                         : "mh4u_aot_block_" + std::to_string(blocks.size());
            Emission emission = Emitter(block, name, options.max_blocks != 1).Emit();
            if (blocks.empty()) first_next_pc = emission.next_pc;
            emitted_sources.push_back(std::move(emission.source));
            opcodes.insert(opcodes.end(), emission.opcodes.begin(), emission.opcodes.end());
            reached_svc |= HasSupervisorCall(block);
            if (HasUnresolvedIndirect(block)) unresolved_indirect.push_back(location);
            for (const A32::LocationDescriptor& target : DirectTargets(block)) {
                if (discovered.insert(target.UniqueHash()).second) pending.push_back(target);
            }
            blocks.push_back(std::move(block));
        }
        std::ostringstream generated;
        for (const std::string& emitted : emitted_sources) generated << emitted;
        generated << EmitIdentity(source, actual_sha256);
        if (options.max_blocks != 1) generated << EmitDispatcher(blocks, options.max_dispatch_steps);
        WriteFile(options.output, generated.str());
        std::uint64_t total_cycles = 0;
        for (const IR::Block& block : blocks) total_cycles += block.CycleCount();
        const bool static_direct_frontier_exhausted = pending.empty();
        const bool coverage_complete = static_direct_frontier_exhausted && unresolved_indirect.empty();
        const char* stop_reason = !options.continue_after_svc && reached_svc
                                      ? "svc-discovered"
                                  : static_direct_frontier_exhausted
                                      ? "static-direct-frontier-exhausted"
                                      : "max-blocks";
        std::ostringstream manifest;
        manifest << "{\n  \"format\": \"mh4u-aot-v1\",\n"
                 << "  \"input_kind\": \"" << input_kind << "\",\n"
                 << "  \"input_path\": \""
                 << JsonEscape((options.fixture.empty() ? options.binary : options.fixture).string()) << "\",\n"
                 << "  \"input_sha256\": \"" << options.input_sha256 << "\",\n"
                 << "  \"architecture\": \"ARMv6K\",\n"
                 << "  \"tick_model\": \"Azahar Core::TicksForInstruction\",\n"
                 << "  \"pc\": \"" << Hex(pc) << "\",\n"
                 << "  \"thumb\": " << ((cpsr & 0x20U) ? "true" : "false") << ",\n"
                 << "  \"entry_descriptor_count\": " << entry_descriptors.size() << ",\n"
                 << "  \"entry_descriptors\": [";
        for (std::size_t index = 0; index < entry_descriptors.size(); ++index) {
            if (index) manifest << ", ";
            const auto& entry = entry_descriptors[index];
            manifest << "{\"pc\":\"" << Hex(entry.PC()) << "\",\"cpsr_mode\":\""
                     << Hex(entry.CPSR().Value() & 0x0600fe20U)
                     << "\",\"fpscr_mode\":\""
                     << Hex(entry.FPSCR().Value() & 0x07f70000U) << "\"}";
        }
        manifest << "],\n"
                 << "  \"cycle_count\": " << total_cycles << ",\n"
                 << "  \"next_pc\": \"" << Hex(first_next_pc) << "\",\n"
                 << "  \"block_count\": " << blocks.size() << ",\n"
                 << "  \"ir_instruction_count\": " << ir_instruction_count << ",\n"
                 << "  \"guest_instruction_fetches\": " << source.code_reads << ",\n"
                 << "  \"max_blocks\": " << options.max_blocks << ",\n"
                 << "  \"max_guest_instruction_fetches\": " << options.max_instructions << ",\n"
                 << "  \"max_dispatch_steps\": " << options.max_dispatch_steps << ",\n"
                 << "  \"static_direct_graph_reached_svc\": "
                 << (reached_svc ? "true" : "false") << ",\n"
                 << "  \"continue_after_svc\": "
                 << (options.continue_after_svc ? "true" : "false") << ",\n"
                 << "  \"static_direct_frontier_exhausted\": "
                 << (static_direct_frontier_exhausted ? "true" : "false") << ",\n"
                 << "  \"coverage_complete\": " << (coverage_complete ? "true" : "false") << ",\n"
                 << "  \"stop_reason\": \"" << stop_reason << "\",\n"
                 << "  \"frontier_count\": " << pending.size() << ",\n"
                 << "  \"frontier\": [";
        for (std::size_t index = 0; index < pending.size(); ++index) {
            if (index) manifest << ", ";
            const A32::LocationDescriptor location{pending[index]};
            manifest << "{\"pc\":\"" << Hex(location.PC()) << "\",\"cpsr_mode\":\""
                     << Hex(location.CPSR().Value() & 0x0600fe20U)
                     << "\",\"fpscr_mode\":\""
                     << Hex(location.FPSCR().Value() & 0x07f70000U) << "\"}";
        }
        manifest << "],\n  \"unresolved_indirect_count\": " << unresolved_indirect.size()
                 << ",\n  \"unresolved_indirect\": [";
        for (std::size_t index = 0; index < unresolved_indirect.size(); ++index) {
            if (index) manifest << ", ";
            const A32::LocationDescriptor& location = unresolved_indirect[index];
            manifest << "{\"pc\":\"" << Hex(location.PC()) << "\",\"cpsr_mode\":\""
                     << Hex(location.CPSR().Value() & 0x0600fe20U)
                     << "\",\"fpscr_mode\":\""
                     << Hex(location.FPSCR().Value() & 0x07f70000U) << "\"}";
        }
        manifest << "],\n  \"emitted_blocks_supported\": true,\n  \"ir_opcodes\": [";
        for (std::size_t index = 0; index < opcodes.size(); ++index) {
            if (index) manifest << ", ";
            manifest << '"' << opcodes[index] << '"';
        }
        manifest << "]\n}\n";
        WriteFile(options.manifest, manifest.str());
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "aot-generator: " << error.what() << '\n';
        return 1;
    }
}
