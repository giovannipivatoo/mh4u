#include "pica_metal.h"

#include <cmath>
#include <limits>

namespace mh4u::pica_metal {
namespace {

bool finite(Float2 value) {
    return std::isfinite(value.x) && std::isfinite(value.y);
}

bool finite(Float4 value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z) &&
           std::isfinite(value.w);
}

template <class Enum>
bool in_range(Enum value, Enum last) {
    return static_cast<uint32_t>(value) <= static_cast<uint32_t>(last);
}

bool uses_source(const TevStage& stage, TevSource wanted) {
    for (const auto source : stage.color_source) {
        if (source == wanted) return true;
    }
    for (const auto source : stage.alpha_source) {
        if (source == wanted) return true;
    }
    return false;
}

} // namespace

ValidationResult validate(const Frame& frame) {
    if (!frame.width || !frame.height || frame.draws.empty())
        return {Error::InvalidDraw,
                "PICA frame must contain a non-empty framebuffer and at least one draw"};
    if (frame.width > 16384 || frame.height > 16384 ||
        static_cast<uint64_t>(frame.width) * frame.height * 4 >
            std::numeric_limits<size_t>::max())
        return {Error::UnsupportedState, "PICA framebuffer exceeds the Metal slice limits"};
    if (!finite(frame.clear_color) || !std::isfinite(frame.clear_depth) ||
        frame.clear_depth < 0.0f || frame.clear_depth > 1.0f)
        return {Error::InvalidDraw, "PICA framebuffer clear values are invalid"};
    if (frame.pica_depth_bits != 16 && frame.pica_depth_bits != 24)
        return {Error::UnsupportedState, "PICA depth target must be D16 or D24"};
    for (const Draw& draw : frame.draws) {
        const auto& state = draw.state;
        if (draw.vertices.empty() || draw.vertices.size() % 3 != 0)
            return {Error::InvalidDraw, "PICA draw must contain a non-empty triangle list"};
        if (!state.viewport_width || !state.viewport_height)
            return {Error::InvalidDraw, "PICA viewport dimensions must be non-zero"};
        if (state.viewport_x < 0 || state.viewport_y < 0 ||
            static_cast<uint64_t>(state.viewport_x) + state.viewport_width > frame.width ||
            static_cast<uint64_t>(state.viewport_y) + state.viewport_height > frame.height)
            return {Error::InvalidDraw, "PICA viewport is outside the framebuffer"};
        if (state.scissor_enable &&
            (!state.scissor_width || !state.scissor_height ||
             static_cast<uint64_t>(state.scissor_x) + state.scissor_width > frame.width ||
             static_cast<uint64_t>(state.scissor_y) + state.scissor_height > frame.height))
            return {Error::InvalidDraw, "PICA include scissor is outside the framebuffer"};
        if (!std::isfinite(state.pica_depth_scale) || !std::isfinite(state.pica_depth_offset))
            return {Error::InvalidDraw, "PICA depth transform is invalid"};
        if (!in_range(state.depth_mode, DepthMode::WBuffering))
            return {Error::InvalidDraw, "PICA depth mode is invalid"};
        if (state.depth_mode == DepthMode::WBuffering)
            return {Error::UnsupportedState,
                    "PICA W-buffering is not implemented by the first Metal slice"};
        if (!in_range(state.cull_mode, CullMode::KeepCounterClockwise) ||
            !in_range(state.color_blend_equation, BlendEquation::Max) ||
            !in_range(state.alpha_blend_equation, BlendEquation::Max) ||
            !in_range(state.source_color_blend_factor, BlendFactor::SourceAlphaSaturate) ||
            !in_range(state.destination_color_blend_factor, BlendFactor::SourceAlphaSaturate) ||
            !in_range(state.source_alpha_blend_factor, BlendFactor::SourceAlphaSaturate) ||
            !in_range(state.destination_alpha_blend_factor, BlendFactor::SourceAlphaSaturate) ||
            !in_range(state.depth_compare, CompareFunc::GreaterEqual) ||
            !in_range(state.alpha_compare, CompareFunc::GreaterEqual) ||
            !in_range(state.stencil_compare, CompareFunc::GreaterEqual) ||
            !in_range(state.stencil_fail, StencilAction::DecrementWrap) ||
            !in_range(state.stencil_depth_fail, StencilAction::DecrementWrap) ||
            !in_range(state.stencil_depth_pass, StencilAction::DecrementWrap))
            return {Error::InvalidDraw, "PICA rasterizer enum is outside the supported range"};
        if (!finite(state.blend_constant))
            return {Error::InvalidDraw, "PICA blend constant is invalid"};
        if (state.stencil_test_enable && !frame.has_stencil)
            return {Error::InvalidDraw, "PICA stencil test requires a stencil target"};
        for (const auto& vertex : draw.vertices) {
            if (!finite(vertex.clip_position) || !finite(vertex.primary_color) ||
                !finite(vertex.texcoord0) || !finite(vertex.texcoord2) ||
                vertex.clip_position.w == 0.0f)
                return {Error::InvalidDraw, "PICA output vertex contains an invalid float24 value"};
        }

    bool texture0_used = false;
    bool procedural_texture_used = false;
    for (size_t stage_index = 0; stage_index < state.tev.size(); ++stage_index) {
        const auto& stage = state.tev[stage_index];
        if ((stage.color_multiplier != 1 && stage.color_multiplier != 2 &&
             stage.color_multiplier != 4) ||
            (stage.alpha_multiplier != 1 && stage.alpha_multiplier != 2 &&
             stage.alpha_multiplier != 4))
            return {Error::InvalidDraw, "PICA TEV multiplier must be 1, 2, or 4"};
        if (!in_range(stage.color_operation, TevOperation::AddThenMultiply) ||
            !in_range(stage.alpha_operation, TevOperation::AddThenMultiply))
            return {Error::InvalidDraw, "PICA TEV operation is outside the supported range"};
        if ((stage.alpha_operation == TevOperation::Dot3Rgb ||
             stage.alpha_operation == TevOperation::Dot3Rgba) &&
            stage.color_operation != TevOperation::Dot3Rgba)
            return {Error::InvalidDraw,
                    "PICA dot3 is not valid for the alpha combiner: stage=" +
                        std::to_string(stage_index) + " color_op=" +
                        std::to_string(static_cast<uint32_t>(stage.color_operation)) +
                        " alpha_op=" +
                        std::to_string(static_cast<uint32_t>(stage.alpha_operation))};
        if (!finite(stage.constant))
            return {Error::InvalidDraw, "PICA TEV constant is invalid"};
        for (const auto source : stage.color_source)
            if (!in_range(source, TevSource::ProceduralTexture))
                return {Error::InvalidDraw, "PICA TEV color source is invalid"};
        for (const auto source : stage.alpha_source)
            if (!in_range(source, TevSource::ProceduralTexture))
                return {Error::InvalidDraw, "PICA TEV alpha source is invalid"};
        for (const auto modifier : stage.color_modifier)
            if (!in_range(modifier, ColorModifier::OneMinusSourceBlue))
                return {Error::InvalidDraw, "PICA TEV color modifier is invalid"};
        for (const auto modifier : stage.alpha_modifier)
            if (!in_range(modifier, AlphaModifier::OneMinusSourceBlue))
                return {Error::InvalidDraw, "PICA TEV alpha modifier is invalid"};
        texture0_used |= uses_source(stage, TevSource::Texture0);
        procedural_texture_used |= uses_source(stage, TevSource::ProceduralTexture);
    }

    if (texture0_used && !draw.texture0)
        return {Error::InvalidDraw, "PICA TEV reads texture0 but none was supplied"};
    if (procedural_texture_used && !draw.procedural_texture)
        return {Error::InvalidDraw, "PICA TEV reads procedural texture3 but no LUT was supplied"};
    if (draw.texture0) {
        const auto& texture = *draw.texture0;
        if (!texture.width || !texture.height || texture.row_bytes < texture.width * 4ULL ||
            texture.pixels.size() < texture.row_bytes * static_cast<uint64_t>(texture.height))
            return {Error::InvalidDraw, "PICA RGBA8 texture storage is invalid"};
        if (!in_range(texture.filter, TextureFilter::Linear) ||
            !in_range(texture.wrap_s, WrapMode::MirroredRepeat) ||
            !in_range(texture.wrap_t, WrapMode::MirroredRepeat))
            return {Error::InvalidDraw, "PICA texture sampler state is invalid"};
    }
    if (draw.procedural_texture) {
        for (const Float2 entry : draw.procedural_texture->color_map)
            if (!finite(entry))
                return {Error::InvalidDraw, "PICA procedural color map contains an invalid value"};
        for (const Float4 entry : draw.procedural_texture->color)
            if (!finite(entry))
                return {Error::InvalidDraw, "PICA procedural color LUT contains an invalid value"};
        for (const Float4 entry : draw.procedural_texture->color_difference)
            if (!finite(entry))
                return {Error::InvalidDraw,
                        "PICA procedural color difference LUT contains an invalid value"};
    }
    }
    return {};
}

} // namespace mh4u::pica_metal
