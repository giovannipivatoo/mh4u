#pragma once

#include "pica_metal.h"

namespace Pica {
struct OutputVertex;
struct RegsInternal;
} // namespace Pica

namespace mh4u::pica_metal {

struct AzaharTextureLayout {
    uint32_t encoded_bytes{};
    uint32_t decoded_bytes{};
};

struct AzaharTexture0 {
    uint32_t width{};
    uint32_t height{};
    std::vector<uint8_t> rgba8{};

    TextureRgba8 view() const { return {width, height, width * 4, rgba8}; }
};

struct AzaharProceduralTexture {
    ProceduralTexture snapshot{};
};

// Derives bounded tiled source storage from the live PICA texture0 registers,
// then decodes that exact span through Azahar's pinned texture helper.
ValidationResult azahar_texture0_layout(const Pica::RegsInternal& regs,
                                        AzaharTextureLayout& output);
ValidationResult decode_azahar_texture0(const Pica::RegsInternal& regs,
                                        std::span<const uint8_t> encoded,
                                        AzaharTexture0& output);
ValidationResult decode_azahar_procedural_texture(
    std::span<const uint32_t, 128> color_map_raw,
    std::span<const uint32_t, 256> color_raw,
    std::span<const uint32_t, 256> color_difference_raw,
    AzaharProceduralTexture& output);

// Azahar ownership stops here. RasterizerInterface::AddTriangle output is copied
// into the core-agnostic representation before Metal sees it.
struct AzaharDraw {
    std::vector<OutputVertex> vertices{};
    DrawState state{};
    TextureRgba8 texture0{};
    bool texture0_enabled{};
    ProceduralTexture procedural_texture{};
    bool procedural_texture_enabled{};
    uint32_t target_width{};
    uint32_t target_height{};
    uint32_t depth_bits{};
    bool target_has_stencil{};

    Draw view() const {
        return {vertices, state, texture0_enabled ? &texture0 : nullptr,
                procedural_texture_enabled ? &procedural_texture : nullptr};
    }
};

// texture0 must already be decoded to linear RGBA8 by the integration layer.
// Every live PICA register that this first slice cannot preserve is rejected.
ValidationResult decode_azahar_draw(const Pica::RegsInternal& regs,
                                    std::span<const Pica::OutputVertex> vertices,
                                    const TextureRgba8* texture0,
                                    const ProceduralTexture* procedural_texture,
                                    AzaharDraw& output);

} // namespace mh4u::pica_metal
