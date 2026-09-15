#include "core_rasterizer.h"

#include "common/color.h"
#include "common/logging/log.h"
#include "core/memory.h"
#include "video_core/pica/pica_core.h"
#include "video_core/pica/regs_framebuffer.h"
#include "video_core/utils.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <vector>

namespace mh4u::pica_metal {
namespace {

constexpr uint64_t MaxSurfaceBytes = 16 * 1024 * 1024;

struct TargetKey {
    PAddr color_address{};
    PAddr depth_address{};
    uint32_t width{};
    uint32_t height{};
    Pica::FramebufferRegs::ColorFormat color_format{};
    Pica::FramebufferRegs::DepthFormat depth_format{};

    bool operator==(const TargetKey&) const = default;
};

bool overlaps(PAddr left, uint32_t left_size, PAddr right, uint32_t right_size) {
    return static_cast<uint64_t>(left) < static_cast<uint64_t>(right) + right_size &&
           static_cast<uint64_t>(right) < static_cast<uint64_t>(left) + left_size;
}

bool fits_physical_address(PAddr address, uint64_t size) {
    return size != 0 && static_cast<uint64_t>(address) + size <=
                            std::numeric_limits<PAddr>::max();
}

bool rasterizer_cacheable(PAddr address, uint64_t size) {
    const uint64_t end = static_cast<uint64_t>(address) + size;
    const bool in_vram = address >= Memory::VRAM_PADDR && end <= Memory::VRAM_PADDR_END;
    const bool in_fcram =
        address >= Memory::FCRAM_PADDR && end <= Memory::FCRAM_N3DS_PADDR_END;
    return in_vram || in_fcram;
}

} // namespace

struct CoreRasterizer::Impl {
    Memory::MemorySystem& memory;
    Pica::PicaCore& pica;
    Renderer renderer{};
    std::vector<Pica::OutputVertex> vertices{};
    std::optional<TargetKey> key{};
    std::unique_ptr<Target> target{};
    bool dirty_color{};
    bool dirty_depth_stencil{};
    uint64_t metal_draws{};
    uint64_t submissions{};
    bool logged_non_rgba_texture{};
    bool logged_procedural_texture{};
    std::string fatal{};

    Impl(Memory::MemorySystem& memory_, Pica::PicaCore& pica_) : memory{memory_}, pica{pica_} {
        LOG_INFO(Render,
                 "Experimental PICA Metal rasterizer active: CPU PICA vertex stage, software RAM "
                 "presenter");
    }

    ~Impl() {
        LOG_INFO(Render, "PICA Metal stopped: metal_draws={} submissions={} reason={}", metal_draws,
                 submissions, fatal.empty() ? "shutdown" : fatal);
        mark_target(false);
    }

    uint32_t color_size(const TargetKey& value) const {
        return value.width * value.height * 4;
    }

    uint32_t depth_size(const TargetKey& value) const {
        return value.width * value.height *
               Pica::FramebufferRegs::BytesPerDepthPixel(value.depth_format);
    }

    void mark_target(bool cached) {
        if (!key) return;
        const auto page_start = [](PAddr address) {
            return address & ~Memory::CITRA_PAGE_MASK;
        };
        const auto page_end = [](PAddr address, uint32_t size) {
            return static_cast<PAddr>(
                (static_cast<uint64_t>(address) + size + Memory::CITRA_PAGE_MASK) &
                ~static_cast<uint64_t>(Memory::CITRA_PAGE_MASK));
        };
        const PAddr color_start = page_start(key->color_address);
        const PAddr color_end = page_end(key->color_address, color_size(*key));
        const PAddr depth_start = page_start(key->depth_address);
        const PAddr depth_end = page_end(key->depth_address, depth_size(*key));
        if (color_start <= depth_end && depth_start <= color_end) {
            const PAddr start = std::min(color_start, depth_start);
            const PAddr end = std::max(color_end, depth_end);
            memory.RasterizerMarkRegionCached(start, end - start, cached);
        } else {
            memory.RasterizerMarkRegionCached(color_start, color_end - color_start, cached);
            memory.RasterizerMarkRegionCached(depth_start, depth_end - depth_start, cached);
        }
    }

    void fail(std::string message) {
        if (!fatal.empty()) return;
        fatal = std::move(message);
        LOG_ERROR(Render, "PICA Metal fatal: metal_draws={} submissions={} reason={}", metal_draws,
                  submissions, fatal);
    }

