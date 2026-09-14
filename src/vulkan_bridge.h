#pragma once

#include <cstdint>
#include <libretro.h>
#include <string>
#include <vector>

// One synchronous libretro Vulkan context; no Vulkan swapchain or external loader.
namespace VulkanBridge {
inline constexpr unsigned maxResolutionScale = 4;
// This host always requests the vertically stacked, unswapped 3DS layout.
constexpr bool validFrameDimensions(unsigned width, unsigned height) {
    return width >= 400 && width <= 400 * maxResolutionScale &&
           width % 400 == 0 && height == (width / 400) * 480;
}
bool environment(unsigned command, void *data);
void initialize(const std::string &libraryPath);
using ConsumeBGRA = void (*)(std::vector<uint8_t> &pixels, unsigned width, unsigned height);
void video(const void *data, unsigned width, unsigned height, ConsumeBGRA consumeBGRA);
void destroyCoreContext() noexcept;
void shutdown() noexcept;
uint64_t readbackFrames();
double readbackSeconds();
const std::string &deviceName();
} // namespace VulkanBridge
