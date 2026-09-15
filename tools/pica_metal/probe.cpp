#include "pica_metal.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>

using namespace mh4u::pica_metal;

namespace {

[[noreturn]] void fail(const char* message) {
    std::fprintf(stderr, "pica-metal golden failed: %s\n", message);
    std::exit(1);
}

DrawState state(uint32_t width, uint32_t height, Float4 color, float depth) {
    DrawState result{};
    result.viewport_width = width;
    result.viewport_height = height;
    result.invert_ndc_y = true;
    result.depth_test_enable = true;
    result.depth_write_enable = true;
    result.depth_compare = CompareFunc::Less;
    result.pica_depth_scale = -1.0f;
    result.pica_depth_offset = 0.0f;
    result.tev[0].color_source = {TevSource::Constant, TevSource::Constant,
                                  TevSource::Constant};
    result.tev[0].alpha_source = {TevSource::Constant, TevSource::Constant,
                                  TevSource::Constant};
    result.tev[0].constant = color;
    for (size_t i = 1; i < result.tev.size(); ++i) {
        result.tev[i].color_source[0] = TevSource::Previous;
        result.tev[i].alpha_source[0] = TevSource::Previous;
    }
    (void)depth;
    return result;
}

std::array<OutputVertex, 3> triangle(float z) {
    return {{{{-0.9f, -0.9f, z, 1.0f}, {1, 1, 1, 1}, {0.5f, 0.5f}},
             {{0.9f, -0.9f, z, 1.0f}, {1, 1, 1, 1}, {0.5f, 0.5f}},
             {{0.0f, 0.9f, z, 1.0f}, {1, 1, 1, 1}, {0.5f, 0.5f}}}};
}

std::array<OutputVertex, 3> positive_y_triangle(float z) {
    return {{{{-0.5f, 0.2f, z, 1.0f}, {1, 1, 1, 1}},
             {{0.5f, 0.2f, z, 1.0f}, {1, 1, 1, 1}},
             {{0.0f, 0.8f, z, 1.0f}, {1, 1, 1, 1}}}};
}

const uint8_t* pixel(const Image& image, uint32_t x, uint32_t y) {
    return image.rgba8.data() + y * image.row_bytes + x * 4;
}

void expect(const Image& image, uint32_t x, uint32_t y, std::array<uint8_t, 4> value,
            const char* message) {
    const auto* actual = pixel(image, x, y);
    for (size_t i = 0; i < value.size(); ++i) {
        if (actual[i] != value[i]) {
            std::fprintf(stderr, "actual=[%u,%u,%u,%u] expected=[%u,%u,%u,%u]\n", actual[0],
                         actual[1], actual[2], actual[3], value[0], value[1], value[2], value[3]);
            fail(message);
        }
    }
}

uint32_t depth_code(const DepthStencilImage& image, uint32_t x, uint32_t y, uint32_t bits) {
    const uint32_t maximum = (1U << bits) - 1U;
    return static_cast<uint32_t>(
        std::llround(static_cast<double>(image.depth[static_cast<size_t>(y) * image.width + x]) *
                     maximum));
}

} // namespace