    bool flush_color() {
        if (!dirty_color) return true;
        if (!target || !key) return false;
        const RenderResult result = renderer.readback(*target);
        if (!result) {
            fail("Metal color readback failed: " + result.message);
            return false;
        }
        const uint32_t size = color_size(*key);
        auto memory_ref = memory.GetPhysicalRef(key->color_address);
        if (!memory_ref || memory_ref.GetSize() < size) {
            fail("PICA Metal color target left valid guest memory before flush");
            return false;
        }
        auto destination = memory_ref.GetWriteBytes(size);
        for (uint32_t y = 0; y < key->height; ++y) {
            const uint32_t tiled_y = key->height - 1 - y;
            for (uint32_t x = 0; x < key->width; ++x) {
                const size_t source_offset = static_cast<size_t>(y) * result.image.row_bytes + x * 4;
                const size_t destination_offset =
                    VideoCore::GetMortonOffset(x, tiled_y, 4) +
                    static_cast<size_t>(tiled_y & ~7U) * key->width * 4;
                const auto color = Common::Vec4<uint8_t>{result.image.rgba8[source_offset + 0],
                                                         result.image.rgba8[source_offset + 1],
                                                         result.image.rgba8[source_offset + 2],
                                                         result.image.rgba8[source_offset + 3]};
                Common::Color::EncodeRGBA8(color, destination.data() + destination_offset);
            }
        }
        dirty_color = false;
        return true;
    }

    bool flush_depth_stencil() {
        if (!dirty_depth_stencil) return true;
        if (!target || !key) return false;
        const DepthStencilResult result = renderer.readback_depth_stencil(*target);
        if (!result) {
            fail("Metal depth/stencil readback failed: " + result.message);
            return false;
        }
        const uint32_t size = depth_size(*key);
        auto memory_ref = memory.GetPhysicalRef(key->depth_address);
        if (!memory_ref || memory_ref.GetSize() < size) {
            fail("PICA Metal depth target left valid guest memory before flush");
            return false;
        }
        auto destination = memory_ref.GetWriteBytes(size);
        const uint32_t bytes_per_pixel =
            Pica::FramebufferRegs::BytesPerDepthPixel(key->depth_format);
        const uint32_t depth_bits =
            Pica::FramebufferRegs::DepthBitsPerPixel(key->depth_format);
        const uint32_t max_depth = (1U << depth_bits) - 1U;
        for (uint32_t y = 0; y < key->height; ++y) {
            const uint32_t tiled_y = key->height - 1 - y;
            for (uint32_t x = 0; x < key->width; ++x) {
                const size_t source = static_cast<size_t>(y) * key->width + x;
                const size_t destination_offset =
                    VideoCore::GetMortonOffset(x, tiled_y, bytes_per_pixel) +
                    static_cast<size_t>(tiled_y & ~7U) * key->width * bytes_per_pixel;
                const double normalized = std::clamp(static_cast<double>(result.image.depth[source]),
                                                     0.0, 1.0);
                const uint32_t depth =
                    static_cast<uint32_t>(std::llround(normalized * max_depth));
                auto* output = destination.data() + destination_offset;
                switch (key->depth_format) {
                case Pica::FramebufferRegs::DepthFormat::D16:
                    Common::Color::EncodeD16(depth, output);
                    break;
                case Pica::FramebufferRegs::DepthFormat::D24:
                    Common::Color::EncodeD24(depth, output);
                    break;
                case Pica::FramebufferRegs::DepthFormat::D24S8:
                    Common::Color::EncodeD24S8(depth, result.image.stencil[source], output);
                    break;
                }
            }
        }
        dirty_depth_stencil = false;
        return true;
    }

    std::vector<uint8_t> decode_color(std::span<const uint8_t> source, uint32_t width,
                                      uint32_t height) {
        std::vector<uint8_t> result(static_cast<size_t>(width) * height * 4);
        for (uint32_t y = 0; y < height; ++y) {
            const uint32_t tiled_y = height - 1 - y;
            for (uint32_t x = 0; x < width; ++x) {
                const size_t source_offset = VideoCore::GetMortonOffset(x, tiled_y, 4) +
                                             static_cast<size_t>(tiled_y & ~7U) * width * 4;
                const auto color = Common::Color::DecodeRGBA8(source.data() + source_offset);
                const size_t destination = (static_cast<size_t>(y) * width + x) * 4;
                std::memcpy(result.data() + destination, color.AsArray(), 4);
            }
        }
        return result;
    }

