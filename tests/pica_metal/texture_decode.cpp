#include "azahar_adapter.h"

#include "common/color.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/utils.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

using Format = Pica::TexturingRegs::TextureFormat;
using namespace mh4u::pica_metal;

[[noreturn]] void fail(const char* message) {
    std::fprintf(stderr, "pica-metal texture decode failed: %s\n", message);
    std::exit(1);
}

Pica::RegsInternal registers(Format format) {
    Pica::RegsInternal regs{};
    regs.texturing.texture0.width.Assign(8);
    regs.texturing.texture0.height.Assign(8);
    regs.texturing.texture0_format.Assign(format);
    return regs;
}

void expect(const AzaharTexture0& texture, uint32_t x, uint32_t y,
            std::array<uint8_t, 4> expected, const char* message) {
    const size_t offset = (static_cast<size_t>(y) * texture.width + x) * 4;
    for (size_t index = 0; index < expected.size(); ++index) {
        if (texture.rgba8[offset + index] != expected[index]) fail(message);
    }
}

} // namespace

int main() {
    constexpr std::array expected_tile_bytes{
        256U, 192U, 128U, 128U, 128U, 128U, 128U,
        64U,  64U,  64U,  32U,  32U,  32U,  64U,
    };
    for (uint32_t value = 0; value < expected_tile_bytes.size(); ++value) {
        auto regs = registers(static_cast<Format>(value));
        AzaharTextureLayout layout{};
        const ValidationResult result = azahar_texture0_layout(regs, layout);
        if (!result || layout.encoded_bytes != expected_tile_bytes[value] ||
            layout.decoded_bytes != 8 * 8 * 4)
            fail("adapter tile byte calculation differs from PICA format table");
    }

    constexpr uint32_t x = 3;
    constexpr uint32_t source_y = 2;
    constexpr uint32_t output_y = 8 - 1 - source_y;
    auto rgba_regs = registers(Format::RGBA8);
    std::vector<uint8_t> rgba(expected_tile_bytes[0]);
    Common::Color::EncodeRGBA8({17, 34, 51, 68},
                               rgba.data() + VideoCore::MortonInterleave(x, source_y) * 4);
    AzaharTexture0 decoded{};
    if (!decode_azahar_texture0(rgba_regs, rgba, decoded)) fail("RGBA8 decode was rejected");
    expect(decoded, x, output_y, {17, 34, 51, 68},
           "RGBA8 Morton/y-flipped texel did not decode to RGBA");
    if (decode_azahar_texture0(rgba_regs, std::span{rgba}.first(rgba.size() - 1), decoded).error !=
        Error::InvalidDraw)
        fail("truncated encoded texture span was not rejected");

    auto i4_regs = registers(Format::I4);
    std::vector<uint8_t> i4(expected_tile_bytes[10]);
    const uint32_t nibble = VideoCore::MortonInterleave(x, source_y);
    i4[nibble / 2] = nibble % 2 ? 0xb0 : 0x0b;
    if (!decode_azahar_texture0(i4_regs, i4, decoded)) fail("I4 decode was rejected");
    expect(decoded, x, output_y, {187, 187, 187, 255},
           "I4 nibble order did not decode to RGBA");

    auto etc1a4_regs = registers(Format::ETC1A4);
    std::vector<uint8_t> etc1a4(expected_tile_bytes[13]);
    for (size_t subtile = 0; subtile < 4; ++subtile)
        std::fill_n(etc1a4.data() + subtile * 16, 8, 0xaa);
    if (!decode_azahar_texture0(etc1a4_regs, etc1a4, decoded))
        fail("ETC1A4 decode was rejected");
    expect(decoded, x, output_y, {2, 2, 2, 170},
           "ETC1A4 alpha/color subtiles did not decode to RGBA");

    auto oversized = registers(Format::RGBA8);
    oversized.texturing.texture0.width.Assign(2040);
    oversized.texturing.texture0.height.Assign(2040);
    AzaharTextureLayout layout{};
    if (azahar_texture0_layout(oversized, layout).error != Error::UnsupportedState)
        fail("oversized decoded texture was not rejected before allocation");

    AzaharTexture0Cache cache{};
    TextureRgba8 cached{};
    std::vector<uint8_t> cache_bytes(expected_tile_bytes[0]);
    if (!cache.resolve(rgba_regs, 0x18000000, cache_bytes, cached) ||
        cache.stats().misses != 1 || cache.stats().hits != 0)
        fail("first texture cache lookup was not a miss");
    if (!cache.resolve(rgba_regs, 0x18000000, cache_bytes, cached) ||
        cache.stats().hits != 1)
        fail("identical owned texture cache lookup was not a hit");
    const std::vector<uint8_t> cached_before_change(cached.pixels.begin(), cached.pixels.end());
    cache_bytes[0] ^= 1;
    if (!std::equal(cached.pixels.begin(), cached.pixels.end(), cached_before_change.begin()))
        fail("texture cache retained a pointer into mutable guest bytes");
    if (!cache.resolve(rgba_regs, 0x18000000, cache_bytes, cached) ||
        cache.stats().misses != 2 ||
        std::equal(cached.pixels.begin(), cached.pixels.end(), cached_before_change.begin()))
        fail("texture byte change did not invalidate the cache");
    if (!cache.resolve(rgba_regs, 0x18000100, cache_bytes, cached) ||
        cache.stats().misses != 3)
        fail("texture address change did not invalidate the cache");

    auto rgb565_regs = registers(Format::RGB565);
    auto rgba5551_regs = registers(Format::RGB5A1);
    std::vector<uint8_t> same_size_format(expected_tile_bytes[3]);
    if (!cache.resolve(rgb565_regs, 0x18000200, same_size_format, cached))
        fail("RGB565 cache fixture was rejected");
    const std::vector<uint8_t> rgb565_pixels(cached.pixels.begin(), cached.pixels.end());
    if (!cache.resolve(rgba5551_regs, 0x18000200, same_size_format, cached) ||
        cache.stats().misses != 5 ||
        std::equal(cached.pixels.begin(), cached.pixels.end(), rgb565_pixels.begin()))
        fail("same-size texture format change did not invalidate the cache");

    auto wide_regs = registers(Format::RGBA8);
    wide_regs.texturing.texture0.width.Assign(16);
    auto tall_regs = registers(Format::RGBA8);
    tall_regs.texturing.texture0.height.Assign(16);
    std::vector<uint8_t> same_size_dimensions(512);
    if (!cache.resolve(wide_regs, 0x18000300, same_size_dimensions, cached) ||
        cached.width != 16 || cached.height != 8 ||
        !cache.resolve(tall_regs, 0x18000300, same_size_dimensions, cached) ||
        cached.width != 8 || cached.height != 16 || cache.stats().misses != 7 ||
        cache.stats().decoded_bytes != 2304)
        fail("same-size texture dimension change did not invalidate the cache");

    std::puts("{\"mode\":\"pica-metal-texture-decode\",\"passed\":true,"
              "\"format_sizes\":14,\"rgba8\":true,\"i4\":true,\"etc1a4\":true,"
              "\"bounds\":true,\"cache_boundary\":true}");
}