int main() {
    constexpr uint32_t size = 64;
    const auto front_vertices = triangle(-0.25f);
    const auto back_vertices = triangle(-0.75f);
    auto front_state = state(size, size, {1, 0, 0, 1}, 0.25f);
    auto back_state = state(size, size, {0, 1, 0, 1}, 0.75f);
    const std::array depth_draws{
        Draw{front_vertices, front_state, nullptr},
        Draw{back_vertices, back_state, nullptr},
    };
    Renderer renderer;
    const RenderResult depth = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, depth_draws});
    if (!depth) {
        std::fprintf(stderr, "pica-metal setup/render failed: %s\n", depth.message.c_str());
        return depth.error == Error::MetalUnavailable ? 77 : 1;
    }
    expect(depth.image, 32, 32, {255, 0, 0, 255},
           "a later, occluded DrawTriangles batch replaced the retained depth/color target");
    expect(depth.image, 0, 0, {0, 0, 0, 255}, "frame clear or viewport mapping is wrong");

    const auto orientation_vertices = positive_y_triangle(-0.25f);
    const std::array orientation_draws{Draw{orientation_vertices, front_state, nullptr}};
    const RenderResult orientation = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, orientation_draws});
    if (!orientation) fail(orientation.message.c_str());
    expect(orientation.image, 32, 45, {255, 0, 0, 255},
           "Metal NDC Y did not map to increasing PICA screen Y");
    expect(orientation.image, 32, 15, {0, 0, 0, 255},
           "PICA screen Y orientation was vertically mirrored");

    const std::array<uint8_t, 4> texel{200, 101, 50, 255};
    const TextureRgba8 texture{1, 1, 4, texel};
    auto tev_state = state(size, size, {200.0f / 255.0f, 200.0f / 255.0f,
                                       200.0f / 255.0f, 1.0f},
                           0.25f);
    tev_state.tev[0].color_source[0] = TevSource::Texture0;
    tev_state.tev[0].color_source[1] = TevSource::Constant;
    tev_state.tev[0].color_operation = TevOperation::Modulate;
    const std::array tev_draws{Draw{front_vertices, tev_state, &texture}};
    const RenderResult tev = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, tev_draws});
    if (!tev) fail(tev.message.c_str());
    // Azahar's accelerated shader generator byte-rounds 200*200/255 to 157.
    // Its diagnostic software rasterizer truncates the same channel to 156.
    expect(tev.image, 32, 32, {157, 79, 39, 255},
           "RGBA8 texture sampling or accelerated TEV byte rounding is wrong");

    const std::array<uint8_t, 8> linear_texels{1, 0, 0, 255, 2, 0, 0, 255};
    const TextureRgba8 linear_texture{2, 1, 8, linear_texels, TextureFilter::Linear};
    auto linear_state = state(size, size, {204.0f / 255.0f, 0, 0, 1}, 0.25f);
    linear_state.tev[0].color_source[0] = TevSource::Texture0;
    linear_state.tev[0].color_source[1] = TevSource::Constant;
    linear_state.tev[0].color_operation = TevOperation::Modulate;
    const std::array linear_draws{Draw{front_vertices, linear_state, &linear_texture}};
    const RenderResult linear = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, linear_draws});
    if (!linear) fail(linear.message.c_str());
    expect(linear.image, 32, 32, {1, 0, 0, 255},
           "linear texture sample was byte-rounded before the TEV combiner");

    ProceduralTexture procedural{};
    for (size_t i = 0; i < procedural.color_map.size(); ++i)
        procedural.color_map[i] = {static_cast<float>(i) / 128.0f, 1.0f / 128.0f};
    procedural.color[127] = {17.0f / 255.0f, 33.0f / 255.0f, 65.0f / 255.0f, 1.0f};
    auto endpoint_vertices = front_vertices;
    for (auto& vertex : endpoint_vertices) vertex.texcoord2 = {1.0f, 0.75f};
    auto endpoint_state = state(size, size, {}, 0.25f);
    endpoint_state.tev[0].color_source[0] = TevSource::ProceduralTexture;
    endpoint_state.tev[0].alpha_source[0] = TevSource::ProceduralTexture;
    const std::array endpoint_draws{
        Draw{endpoint_vertices, endpoint_state, nullptr, &procedural}};
    const RenderResult endpoint = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, endpoint_draws});
    if (!endpoint) fail(endpoint.message.c_str());
    expect(endpoint.image, 32, 32, {17, 33, 65, 255},
           "procedural texture endpoint u=1 did not use map[127] plus its difference");

    procedural.color[10] = {200.0f / 255.0f, 0, 0, 1};
    procedural.color_difference[10] = {-18.0f / 255.0f, 0, 0, 0};
    auto difference_vertices = front_vertices;
    for (auto& vertex : difference_vertices)
        vertex.texcoord2 = {10.25f / 127.0f, 0.25f};
    auto difference_state = state(size, size, {204.0f / 255.0f, 1, 1, 1}, 0.25f);
    difference_state.tev[0].color_source[0] = TevSource::ProceduralTexture;
    difference_state.tev[0].color_source[1] = TevSource::Constant;
    difference_state.tev[0].color_operation = TevOperation::Modulate;
    difference_state.tev[0].alpha_source[0] = TevSource::ProceduralTexture;
    const std::array difference_draws{
        Draw{difference_vertices, difference_state, nullptr, &procedural}};
    const RenderResult difference = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 1.0f, 24, difference_draws});
    if (!difference) fail(difference.message.c_str());
    expect(difference.image, 32, 32, {156, 0, 0, 255},
           "procedural signed difference or post-combiner TEV rounding is wrong");

    auto alpha_state = state(size, size, {0, 0, 1, 153.0f / 255.0f}, 0.5f);
    alpha_state.depth_compare = CompareFunc::Equal;
    alpha_state.depth_write_enable = false;
    alpha_state.tev[0].alpha_source[0] = TevSource::Previous;
    alpha_state.tev[0].alpha_source[2] = TevSource::Constant;
    const auto equal_vertices = triangle(-0.5f);
    const std::array equal_draws{Draw{equal_vertices, alpha_state, nullptr}};
    const RenderResult equal = renderer.render(
        Frame{size, size, {0, 0, 0, 1}, 0.5f, 16, equal_draws});
    if (!equal) fail(equal.message.c_str());
    expect(equal.image, 32, 32, {0, 0, 255, 153},
           "D16 clear quantization or accelerated stage-zero alpha Previous mapping is wrong");

    auto unsupported_state = front_state;
    unsupported_state.depth_mode = DepthMode::WBuffering;
    const std::array unsupported_draws{Draw{front_vertices, unsupported_state, nullptr}};
    const ValidationResult unsupported = validate(
        Frame{size, size, {}, 1.0f, 24, unsupported_draws});
    if (unsupported.error != Error::UnsupportedState) fail("W-buffer state did not fail closed");

    std::vector<uint8_t> initial_color(8 * 8 * 4, 0);
    for (size_t i = 0; i < initial_color.size(); i += 4) {
        initial_color[i + 2] = 255;
        initial_color[i + 3] = 255;
    }
    TargetResult imported = renderer.create_target(
        TargetDescriptor{8, 8, 24, false, {}, 1.0f, 0, initial_color, 8 * 4});
    if (!imported) fail(imported.message.c_str());
    const RenderResult imported_image = renderer.readback(*imported.target);
    if (!imported_image) fail(imported_image.message.c_str());
    expect(imported_image.image, 4, 4, {0, 0, 255, 255},
           "explicit RGBA8 target import was not retained");

    TargetResult persistent = renderer.create_target(
        TargetDescriptor{size, size, 24, false, {0, 0, 0, 1}, 1.0f});
    if (!persistent) fail(persistent.message.c_str());
    const Draw front_draw{front_vertices, front_state, nullptr};
    if (const auto result = renderer.draw(*persistent.target, std::span{&front_draw, 1}); !result)
        fail(result.message.c_str());
    const RenderResult first_readback = renderer.readback(*persistent.target);
    if (!first_readback) fail(first_readback.message.c_str());
    expect(first_readback.image, 32, 32, {255, 0, 0, 255},
           "first persistent target draw was not stored");
    const Draw back_draw{back_vertices, back_state, nullptr};
    if (const auto result = renderer.draw(*persistent.target, std::span{&back_draw, 1}); !result)
        fail(result.message.c_str());
    const RenderResult second_readback = renderer.readback(*persistent.target);
    if (!second_readback) fail(second_readback.message.c_str());
    expect(second_readback.image, 32, 32, {255, 0, 0, 255},
           "LoadActionLoad failed to retain persistent color/depth across submissions");

    std::vector<float> initial_d16(8 * 8, 0.0f);
    constexpr uint32_t d16_max = (1U << 16) - 1U;
    for (size_t i = 0; i < initial_d16.size(); ++i)
        initial_d16[i] = static_cast<float>((i * 997U + 1U) & d16_max) / d16_max;
    TargetResult d16_imported = renderer.create_target(
        TargetDescriptor{8, 8, 16, false, {}, 1.0f, 0, {}, 0, initial_d16, {}});
    if (!d16_imported) fail(d16_imported.message.c_str());
    const DepthStencilResult d16_snapshot =
        renderer.readback_depth_stencil(*d16_imported.target);
    if (!d16_snapshot) fail(d16_snapshot.message.c_str());
    if (depth_code(d16_snapshot.image, 0, 0, 16) != 1 ||
        depth_code(d16_snapshot.image, 7, 7, 16) != ((63U * 997U + 1U) & d16_max) ||
        !d16_snapshot.image.stencil.empty())
        fail("D16 per-pixel import/readback did not preserve adjacent quantized values");

    constexpr uint32_t ds_size = 8;
    constexpr uint32_t d24_max = (1U << 24) - 1U;
    std::vector<float> initial_d24s8(ds_size * ds_size);
    std::vector<uint8_t> initial_stencil(ds_size * ds_size);
    for (size_t i = 0; i < initial_d24s8.size(); ++i) {
        initial_d24s8[i] = static_cast<float>((i * 131071U + 1U) & d24_max) / d24_max;
        initial_stencil[i] = (i % 2 == 0) ? 3 : 7;
    }
    const size_t center_index = 4 * ds_size + 4;
    initial_d24s8[center_index] = 0.75f;
    initial_stencil[center_index] = 3;
    TargetResult d24s8_imported = renderer.create_target(TargetDescriptor{
        ds_size, ds_size, 24, true, {}, 1.0f, 0, {}, 0, initial_d24s8, initial_stencil});
    if (!d24s8_imported) fail(d24s8_imported.message.c_str());
    const DepthStencilResult before_draw =
        renderer.readback_depth_stencil(*d24s8_imported.target);
    if (!before_draw) fail(before_draw.message.c_str());
    if (depth_code(before_draw.image, 0, 0, 24) != 1 ||
        before_draw.image.stencil[0] != 3 || before_draw.image.stencil[1] != 7)
        fail("D24S8 per-pixel import did not preserve depth/stencil planes");

    const auto ds_vertices = triangle(-0.25f);
    auto ds_state = state(ds_size, ds_size, {1, 1, 1, 1}, 0.25f);
    ds_state.stencil_test_enable = true;
    ds_state.stencil_compare = CompareFunc::Equal;
    ds_state.stencil_reference = 3;
    ds_state.stencil_depth_pass = StencilAction::IncrementClamp;
    const Draw ds_draw{ds_vertices, ds_state, nullptr};
    if (const auto result = renderer.draw(*d24s8_imported.target, std::span{&ds_draw, 1}); !result)
        fail(result.message.c_str());
    const DepthStencilResult after_draw =
        renderer.readback_depth_stencil(*d24s8_imported.target);
    if (!after_draw) fail(after_draw.message.c_str());
    if (depth_code(after_draw.image, 4, 4, 24) != d24_max / 4 ||
        after_draw.image.stencil[center_index] != 4 ||
        depth_code(after_draw.image, 0, 0, 24) != 1 || after_draw.image.stencil[0] != 3)
        fail("D24S8 imported compare/write/readback did not preserve per-pixel state");

    std::puts("{\"mode\":\"pica-metal-golden\",\"passed\":true,"
              "\"scope\":\"post-PICA-vertex-output rasterization\","
              "\"draw_batches\":2,\"depth_retained\":true,"
              "\"pica_screen_y_orientation\":true,"
              "\"texture0_rgba8\":true,\"tev_accelerated\":157,"
              "\"tev_software_reference\":156,\"linear_sample_float\":true,"
              "\"procedural_texture_observed_profile\":true,"
              "\"persistent_target\":true,"
              "\"rgba8_import\":true,\"depth_stencil_snapshot\":true,"
              "\"game_integrated\":false}");
}