    void decode_depth_stencil(std::span<const uint8_t> source, const TargetKey& value,
                              std::vector<float>& depth, std::vector<uint8_t>& stencil) {
        const size_t pixel_count = static_cast<size_t>(value.width) * value.height;
        depth.resize(pixel_count);
        if (value.depth_format == Pica::FramebufferRegs::DepthFormat::D24S8)
            stencil.resize(pixel_count);
        const uint32_t bytes_per_pixel =
            Pica::FramebufferRegs::BytesPerDepthPixel(value.depth_format);
        const uint32_t depth_bits =
            Pica::FramebufferRegs::DepthBitsPerPixel(value.depth_format);
        const float max_depth = static_cast<float>((1U << depth_bits) - 1U);
        for (uint32_t y = 0; y < value.height; ++y) {
            const uint32_t tiled_y = value.height - 1 - y;
            for (uint32_t x = 0; x < value.width; ++x) {
                const size_t source_offset =
                    VideoCore::GetMortonOffset(x, tiled_y, bytes_per_pixel) +
                    static_cast<size_t>(tiled_y & ~7U) * value.width * bytes_per_pixel;
                const size_t destination = static_cast<size_t>(y) * value.width + x;
                const auto* input = source.data() + source_offset;
                uint32_t depth_value{};
                switch (value.depth_format) {
                case Pica::FramebufferRegs::DepthFormat::D16:
                    depth_value = Common::Color::DecodeD16(input);
                    break;
                case Pica::FramebufferRegs::DepthFormat::D24:
                    depth_value = Common::Color::DecodeD24(input);
                    break;
                case Pica::FramebufferRegs::DepthFormat::D24S8: {
                    const auto decoded = Common::Color::DecodeD24S8(input);
                    depth_value = decoded.x;
                    stencil[destination] = static_cast<uint8_t>(decoded.y);
                    break;
                }
                }
                depth[destination] = static_cast<float>(depth_value) / max_depth;
            }
        }
    }

