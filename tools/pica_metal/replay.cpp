#include "azahar_adapter.h"

#include "common/color.h"
#include "video_core/pica/output_vertex.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/utils.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace mh4u::pica_metal;

namespace {

constexpr std::array<char, 8> Magic{'M', 'H', '4', 'U', 'P', 'M', 'T', '1'};
constexpr uint32_t MaxVertices = 65536;
constexpr uint32_t MaxTextureBytes = 4 * 1024 * 1024;

template <typename T>
bool read(std::ifstream& input, T& value) {
    return static_cast<bool>(input.read(reinterpret_cast<char*>(&value), sizeof(value)));
}

bool load_trace(const std::filesystem::path& path, Pica::RegsInternal& regs,
                std::vector<Pica::OutputVertex>& vertices, std::vector<uint8_t>& texture,
                std::string& error) {
    std::ifstream input(path, std::ios::binary);
    std::array<char, 8> magic{};
    uint32_t version{}, register_count{}, vertex_count{}, floats_per_vertex{}, texture_bytes{};
    if (!input || !read(input, magic) || magic != Magic || !read(input, version) ||
        !read(input, register_count) || !read(input, vertex_count) ||
        !read(input, floats_per_vertex) || !read(input, texture_bytes)) {
        error = "invalid or truncated trace header";
        return false;
    }
    if ((version != 1 && version != 2) || register_count != Pica::RegsInternal::NUM_REGS ||
        floats_per_vertex != 10 || texture_bytes > MaxTextureBytes || vertex_count > MaxVertices ||
        vertex_count == 0 || vertex_count % 3 != 0) {
        error = "unsupported trace shape";
        return false;
    }
    if (!input.read(reinterpret_cast<char*>(regs.reg_array.data()),
                    static_cast<std::streamsize>(regs.reg_array.size() * sizeof(uint32_t)))) {
        error = "truncated register payload";
        return false;
    }
    if (version == 1 && texture_bytes != 0) {
        error = "version-one trace contains texture bytes";
        return false;
    }
    if (version == 2) {
        if (regs.texturing.main_config.texture0_enable) {
            const auto format = regs.texturing.texture0_format.Value();
            const uint64_t width = regs.texturing.texture0.width;
            const uint64_t height = regs.texturing.texture0.height;
            if (format > Pica::TexturingRegs::TextureFormat::ETC1A4 || !width || !height ||
                width % 8 || height % 8) {
                error = "captured texture0 metadata is invalid";
                return false;
            }
            const uint64_t expected = format == Pica::TexturingRegs::TextureFormat::RGBA8
                                          ? width * height * 4
                                          : texture_bytes;
            if (texture_bytes && texture_bytes != expected) {
                error = "captured texture0 span differs from register-derived tiled size";
                return false;
            }
        } else if (texture_bytes) {
            error = "trace contains texture bytes while texture0 is disabled";
            return false;
        }
    }
    vertices.resize(vertex_count);
    for (auto& vertex : vertices) {
        std::array<float, 10> values{};
        if (!input.read(reinterpret_cast<char*>(values.data()), sizeof(values))) {
            error = "truncated vertex payload";
            return false;
        }
        if (!std::all_of(values.begin(), values.end(),
                         [](float value) { return std::isfinite(value); })) {
            error = "non-finite vertex payload";
            return false;
        }
        vertex.pos = {Pica::f24::FromFloat32(values[0]), Pica::f24::FromFloat32(values[1]),
                      Pica::f24::FromFloat32(values[2]), Pica::f24::FromFloat32(values[3])};
        vertex.color = {Pica::f24::FromFloat32(values[4]), Pica::f24::FromFloat32(values[5]),
                        Pica::f24::FromFloat32(values[6]), Pica::f24::FromFloat32(values[7])};
        vertex.tc0 = {Pica::f24::FromFloat32(values[8]), Pica::f24::FromFloat32(values[9])};
    }
    texture.resize(texture_bytes);
    if (texture_bytes &&
        !input.read(reinterpret_cast<char*>(texture.data()),
                    static_cast<std::streamsize>(texture.size()))) {
        error = "truncated texture0 payload";
        return false;
    }
    char extra{};
    if (input.read(&extra, 1)) {
        error = "unexpected trailing trace data";
        return false;
    }
    return true;
}

TextureRgba8 decode_texture0(const Pica::RegsInternal& regs, std::span<const uint8_t> encoded,
                            std::vector<uint8_t>& decoded) {
    const auto& config = regs.texturing.texture0;
    decoded.resize(static_cast<size_t>(config.width) * config.height * 4);
    for (uint32_t y = 0; y < config.height; ++y) {
        for (uint32_t x = 0; x < config.width; ++x) {
            const uint32_t tiled_y = config.height - 1 - y;
            const size_t tile = (static_cast<size_t>(tiled_y / 8) * (config.width / 8) + x / 8) *
                                8 * 8 * 4;
            const auto texel = Common::Color::DecodeRGBA8(
                encoded.data() + tile + VideoCore::MortonInterleave(x, tiled_y) * 4);
            const size_t offset = (static_cast<size_t>(y) * config.width + x) * 4;
            decoded[offset + 0] = texel.x;
            decoded[offset + 1] = texel.y;
            decoded[offset + 2] = texel.z;
            decoded[offset + 3] = texel.w;
        }
    }
    return {config.width, config.height, config.width * 4, decoded};
}

uint64_t fnv1a(std::span<const uint8_t> bytes) {
    uint64_t hash = 14695981039346656037ULL;
    for (const uint8_t value : bytes) {
        hash ^= value;
        hash *= 1099511628211ULL;
    }
    return hash;
}

void print_string(const std::string& value) {
    for (const char c : value) {
        if (c == '\\' || c == '"') std::putchar('\\');
        if (c == '\n') {
            std::fputs("\\n", stdout);
        } else {
            std::putchar(c);
        }
    }
}

bool write_ppm(const std::filesystem::path& path, const Image& image, std::string& error) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << "P6\n" << image.width << ' ' << image.height << "\n255\n";
    for (uint32_t y = 0; y < image.height; ++y) {
        const uint8_t* row = image.rgba8.data() + y * image.row_bytes;
        for (uint32_t x = 0; x < image.width; ++x)
            output.write(reinterpret_cast<const char*>(row + x * 4), 3);
    }
    if (!output) {
        error = "failed to write isolated replay PPM";
        return false;
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: pica-metal-trace-replay TRACE_DIRECTORY\n");
        return 2;
    }
    std::error_code filesystem_error;
    std::vector<std::filesystem::path> paths{};
    for (std::filesystem::directory_iterator it(argv[1], filesystem_error), end;
         !filesystem_error && it != end; it.increment(filesystem_error)) {
        if (it->is_regular_file() && it->path().extension() == ".bin") paths.push_back(it->path());
    }
    if (filesystem_error || paths.empty() || paths.size() > 8) {
        std::fprintf(stderr, "trace directory must contain between one and eight .bin files\n");
        return 2;
    }
    std::sort(paths.begin(), paths.end());
    const std::filesystem::path output_directory =
        std::filesystem::path(argv[1]).parent_path() / "replay-output";
    std::filesystem::create_directories(output_directory, filesystem_error);
    if (filesystem_error) {
        std::fprintf(stderr, "failed to create replay output directory\n");
        return 2;
    }

