#include "azahar_adapter.h"

#include "video_core/pica/output_vertex.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/texture/texture_decode.h"

#include <cstring>

namespace mh4u::pica_metal {
namespace {

ValidationResult unsupported(const char* message) {
    return {Error::UnsupportedState, message};
}

Float4 rgba8(uint32_t raw) {
    constexpr float scale = 1.0f / 255.0f;
    return {static_cast<float>(raw & 0xff) * scale,
            static_cast<float>((raw >> 8) & 0xff) * scale,
            static_cast<float>((raw >> 16) & 0xff) * scale,
            static_cast<float>((raw >> 24) & 0xff) * scale};
}

bool source(Pica::TexturingRegs::TevStageConfig::Source value, TevSource& result) {
    using Source = Pica::TexturingRegs::TevStageConfig::Source;
    switch (value) {
    case Source::PrimaryColor: result = TevSource::PrimaryColor; return true;
    case Source::Texture0: result = TevSource::Texture0; return true;
    case Source::PreviousBuffer: result = TevSource::PreviousBuffer; return true;
    case Source::Constant: result = TevSource::Constant; return true;
    case Source::Previous: result = TevSource::Previous; return true;
    default: return false;
    }
    return false;
}

bool color_modifier(Pica::TexturingRegs::TevStageConfig::ColorModifier value,
                    ColorModifier& result) {
    using Source = Pica::TexturingRegs::TevStageConfig::ColorModifier;
    switch (value) {
    case Source::SourceColor: result = ColorModifier::SourceColor; return true;
    case Source::OneMinusSourceColor: result = ColorModifier::OneMinusSourceColor; return true;
    case Source::SourceAlpha: result = ColorModifier::SourceAlpha; return true;
    case Source::OneMinusSourceAlpha: result = ColorModifier::OneMinusSourceAlpha; return true;
    case Source::SourceRed: result = ColorModifier::SourceRed; return true;
    case Source::OneMinusSourceRed: result = ColorModifier::OneMinusSourceRed; return true;
    case Source::SourceGreen: result = ColorModifier::SourceGreen; return true;
    case Source::OneMinusSourceGreen: result = ColorModifier::OneMinusSourceGreen; return true;
    case Source::SourceBlue: result = ColorModifier::SourceBlue; return true;
    case Source::OneMinusSourceBlue: result = ColorModifier::OneMinusSourceBlue; return true;
    }
    return false;
}

bool alpha_modifier(Pica::TexturingRegs::TevStageConfig::AlphaModifier value,
                    AlphaModifier& result) {
    using Source = Pica::TexturingRegs::TevStageConfig::AlphaModifier;
    switch (value) {
    case Source::SourceAlpha: result = AlphaModifier::SourceAlpha; return true;
    case Source::OneMinusSourceAlpha: result = AlphaModifier::OneMinusSourceAlpha; return true;
    case Source::SourceRed: result = AlphaModifier::SourceRed; return true;
    case Source::OneMinusSourceRed: result = AlphaModifier::OneMinusSourceRed; return true;
    case Source::SourceGreen: result = AlphaModifier::SourceGreen; return true;
    case Source::OneMinusSourceGreen: result = AlphaModifier::OneMinusSourceGreen; return true;
    case Source::SourceBlue: result = AlphaModifier::SourceBlue; return true;
    case Source::OneMinusSourceBlue: result = AlphaModifier::OneMinusSourceBlue; return true;
    }
    return false;
}

bool operation(Pica::TexturingRegs::TevStageConfig::Operation value, TevOperation& result) {
    using Source = Pica::TexturingRegs::TevStageConfig::Operation;
    switch (value) {
    case Source::Replace: result = TevOperation::Replace; return true;
    case Source::Modulate: result = TevOperation::Modulate; return true;
    case Source::Add: result = TevOperation::Add; return true;
    case Source::AddSigned: result = TevOperation::AddSigned; return true;
    case Source::Lerp: result = TevOperation::Lerp; return true;
    case Source::Subtract: result = TevOperation::Subtract; return true;
    case Source::Dot3_RGB: result = TevOperation::Dot3Rgb; return true;
    case Source::Dot3_RGBA: result = TevOperation::Dot3Rgba; return true;
    case Source::MultiplyThenAdd: result = TevOperation::MultiplyThenAdd; return true;
    case Source::AddThenMultiply: result = TevOperation::AddThenMultiply; return true;
    }
    return false;
}

bool wrap(Pica::TexturingRegs::TextureConfig::WrapMode value, WrapMode& result) {
    using Source = Pica::TexturingRegs::TextureConfig::WrapMode;
    switch (value) {
    case Source::ClampToEdge: result = WrapMode::ClampToEdge; return true;
    case Source::Repeat:
    case Source::Repeat2:
    case Source::Repeat3: result = WrapMode::Repeat; return true;
    case Source::MirroredRepeat: result = WrapMode::MirroredRepeat; return true;
    default: return false;
    }
    return false;
}

} // namespace

ValidationResult azahar_texture0_layout(const Pica::RegsInternal& regs,
                                        AzaharTextureLayout& output) {
    constexpr uint64_t MaxTextureBytes = 4 * 1024 * 1024;
    const auto& config = regs.texturing.texture0;
    const auto format = regs.texturing.texture0_format.Value();
    const uint32_t format_value = static_cast<uint32_t>(format);
    const uint64_t decoded_bytes = static_cast<uint64_t>(config.width) * config.height * 4;
    if (format_value > static_cast<uint32_t>(Pica::TexturingRegs::TextureFormat::ETC1A4) ||
        config.width == 0 || config.height == 0 || config.width % 8 || config.height % 8 ||
        config.type != Pica::TexturingRegs::TextureConfig::Texture2D || config.lod.max_level != 0)
        return {Error::UnsupportedState, "PICA texture0 layout is unsupported"};
    const uint64_t encoded_bytes = Pica::Texture::CalculateTileSize(format) *
                                   static_cast<uint64_t>(config.width / 8) *
                                   static_cast<uint64_t>(config.height / 8);
    if (!encoded_bytes || encoded_bytes > MaxTextureBytes || decoded_bytes > MaxTextureBytes)
        return {Error::UnsupportedState, "PICA texture0 exceeds the 4 MiB decode bounds"};
    output = {static_cast<uint32_t>(encoded_bytes), static_cast<uint32_t>(decoded_bytes)};
    return {};
}

ValidationResult decode_azahar_texture0(const Pica::RegsInternal& regs,
                                        std::span<const uint8_t> encoded,
                                        AzaharTexture0& output) {
    AzaharTextureLayout layout{};
    const ValidationResult valid = azahar_texture0_layout(regs, layout);
    if (!valid) return valid;
    if (encoded.size() != layout.encoded_bytes)
        return {Error::InvalidDraw, "PICA texture0 encoded span has the wrong size"};
    const auto& config = regs.texturing.texture0;
    const auto info = Pica::Texture::TextureInfo::FromPicaRegister(
        config, regs.texturing.texture0_format.Value());
    output = {config.width, config.height, std::vector<uint8_t>(layout.decoded_bytes)};
    for (uint32_t y = 0; y < config.height; ++y) {
        for (uint32_t x = 0; x < config.width; ++x) {
            const auto value = Pica::Texture::LookupTexture(encoded.data(), x,
                                                            config.height - 1 - y, info);
            const size_t offset = (static_cast<size_t>(y) * config.width + x) * 4;
            std::memcpy(output.rgba8.data() + offset, value.AsArray(), 4);
        }
    }
    return {};
}

ValidationResult decode_azahar_draw(const Pica::RegsInternal& regs,
                                    std::span<const Pica::OutputVertex> vertices,
                                    const TextureRgba8* texture0, AzaharDraw& output) {
    using Framebuffer = Pica::FramebufferRegs;
    using Texturing = Pica::TexturingRegs;
    const auto& fb = regs.framebuffer;
    const auto& merger = fb.output_merger;
    if (vertices.empty() || vertices.size() % 3 != 0)
        return {Error::InvalidDraw, "Azahar AddTriangle batch is not a triangle list"};
    if (fb.framebuffer.color_format != Framebuffer::ColorFormat::RGBA8)
        return unsupported("PICA Metal first slice requires an RGBA8 color target");
    if (fb.framebuffer.depth_format != Framebuffer::DepthFormat::D16 &&
        fb.framebuffer.depth_format != Framebuffer::DepthFormat::D24 &&
        fb.framebuffer.depth_format != Framebuffer::DepthFormat::D24S8)
        return unsupported("PICA depth target format is unsupported");
    if (merger.fragment_operation_mode != Framebuffer::FragmentOperationMode::Default)
        return unsupported("PICA gas and shadow fragment modes are not implemented");
    if (!merger.alphablend_enable && merger.logic_op != Framebuffer::LogicOp::Copy) {
        return unsupported("PICA non-copy logic operations are not implemented");
    }
    if (!fb.framebuffer.allow_color_write || !merger.red_enable || !merger.green_enable ||
        !merger.blue_enable || !merger.alpha_enable)
        return unsupported("PICA partial color write masks are not implemented");
    if (merger.depth_write_enable && !fb.framebuffer.allow_depth_stencil_write)
        return unsupported("PICA depth writes are disabled by the framebuffer register");
    if (regs.rasterizer.scissor_test.mode == Pica::RasterizerRegs::ScissorMode::Exclude)
        return unsupported("PICA exclude scissor mode is not implemented");
    if (regs.rasterizer.scissor_test.mode != Pica::RasterizerRegs::ScissorMode::Disabled &&
        regs.rasterizer.scissor_test.mode != Pica::RasterizerRegs::ScissorMode::Include)
        return {Error::InvalidDraw, "PICA scissor mode is invalid"};
    if (regs.rasterizer.clip_enable)
        return unsupported("PICA custom clipping plane is not implemented");
    if (regs.rasterizer.depthmap_enable == Pica::RasterizerRegs::WBuffering)
        return unsupported("PICA W-buffering is not implemented");
    if (regs.texturing.fragment_lighting_enable)
        return unsupported("PICA fragment lighting is not implemented");
    if (regs.texturing.main_config.texture3_enable)
        return unsupported("PICA procedural texture3 is not implemented");
    if (regs.texturing.fog_mode != Texturing::FogMode::None)
        return unsupported("PICA fog and gas are not implemented");
    if (regs.texturing.main_config.texture1_enable || regs.texturing.main_config.texture2_enable)
        return unsupported("PICA texture units 1 and 2 are not implemented");

    output = {};
    output.target_width = fb.framebuffer.GetWidth();
    output.target_height = fb.framebuffer.GetHeight();
    output.depth_bits = fb.framebuffer.depth_format == Framebuffer::DepthFormat::D16 ? 16 : 24;
    output.target_has_stencil =
        fb.framebuffer.depth_format == Framebuffer::DepthFormat::D24S8;
    output.vertices.reserve(vertices.size());
    for (const auto& vertex : vertices) {
        output.vertices.push_back({
            {vertex.pos.x.ToFloat32(), vertex.pos.y.ToFloat32(), vertex.pos.z.ToFloat32(),
             vertex.pos.w.ToFloat32()},
            {vertex.color.x.ToFloat32(), vertex.color.y.ToFloat32(), vertex.color.z.ToFloat32(),
             vertex.color.w.ToFloat32()},
            {vertex.tc0.x.ToFloat32(), vertex.tc0.y.ToFloat32()},
        });
    }

    const auto viewport = regs.rasterizer.GetViewportRect();
    output.state.viewport_x = viewport.left;
    output.state.viewport_y = fb.framebuffer.IsFlipped()
                                  ? static_cast<int32_t>(fb.framebuffer.GetHeight()) - viewport.top
                                  : viewport.bottom;
    output.state.viewport_width = viewport.GetWidth();
    output.state.viewport_height = viewport.GetHeight();
    output.state.flip_viewport_y = fb.framebuffer.IsFlipped();
    if (regs.rasterizer.scissor_test.mode == Pica::RasterizerRegs::ScissorMode::Include) {
        output.state.scissor_enable = true;
        output.state.scissor_x = regs.rasterizer.scissor_test.x1;
        output.state.scissor_width = regs.rasterizer.scissor_test.x2.Value() -
                                         regs.rasterizer.scissor_test.x1.Value() +
                                     1;
        output.state.scissor_height = regs.rasterizer.scissor_test.y2.Value() -
                                          regs.rasterizer.scissor_test.y1.Value() +
                                      1;
        output.state.scissor_y = fb.framebuffer.IsFlipped()
                                     ? fb.framebuffer.GetHeight() -
                                           (regs.rasterizer.scissor_test.y2.Value() + 1)
                                     : regs.rasterizer.scissor_test.y1.Value();
    }
    output.state.blend_enable = merger.alphablend_enable;
    output.state.color_blend_equation =
        static_cast<BlendEquation>(merger.alpha_blending.blend_equation_rgb.Value());
    output.state.alpha_blend_equation =
        static_cast<BlendEquation>(merger.alpha_blending.blend_equation_a.Value());
    output.state.source_color_blend_factor =
        static_cast<BlendFactor>(merger.alpha_blending.factor_source_rgb.Value());
    output.state.destination_color_blend_factor =
        static_cast<BlendFactor>(merger.alpha_blending.factor_dest_rgb.Value());
    output.state.source_alpha_blend_factor =
        static_cast<BlendFactor>(merger.alpha_blending.factor_source_a.Value());
    output.state.destination_alpha_blend_factor =
        static_cast<BlendFactor>(merger.alpha_blending.factor_dest_a.Value());
    output.state.blend_constant = rgba8(merger.blend_const.raw);
    switch (regs.rasterizer.cull_mode) {
    case Pica::RasterizerRegs::CullMode::KeepAll:
    case Pica::RasterizerRegs::CullMode::KeepAll2:
        output.state.cull_mode = CullMode::KeepAll;
        break;
    case Pica::RasterizerRegs::CullMode::KeepClockWise:
        output.state.cull_mode = CullMode::KeepClockwise;
        break;
    case Pica::RasterizerRegs::CullMode::KeepCounterClockWise:
        output.state.cull_mode = CullMode::KeepCounterClockwise;
        break;
    }
    output.state.pica_depth_scale =
        Pica::f24::FromRaw(regs.rasterizer.viewport_depth_range).ToFloat32();
    output.state.pica_depth_offset =
        Pica::f24::FromRaw(regs.rasterizer.viewport_depth_near_plane).ToFloat32();
    output.state.depth_test_enable = merger.depth_test_enable;
    output.state.depth_write_enable = merger.depth_write_enable;
    output.state.depth_compare = static_cast<CompareFunc>(merger.depth_test_func.Value());
    output.state.stencil_test_enable = merger.stencil_test.enable;
    output.state.stencil_compare =
        static_cast<CompareFunc>(merger.stencil_test.func.Value());
    output.state.stencil_fail =
        static_cast<StencilAction>(merger.stencil_test.action_stencil_fail.Value());
    output.state.stencil_depth_fail =
        static_cast<StencilAction>(merger.stencil_test.action_depth_fail.Value());
    output.state.stencil_depth_pass =
        static_cast<StencilAction>(merger.stencil_test.action_depth_pass.Value());
    output.state.stencil_reference = merger.stencil_test.reference_value;
    output.state.stencil_read_mask = merger.stencil_test.input_mask;
    output.state.stencil_write_mask = fb.framebuffer.allow_depth_stencil_write
                                          ? merger.stencil_test.write_mask.Value()
                                          : 0;
    output.state.alpha_test_enable = merger.alpha_test.enable;
    output.state.alpha_compare = static_cast<CompareFunc>(merger.alpha_test.func.Value());
    output.state.alpha_reference = merger.alpha_test.ref;
    output.state.combiner_buffer_color = rgba8(regs.texturing.tev_combiner_buffer_color.raw);

    const auto pica_stages = regs.texturing.GetTevStages();
    for (size_t i = 0; i < pica_stages.size(); ++i) {
        const auto& from = pica_stages[i];
        auto& to = output.state.tev[i];
        const std::array color_sources{from.color_source1.Value(), from.color_source2.Value(),
                                       from.color_source3.Value()};
        const std::array alpha_sources{from.alpha_source1.Value(), from.alpha_source2.Value(),
                                       from.alpha_source3.Value()};
        const std::array color_modifiers{from.color_modifier1.Value(), from.color_modifier2.Value(),
                                         from.color_modifier3.Value()};
        const std::array alpha_modifiers{from.alpha_modifier1.Value(), from.alpha_modifier2.Value(),
                                         from.alpha_modifier3.Value()};
        for (size_t j = 0; j < 3; ++j) {
            if (!source(color_sources[j], to.color_source[j]) ||
                !source(alpha_sources[j], to.alpha_source[j]) ||
                !color_modifier(color_modifiers[j], to.color_modifier[j]) ||
                !alpha_modifier(alpha_modifiers[j], to.alpha_modifier[j]))
                return unsupported("PICA TEV references an unsupported source or modifier");
        }
        if (!operation(from.color_op, to.color_operation) ||
            !operation(from.alpha_op, to.alpha_operation))
            return unsupported("PICA TEV operation is unsupported");
        to.color_multiplier = from.GetColorMultiplier();
        to.alpha_multiplier = from.GetAlphaMultiplier();
        to.update_buffer_color =
            regs.texturing.tev_combiner_buffer_input.TevStageUpdatesCombinerBufferColor(i);
        to.update_buffer_alpha =
            regs.texturing.tev_combiner_buffer_input.TevStageUpdatesCombinerBufferAlpha(i);
        to.constant = rgba8(from.const_color);
    }

    if (regs.texturing.main_config.texture0_enable) {
        const auto& config = regs.texturing.texture0;
        if (!texture0) return {Error::InvalidDraw, "enabled PICA texture0 has no decoded pixels"};
        if (static_cast<uint32_t>(regs.texturing.texture0_format.Value()) >
                static_cast<uint32_t>(Texturing::TextureFormat::ETC1A4) ||
            config.type != Texturing::TextureConfig::Texture2D || config.lod.max_level != 0)
            return unsupported("PICA Metal first slice supports only non-mipmapped texture2D");
        output.texture0 = *texture0;
        output.texture0_enabled = true;
        if (config.min_filter != config.mag_filter || !wrap(config.wrap_s, output.texture0.wrap_s) ||
            !wrap(config.wrap_t, output.texture0.wrap_t))
            return unsupported("PICA texture0 filter or wrap mode is unsupported");
        output.texture0.filter = config.min_filter == Texturing::TextureConfig::Linear
                                     ? TextureFilter::Linear
                                     : TextureFilter::Nearest;
        if (texture0->width != config.width || texture0->height != config.height)
            return {Error::InvalidDraw, "decoded texture0 dimensions differ from PICA registers"};
    }
    return {};
}

} // namespace mh4u::pica_metal
