#include "azahar_adapter.h"

#include "video_core/pica/output_vertex.h"
#include "video_core/pica/regs_internal.h"

#include <array>
#include <cstdio>
#include <vector>

using namespace mh4u::pica_metal;

namespace {

Pica::RegsInternal registers() {
    Pica::RegsInternal regs{};
    regs.framebuffer.framebuffer.color_format.Assign(Pica::FramebufferRegs::ColorFormat::RGBA8);
    regs.framebuffer.framebuffer.depth_format.Assign(Pica::FramebufferRegs::DepthFormat::D24S8);
    regs.framebuffer.framebuffer.allow_color_write.Assign(1);
    regs.framebuffer.framebuffer.allow_depth_stencil_write.Assign(1);
    regs.framebuffer.framebuffer.width.Assign(64);
    regs.framebuffer.framebuffer.height.Assign(63);
    regs.framebuffer.framebuffer.flip.Assign(1);
    auto& merger = regs.framebuffer.output_merger;
    merger.logic_op.Assign(Pica::FramebufferRegs::LogicOp::Copy);
    merger.alphablend_enable.Assign(1);
    merger.alpha_blending.blend_equation_rgb.Assign(Pica::FramebufferRegs::BlendEquation::Add);
    merger.alpha_blending.blend_equation_a.Assign(Pica::FramebufferRegs::BlendEquation::Add);
    merger.alpha_blending.factor_source_rgb.Assign(Pica::FramebufferRegs::BlendFactor::One);
    merger.alpha_blending.factor_dest_rgb.Assign(Pica::FramebufferRegs::BlendFactor::Zero);
    merger.alpha_blending.factor_source_a.Assign(Pica::FramebufferRegs::BlendFactor::One);
    merger.alpha_blending.factor_dest_a.Assign(Pica::FramebufferRegs::BlendFactor::Zero);
    merger.red_enable.Assign(1);
    merger.green_enable.Assign(1);
    merger.blue_enable.Assign(1);
    merger.alpha_enable.Assign(1);
    merger.depth_test_enable.Assign(1);
    merger.depth_write_enable.Assign(1);
    merger.depth_test_func.Assign(Pica::FramebufferRegs::CompareFunc::LessThan);
    merger.stencil_test.enable.Assign(1);
    merger.stencil_test.func.Assign(Pica::FramebufferRegs::CompareFunc::Always);
    merger.stencil_test.action_stencil_fail.Assign(Pica::FramebufferRegs::StencilAction::Keep);
    merger.stencil_test.action_depth_fail.Assign(Pica::FramebufferRegs::StencilAction::Keep);
    merger.stencil_test.action_depth_pass.Assign(Pica::FramebufferRegs::StencilAction::Replace);
    merger.stencil_test.reference_value.Assign(7);
    merger.stencil_test.input_mask.Assign(0xff);
    merger.stencil_test.write_mask.Assign(0xff);
    regs.rasterizer.scissor_test.mode.Assign(Pica::RasterizerRegs::ScissorMode::Include);
    regs.rasterizer.scissor_test.x2.Assign(63);
    regs.rasterizer.scissor_test.y2.Assign(63);
    regs.rasterizer.viewport_size_x.Assign(0x440000); // float24(32)
    regs.rasterizer.viewport_size_y.Assign(0x440000);
    regs.rasterizer.viewport_depth_range.Assign(0xbf0000); // float24(-1)
    regs.rasterizer.depthmap_enable.Assign(Pica::RasterizerRegs::ZBuffering);
    return regs;
}

std::array<Pica::OutputVertex, 3> vertices() {
    std::array<Pica::OutputVertex, 3> result{};
    constexpr std::array positions{
        std::array{-0.5f, -0.5f}, std::array{0.5f, -0.5f}, std::array{0.0f, 0.5f}};
    for (size_t i = 0; i < result.size(); ++i) {
        result[i].pos = {Pica::f24::FromFloat32(positions[i][0]),
                         Pica::f24::FromFloat32(positions[i][1]),
                         Pica::f24::FromFloat32(-0.25f), Pica::f24::One()};
        result[i].color = {Pica::f24::One(), Pica::f24::Zero(), Pica::f24::Zero(),
                           Pica::f24::One()};
    }
    return result;
}

} // namespace

int main() {
    auto regs = registers();
    const auto input = vertices();
    AzaharDraw output{};
    const ValidationResult accepted = decode_azahar_draw(regs, input, nullptr, output);
    if (!accepted || output.vertices.size() != 3 || output.target_width != 64 ||
        output.target_height != 64 || output.depth_bits != 24 ||
        output.state.viewport_width != 64 || output.state.viewport_height != 64 ||
        !output.target_has_stencil || output.state.depth_compare != CompareFunc::Less ||
        !output.state.stencil_test_enable || !output.state.scissor_enable ||
        output.vertices[0].clip_position.z != -0.25f) {
        std::fprintf(stderr, "adapter acceptance failed: %s\n", accepted.message.c_str());
        return 1;
    }

    regs = registers();
    regs.texturing.main_config.texture0_enable.Assign(1);
    regs.texturing.texture0_format.Assign(Pica::TexturingRegs::TextureFormat::ETC1A4);
    regs.texturing.texture0.width.Assign(8);
    regs.texturing.texture0.height.Assign(8);
    regs.texturing.texture0.type.Assign(Pica::TexturingRegs::TextureConfig::Texture2D);
    std::vector<uint8_t> decoded_pixels(8 * 8 * 4, 255);
    const TextureRgba8 decoded_texture{8, 8, 8 * 4, decoded_pixels};
    const ValidationResult decoded_format =
        decode_azahar_draw(regs, input, &decoded_texture, output);
    if (!decoded_format || !output.texture0_enabled) {
        std::fprintf(stderr, "adapter rejected decoded ETC1A4 texture0: %s\n",
                     decoded_format.message.c_str());
        return 1;
    }

    regs = registers();
    regs.framebuffer.output_merger.alphablend_enable.Assign(0);
    regs.framebuffer.output_merger.logic_op.Assign(Pica::FramebufferRegs::LogicOp::Xor);
    const ValidationResult rejected = decode_azahar_draw(regs, input, nullptr, output);
    if (rejected.error != Error::UnsupportedState) {
        std::fprintf(stderr, "adapter failed to reject unsupported PICA blending\n");
        return 1;
    }
    regs = registers();
    if (!decode_azahar_draw(regs, input, nullptr, output)) return 1;
    const Draw draw = output.view();
    const std::array draws{draw};
    Renderer renderer;
    const RenderResult rendered = renderer.render(
        Frame{output.target_width, output.target_height, {0, 0, 0, 1}, 1.0f,
              output.depth_bits, draws, output.target_has_stencil, 0});
    if (!rendered) {
        std::fprintf(stderr, "adapter GPU render failed: %s\n", rendered.message.c_str());
        return rendered.error == Error::MetalUnavailable ? 77 : 1;
    }
    const auto* center = rendered.image.rgba8.data() + 32 * rendered.image.row_bytes + 32 * 4;
    if (center[0] != 255 || center[1] != 0 || center[2] != 0 || center[3] != 255) {
        std::fprintf(stderr, "adapter decoded draw did not reach expected Metal output\n");
        return 1;
    }
    std::puts("{\"mode\":\"pica-metal-azahar-adapter\",\"passed\":true,"
              "\"source\":\"RasterizerInterface::AddTriangle OutputVertex + RegsInternal\","
              "\"gpu_rendered\":true}");
}