    Renderer renderer;
    uint32_t decoded{}, rendered{}, rejected{}, invalid{}, gpu_failures{};
    std::puts("{\"mode\":\"pica-metal-actual-batch-replay\",\"batches\":[");
    for (size_t index = 0; index < paths.size(); ++index) {
        Pica::RegsInternal regs{};
        std::vector<Pica::OutputVertex> vertices{};
        std::vector<uint8_t> encoded_texture{};
        std::vector<uint8_t> decoded_texture{};
        std::string message{};
        AzaharDraw converted{};
        Error result_error = Error::None;
        uint64_t image_hash{};
        bool did_render{};
        uint64_t rgb_nonzero_pixels{};
        uint64_t alpha_nonzero_pixels{};
        uint8_t max_rgb{};
        std::string ppm_path{};
        if (!load_trace(paths[index], regs, vertices, encoded_texture, message)) {
            ++invalid;
            result_error = Error::InvalidDraw;
        } else {
            ValidationResult result{};
            TextureRgba8 texture{};
            const TextureRgba8* texture_pointer = nullptr;
            if (regs.texturing.main_config.texture0_enable && encoded_texture.empty()) {
                result = {Error::UnsupportedState,
                          "trace format does not capture enabled texture0 bytes"};
            } else if (regs.texturing.main_config.texture0_enable &&
                       regs.texturing.texture0_format !=
                           Pica::TexturingRegs::TextureFormat::RGBA8) {
                result = {Error::UnsupportedState,
                          "replay decoder supports only captured tiled RGBA8 texture0"};
            } else {
                if (regs.texturing.main_config.texture0_enable) {
                    texture = decode_texture0(regs, encoded_texture, decoded_texture);
                    texture_pointer = &texture;
                }
                result = decode_azahar_draw(regs, vertices, texture_pointer, nullptr, converted);
            }
            result_error = result.error;
            message = result.message;
            if (result) {
                ++decoded;
                const Draw draw = converted.view();
                const std::array draws{draw};
                const RenderResult gpu = renderer.render(
                    Frame{converted.target_width, converted.target_height, {0, 0, 0, 0}, 1.0f,
                          converted.depth_bits, draws, converted.target_has_stencil, 0});
                result_error = gpu.error;
                message = gpu.message;
                if (gpu) {
                    ++rendered;
                    did_render = true;
                    image_hash = fnv1a(gpu.image.rgba8);
                    for (uint32_t y = 0; y < gpu.image.height; ++y) {
                        const uint8_t* row = gpu.image.rgba8.data() + y * gpu.image.row_bytes;
                        for (uint32_t x = 0; x < gpu.image.width; ++x) {
                            const uint8_t* pixel = row + x * 4;
                            rgb_nonzero_pixels += pixel[0] || pixel[1] || pixel[2];
                            alpha_nonzero_pixels += pixel[3] != 0;
                            max_rgb = std::max({max_rgb, pixel[0], pixel[1], pixel[2]});
                        }
                    }
                    const auto output_path = output_directory / (paths[index].stem().string() + ".ppm");
                    if (!write_ppm(output_path, gpu.image, message)) {
                        result_error = Error::Submission;
                        ++gpu_failures;
                        did_render = false;
                    } else {
                        ppm_path = output_path.string();
                    }
                } else if (gpu.error == Error::MetalUnavailable) {
                    std::fprintf(stderr, "Metal is unavailable: %s\n", gpu.message.c_str());
                    return 77;
                } else {
                    ++gpu_failures;
                }
            } else if (result.error == Error::UnsupportedState) {
                ++rejected;
            } else {
                ++invalid;
            }
        }
        std::printf("{\"file\":\"");
        print_string(paths[index].filename().string());
        const auto& merger = regs.framebuffer.output_merger;
        std::printf("\",\"vertices\":%zu,\"features\":{\"color_format\":%u,"
                    "\"depth_format\":%u,\"target\":\"%u/%u\",\"flipped\":%u,"
                    "\"stencil_enable\":%u,\"stencil_func\":%u,"
                    "\"stencil_ops\":\"%u/%u/%u\",\"blend_enable\":%u,"
                    "\"blend_rgb\":\"%u/%u/%u\",\"blend_alpha\":\"%u/%u/%u\","
                    "\"texture0_enable\":%u,\"lighting_enable\":%u,"
                    "\"texture0_format\":%u,\"texture0_size\":\"%u/%u\","
                    "\"texture0_type\":%u,\"texture0_max_level\":%u,"
                    "\"procedural_texture\":%u,\"fog_mode\":%u,"
                    "\"scissor_mode\":%u,\"scissor\":\"%u/%u/%u/%u\"},"
                    "\"texture_bytes\":%zu,\"texture_fnv1a64\":\"%016llx\","
                    "\"error\":%u,\"rendered\":%s,"
                    "\"image_fnv1a64\":\"%016llx\",\"rgb_nonzero_pixels\":%llu,"
                    "\"alpha_nonzero_pixels\":%llu,\"max_rgb\":%u,"
                    "\"ppm\":\"",
                    vertices.size(),
                    static_cast<unsigned>(regs.framebuffer.framebuffer.color_format.Value()),
                    static_cast<unsigned>(regs.framebuffer.framebuffer.depth_format.Value()),
                    regs.framebuffer.framebuffer.GetWidth(),
                    regs.framebuffer.framebuffer.GetHeight(),
                    static_cast<unsigned>(regs.framebuffer.framebuffer.IsFlipped()),
                    static_cast<unsigned>(
                        regs.framebuffer.output_merger.stencil_test.enable.Value()),
                    static_cast<unsigned>(merger.stencil_test.func.Value()),
                    static_cast<unsigned>(merger.stencil_test.action_stencil_fail.Value()),
                    static_cast<unsigned>(merger.stencil_test.action_depth_fail.Value()),
                    static_cast<unsigned>(merger.stencil_test.action_depth_pass.Value()),
                    static_cast<unsigned>(
                        regs.framebuffer.output_merger.alphablend_enable.Value()),
                    static_cast<unsigned>(merger.alpha_blending.blend_equation_rgb.Value()),
                    static_cast<unsigned>(merger.alpha_blending.factor_source_rgb.Value()),
                    static_cast<unsigned>(merger.alpha_blending.factor_dest_rgb.Value()),
                    static_cast<unsigned>(merger.alpha_blending.blend_equation_a.Value()),
                    static_cast<unsigned>(merger.alpha_blending.factor_source_a.Value()),
                    static_cast<unsigned>(merger.alpha_blending.factor_dest_a.Value()),
                    static_cast<unsigned>(regs.texturing.main_config.texture0_enable.Value()),
                    static_cast<unsigned>(regs.texturing.fragment_lighting_enable.Value()),
                    static_cast<unsigned>(regs.texturing.texture0_format.Value()),
                    static_cast<unsigned>(regs.texturing.texture0.width.Value()),
                    static_cast<unsigned>(regs.texturing.texture0.height.Value()),
                    static_cast<unsigned>(regs.texturing.texture0.type.Value()),
                    static_cast<unsigned>(regs.texturing.texture0.lod.max_level.Value()),
                    static_cast<unsigned>(regs.texturing.main_config.texture3_enable.Value()),
                    static_cast<unsigned>(regs.texturing.fog_mode.Value()),
                    static_cast<unsigned>(regs.rasterizer.scissor_test.mode.Value()),
                    static_cast<unsigned>(regs.rasterizer.scissor_test.x1.Value()),
                    static_cast<unsigned>(regs.rasterizer.scissor_test.y1.Value()),
                    static_cast<unsigned>(regs.rasterizer.scissor_test.x2.Value()),
                    static_cast<unsigned>(regs.rasterizer.scissor_test.y2.Value()),
                    encoded_texture.size(),
                    static_cast<unsigned long long>(fnv1a(encoded_texture)),
                    static_cast<unsigned>(result_error),
                    did_render ? "true" : "false", static_cast<unsigned long long>(image_hash),
                    static_cast<unsigned long long>(rgb_nonzero_pixels),
                    static_cast<unsigned long long>(alpha_nonzero_pixels),
                    static_cast<unsigned>(max_rgb));
        print_string(ppm_path);
        std::printf("\",\"message\":\"");
        print_string(message);
        std::printf("\"}%s\n", index + 1 == paths.size() ? "" : ",");
    }
    std::printf("] ,\"decoded\":%u,\"rendered\":%u,\"unsupported\":%u,\"invalid\":%u,"
                "\"gpu_failures\":%u,\"trace_reader_versions\":[1,2],"
                "\"replay_mode\":\"isolated batch with transparent color/depth-one/stencil-zero clear\","
                "\"game_renderer_integrated\":false}\n",
                decoded, rendered, rejected, invalid, gpu_failures);
    return invalid || gpu_failures ? 1 : 0;
}