    bool ensure_target(const Pica::RegsInternal& regs) {
        const auto& fb = regs.framebuffer.framebuffer;
        if (fb.color_format != Pica::FramebufferRegs::ColorFormat::RGBA8) {
            fail("core adapter supports only RGBA8 render targets");
            return false;
        }
        if (fb.depth_format != Pica::FramebufferRegs::DepthFormat::D16 &&
            fb.depth_format != Pica::FramebufferRegs::DepthFormat::D24 &&
            fb.depth_format != Pica::FramebufferRegs::DepthFormat::D24S8) {
            fail("core adapter rejected invalid PICA depth format");
            return false;
        }
        TargetKey requested{fb.GetColorBufferPhysicalAddress(), fb.GetDepthBufferPhysicalAddress(),
                            fb.GetWidth(), fb.GetHeight(), fb.color_format.Value(),
                            fb.depth_format.Value()};
        const uint64_t color_bytes = static_cast<uint64_t>(requested.width) * requested.height * 4;
        const uint64_t depth_bytes = static_cast<uint64_t>(requested.width) * requested.height *
                                     Pica::FramebufferRegs::BytesPerDepthPixel(
                                         requested.depth_format);
        if (!requested.width || !requested.height || requested.width % 8 || requested.height % 8 ||
            color_bytes > MaxSurfaceBytes || depth_bytes > MaxSurfaceBytes ||
            !fits_physical_address(requested.color_address, color_bytes) ||
            !fits_physical_address(requested.depth_address, depth_bytes) ||
            !rasterizer_cacheable(requested.color_address, color_bytes) ||
            !rasterizer_cacheable(requested.depth_address, depth_bytes) ||
            overlaps(requested.color_address, color_bytes, requested.depth_address, depth_bytes)) {
            fail("core adapter rejected invalid, uncacheable, or aliased PICA target intervals");
            return false;
        }
        if (key && *key == requested) return true;
        if (key) {
            if (!flush_color()) return false;
            if (!flush_depth_stencil()) return false;
            mark_target(false);
            target.reset();
            key.reset();
        }
        auto color_ref = memory.GetPhysicalRef(requested.color_address);
        auto depth_ref = memory.GetPhysicalRef(requested.depth_address);
        if (!color_ref || color_ref.GetSize() < color_bytes || !depth_ref ||
            depth_ref.GetSize() < depth_bytes) {
            fail("core adapter target interval is outside guest physical memory");
            return false;
        }
        const auto color = color_ref.GetReadBytes<uint8_t>(color_bytes);
        const auto depth = depth_ref.GetReadBytes<uint8_t>(depth_bytes);
        const uint32_t depth_bits = Pica::FramebufferRegs::DepthBitsPerPixel(requested.depth_format);
        std::vector<uint8_t> imported_color =
            decode_color(color, requested.width, requested.height);
        std::vector<float> imported_depth{};
        std::vector<uint8_t> imported_stencil{};
        decode_depth_stencil(depth, requested, imported_depth, imported_stencil);
        TargetDescriptor descriptor{
            requested.width,
            requested.height,
            depth_bits,
            requested.depth_format == Pica::FramebufferRegs::DepthFormat::D24S8,
            {},
            1.0f,
            0,
            imported_color,
            requested.width * 4,
            imported_depth,
            imported_stencil,
        };
        TargetResult created = renderer.create_target(descriptor);
        if (!created) {
            fail("core adapter target creation failed: " + created.message);
            return false;
        }
        key = requested;
        target = std::move(created.target);
        mark_target(true);
        dirty_color = false;
        dirty_depth_stencil = false;
        return true;
    }
};

CoreRasterizer::CoreRasterizer(Memory::MemorySystem& memory, Pica::PicaCore& pica)
    : impl_(std::make_unique<Impl>(memory, pica)) {}
CoreRasterizer::~CoreRasterizer() = default;

void CoreRasterizer::AddTriangle(const Pica::OutputVertex& v0, const Pica::OutputVertex& v1,
                                 const Pica::OutputVertex& v2) {
    if (!impl_->fatal.empty()) return;
    impl_->vertices.insert(impl_->vertices.end(), {v0, v1, v2});
    if (impl_->vertices.size() > 65536) impl_->fail("PICA Metal vertex batch exceeds 65536 vertices");
}

void CoreRasterizer::DrawTriangles() {
    if (!impl_->fatal.empty() || impl_->vertices.empty()) return;
    const auto& regs = impl_->pica.regs.internal;
    AzaharTexture0 decoded_texture{};
    TextureRgba8 texture{};
    const TextureRgba8* texture_pointer = nullptr;
    if (regs.texturing.main_config.texture0_enable) {
        const auto& config = regs.texturing.texture0;
        const auto format = regs.texturing.texture0_format.Value();
        const uint32_t format_value = static_cast<uint32_t>(format);
        AzaharTextureLayout layout{};
        const ValidationResult texture_layout = azahar_texture0_layout(regs, layout);
        if (!texture_layout) {
            impl_->fail("core adapter rejected texture0 format=" + std::to_string(format_value) +
                        " dimensions=" + std::to_string(config.width.Value()) + "x" +
                        std::to_string(config.height.Value()) + ": " + texture_layout.message);
            impl_->vertices.clear();
            return;
        }
        const PAddr address = config.GetPhysicalAddress();
        const uint32_t size = layout.encoded_bytes;
        if (!fits_physical_address(address, size)) {
            impl_->fail("core adapter texture0 interval overflows physical address space");
            impl_->vertices.clear();
            return;
        }
        if (impl_->key && overlaps(address, size, impl_->key->color_address,
                                   impl_->color_size(*impl_->key)) &&
            !impl_->flush_color()) {
            impl_->vertices.clear();
            return;
        }
        if (impl_->key && overlaps(address, size, impl_->key->depth_address,
                                   impl_->depth_size(*impl_->key)) &&
            !impl_->flush_depth_stencil()) {
            impl_->vertices.clear();
            return;
        }
        auto texture_ref = impl_->memory.GetPhysicalRef(address);
        if (!texture_ref || texture_ref.GetSize() < size) {
            impl_->fail("core adapter texture0 interval is outside guest physical memory");
            impl_->vertices.clear();
            return;
        }
        const auto encoded = texture_ref.GetReadBytes<uint8_t>(size);
        const ValidationResult decoded = decode_azahar_texture0(regs, encoded, decoded_texture);
        if (!decoded) {
            impl_->fail("core adapter failed texture0 decode: " + decoded.message);
            impl_->vertices.clear();
            return;
        }
        if (format != Pica::TexturingRegs::TextureFormat::RGBA8 &&
            !impl_->logged_non_rgba_texture) {
            impl_->logged_non_rgba_texture = true;
            LOG_INFO(Render,
                     "PICA Metal decoded texture0 format={} dimensions={}x{} encoded_bytes={} "
                     "decoded_bytes={}",
                     format_value, config.width.Value(), config.height.Value(),
                     layout.encoded_bytes, layout.decoded_bytes);
        }
        texture = decoded_texture.view();
        texture_pointer = &texture;
    }
    AzaharProceduralTexture decoded_procedural{};
    const ProceduralTexture* procedural_pointer = nullptr;
    if (regs.texturing.main_config.texture3_enable) {
        std::array<uint32_t, 128> color_map{};
        std::array<uint32_t, 256> color{};
        std::array<uint32_t, 256> color_difference{};
        for (size_t i = 0; i < color_map.size(); ++i)
            color_map[i] = impl_->pica.proctex.color_map_table[i].raw;
        for (size_t i = 0; i < color.size(); ++i) {
            color[i] = impl_->pica.proctex.color_table[i].raw;
            color_difference[i] = impl_->pica.proctex.color_diff_table[i].raw;
        }
        const ValidationResult snapshot = decode_azahar_procedural_texture(
            color_map, color, color_difference, decoded_procedural);
        if (!snapshot) {
            impl_->fail("core adapter failed procedural texture snapshot: " + snapshot.message);
            impl_->vertices.clear();
            return;
        }
        procedural_pointer = &decoded_procedural.snapshot;
    }
    AzaharDraw converted{};
    const ValidationResult decoded = decode_azahar_draw(
        regs, impl_->vertices, texture_pointer, procedural_pointer, converted);
    impl_->vertices.clear();
    if (!decoded) {
        impl_->fail("core adapter rejected live PICA state: " + decoded.message);
        return;
    }
    if (converted.procedural_texture_enabled && !impl_->logged_procedural_texture) {
        impl_->logged_procedural_texture = true;
        LOG_INFO(Render,
                 "PICA Metal procedural texture3: coord=2 clamp=edge map=U filter=linear "
                 "width=128 offset=0");
    }
    if (!impl_->ensure_target(regs)) return;
    const Draw draw = converted.view();
    ++impl_->submissions;
    const ValidationResult rendered = impl_->renderer.draw(*impl_->target, std::span{&draw, 1});
    if (!rendered) {
        impl_->fail("core adapter Metal draw failed: " + rendered.message);
        return;
    }
    ++impl_->metal_draws;
    impl_->dirty_color = true;
    impl_->dirty_depth_stencil =
        impl_->dirty_depth_stencil || converted.state.depth_write_enable ||
        (converted.state.stencil_test_enable && converted.state.stencil_write_mask != 0);
}

void CoreRasterizer::FlushAll() {
    if (!impl_->flush_color()) return;
    impl_->flush_depth_stencil();
}

void CoreRasterizer::FlushRegion(PAddr addr, u32 size) {
    if (!impl_->key || !size) return;
    if (overlaps(addr, size, impl_->key->color_address, impl_->color_size(*impl_->key)))
        impl_->flush_color();
    if (overlaps(addr, size, impl_->key->depth_address, impl_->depth_size(*impl_->key)))
        impl_->flush_depth_stencil();
}

void CoreRasterizer::InvalidateRegion(PAddr addr, u32 size) {
    if (!impl_->key || !size) return;
    const bool color_overlap =
        overlaps(addr, size, impl_->key->color_address, impl_->color_size(*impl_->key));
    const bool depth_overlap =
        overlaps(addr, size, impl_->key->depth_address, impl_->depth_size(*impl_->key));
    if (!color_overlap && !depth_overlap) return;
    if (!impl_->flush_color()) return;
    if (!impl_->flush_depth_stencil()) return;
    impl_->mark_target(false);
    impl_->target.reset();
    impl_->key.reset();
}

void CoreRasterizer::FlushAndInvalidateRegion(PAddr addr, u32 size) {
    FlushRegion(addr, size);
    if (impl_->fatal.empty()) InvalidateRegion(addr, size);
}

void CoreRasterizer::ClearAll(bool flush) {
    impl_->vertices.clear();
    if (flush) {
        FlushAll();
        if (!impl_->fatal.empty()) return;
    }
    impl_->mark_target(false);
    impl_->target.reset();
    impl_->key.reset();
    impl_->dirty_color = false;
    impl_->dirty_depth_stencil = false;
}

bool CoreRasterizer::FlushColorForPresentation() {
    return impl_->fatal.empty() && impl_->flush_color();
}

bool CoreRasterizer::healthy() const {
    return impl_->fatal.empty();
}

const std::string& CoreRasterizer::error() const {
    return impl_->fatal;
}

} // namespace mh4u::pica_metal
