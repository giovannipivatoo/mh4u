#include "pica_metal.h"

#include <array>
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

    std::puts("{\"mode\":\"pica-metal-golden\",\"passed\":true,"
              "\"scope\":\"post-PICA-vertex-output rasterization\","
              "\"draw_batches\":2,\"depth_retained\":true,"
              "\"texture0_rgba8\":true,\"tev_accelerated\":157,"
              "\"tev_software_reference\":156,\"persistent_target\":true,"
              "\"rgba8_import\":true,\"game_integrated\":false}");
}
