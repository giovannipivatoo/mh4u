#pragma once

#include <cstdint>
#include <libretro.h>
#include <string>

// One synchronous libretro Vulkan context; no Vulkan swapchain or external loader.
namespace VulkanBridge {
bool environment(unsigned command, void *data);
void initialize(const std::string &libraryPath);
void video(const void *data, unsigned width, unsigned height, retro_video_refresh_t consumeBGRA);
void destroyCoreContext() noexcept;
void shutdown() noexcept;
uint64_t readbackFrames();
double readbackSeconds();
const std::string &deviceName();
} // namespace VulkanBridge
