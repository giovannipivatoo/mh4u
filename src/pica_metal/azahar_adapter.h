#pragma once

#include "pica_metal.h"

namespace Pica {
struct OutputVertex;
struct RegsInternal;
} // namespace Pica

namespace mh4u::pica_metal {

// Azahar ownership stops here. RasterizerInterface::AddTriangle output is copied
// into the core-agnostic representation before Metal sees it.
struct AzaharDraw {
    std::vector<OutputVertex> vertices{};
    DrawState state{};
    TextureRgba8 texture0{};
    bool texture0_enabled{};
    uint32_t target_width{};
    uint32_t target_height{};
    uint32_t depth_bits{};
    bool target_has_stencil{};

    Draw view() const { return {vertices, state, texture0_enabled ? &texture0 : nullptr}; }
};

// texture0 must already be decoded to linear RGBA8 by the integration layer.
// Every live PICA register that this first slice cannot preserve is rejected.
ValidationResult decode_azahar_draw(const Pica::RegsInternal& regs,
                                    std::span<const Pica::OutputVertex> vertices,
                                    const TextureRgba8* texture0, AzaharDraw& output);

} // namespace mh4u::pica_metal
