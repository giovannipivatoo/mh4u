#include "vulkan_bridge.h"
#define VK_NO_PROTOTYPES
#include <libretro_vulkan.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace VulkanBridge {
namespace {
struct State {
    void *library = nullptr;
    retro_hw_render_callback hardware{};
    retro_hw_render_context_negotiation_interface_vulkan negotiation{};
    retro_hw_render_interface_vulkan interface{};
    bool hardwareRegistered = false, negotiationRegistered = false;
    bool coreContextStarted = false, deviceNegotiated = false, fenceSubmitted = false;
    VkInstance instance = VK_NULL_HANDLE;
    retro_vulkan_context context{};
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = nullptr;
    std::mutex queueMutex;
    std::mutex frameMutex;
    const retro_vulkan_image *image = nullptr;
    std::vector<VkSemaphore> waitSemaphores;
    std::vector<VkCommandBuffer> producerCommands;
    VkSemaphore signalSemaphore = VK_NULL_HANDLE;
    uint32_t sourceFamily = VK_QUEUE_FAMILY_IGNORED;
    std::vector<uint8_t> bgra;
    std::string gpuName, callbackError;
    uint64_t frames = 0;
    double seconds = 0;
    PFN_vkGetInstanceProcAddr getInstanceProcAddr = nullptr;
    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
#define VK_FUNCTION(name) PFN_vk##name name = nullptr
    VK_FUNCTION(CreateInstance); VK_FUNCTION(DestroyInstance);
    VK_FUNCTION(EnumerateInstanceExtensionProperties); VK_FUNCTION(EnumeratePhysicalDevices);
    VK_FUNCTION(GetPhysicalDeviceProperties); VK_FUNCTION(GetPhysicalDeviceMemoryProperties);
    VK_FUNCTION(GetPhysicalDeviceQueueFamilyProperties); VK_FUNCTION(EnumerateDeviceExtensionProperties);
    VK_FUNCTION(CreateDevice); VK_FUNCTION(DestroyDevice); VK_FUNCTION(DeviceWaitIdle);
    VK_FUNCTION(CreateCommandPool); VK_FUNCTION(DestroyCommandPool); VK_FUNCTION(ResetCommandPool);
    VK_FUNCTION(AllocateCommandBuffers); VK_FUNCTION(BeginCommandBuffer); VK_FUNCTION(EndCommandBuffer);
    VK_FUNCTION(CreateFence); VK_FUNCTION(DestroyFence); VK_FUNCTION(ResetFences); VK_FUNCTION(WaitForFences);
    VK_FUNCTION(CreateBuffer); VK_FUNCTION(DestroyBuffer); VK_FUNCTION(GetBufferMemoryRequirements);
    VK_FUNCTION(AllocateMemory); VK_FUNCTION(FreeMemory); VK_FUNCTION(BindBufferMemory);
    VK_FUNCTION(MapMemory); VK_FUNCTION(UnmapMemory);
    VK_FUNCTION(CmdPipelineBarrier); VK_FUNCTION(CmdCopyImageToBuffer); VK_FUNCTION(QueueSubmit);
#undef VK_FUNCTION
};
State state;
constexpr VkDeviceSize stagingBytes = 400 * 480 * 4;

void check(VkResult result, const char *operation) {
    if (result != VK_SUCCESS)
        throw std::runtime_error(std::string(operation) + " failed: VkResult " + std::to_string(result));
}

template <class T> T instanceFunction(const char *name) {
    auto result = reinterpret_cast<T>(state.getInstanceProcAddr(state.instance, name));
    if (!result) throw std::runtime_error(std::string("Missing Vulkan function: ") + name);
    return result;
}

template <class T> T deviceFunction(const char *name) {
    auto result = reinterpret_cast<T>(state.getDeviceProcAddr(state.context.device, name));
    if (!result) throw std::runtime_error(std::string("Missing Vulkan device function: ") + name);
    return result;
}

bool contains(const std::vector<VkExtensionProperties> &properties, const char *name) {
    return std::any_of(properties.begin(), properties.end(), [&](const auto &p) { return std::strcmp(p.extensionName, name) == 0; });
}

std::vector<const char *> instanceExtensions() {
    uint32_t count = 0;
    check(state.EnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
    std::vector<VkExtensionProperties> properties(count);
    check(state.EnumerateInstanceExtensionProperties(nullptr, &count, properties.data()), "Read instance extensions");
    std::vector<const char *> extensions;
    for (const char *name : {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME, VK_KHR_SURFACE_EXTENSION_NAME})
        if (contains(properties, name)) extensions.push_back(name);
    return extensions;
}

VkInstance createInstanceWrapper(void *, const VkInstanceCreateInfo *requested) {
    if (!requested) return VK_NULL_HANDLE;
    VkInstanceCreateInfo info = *requested;
    std::vector<const char *> extensions = instanceExtensions();
    for (uint32_t i = 0; i < info.enabledExtensionCount; ++i)
        if (std::none_of(extensions.begin(), extensions.end(), [&](const char *e) { return std::strcmp(e, info.ppEnabledExtensionNames[i]) == 0; }))
            extensions.push_back(info.ppEnabledExtensionNames[i]);
    for (const char *e : extensions)
        if (std::strcmp(e, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0)
            info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    info.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    info.ppEnabledExtensionNames = extensions.data();
    VkInstance instance = VK_NULL_HANDLE;
    check(state.CreateInstance(&info, nullptr, &instance), "Create Vulkan instance");
    return instance;
}

VkDevice createDeviceWrapper(VkPhysicalDevice gpu, void *, const VkDeviceCreateInfo *requested) {
    if (!requested) return VK_NULL_HANDLE;
    VkDeviceCreateInfo info = *requested;
    std::vector<const char *> extensions;
    for (uint32_t i = 0; i < info.enabledExtensionCount; ++i) extensions.push_back(info.ppEnabledExtensionNames[i]);
    uint32_t count = 0;
    check(state.EnumerateDeviceExtensionProperties(gpu, nullptr, &count, nullptr), "Enumerate device extensions");
    std::vector<VkExtensionProperties> available(count);
    check(state.EnumerateDeviceExtensionProperties(gpu, nullptr, &count, available.data()), "Read device extensions");
    constexpr const char *portability = "VK_KHR_portability_subset";
    if (contains(available, portability) && std::none_of(extensions.begin(), extensions.end(), [&](const char *e) { return std::strcmp(e, portability) == 0; }))
        extensions.push_back(portability);
    info.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    info.ppEnabledExtensionNames = extensions.data();
    VkDevice device = VK_NULL_HANDLE;
    // Preserve all core-requested features; add the portability extension required by MoltenVK.
    check(state.CreateDevice(gpu, &info, nullptr, &device), "Create negotiated Vulkan device");
    return device;
}

void setImage(void *handle, const retro_vulkan_image *image, uint32_t count, const VkSemaphore *semaphores, uint32_t family) {
    auto &s = *static_cast<State *>(handle);
    std::lock_guard<std::mutex> lock(s.frameMutex);
    if (!image || count > 64 || (count && !semaphores)) {
        s.callbackError = "Invalid libretro Vulkan image or semaphore list";
        return;
    }
    s.image = image; // libretro guarantees its lifetime until video_refresh returns.
    s.waitSemaphores.clear();
    if (count) s.waitSemaphores.assign(semaphores, semaphores + count);
    s.sourceFamily = family;
}

void setCommands(void *handle, uint32_t count, const VkCommandBuffer *commands) {
    auto &s = *static_cast<State *>(handle);
    std::lock_guard<std::mutex> lock(s.frameMutex);
    if (count > 128 || s.producerCommands.size() + count > 128 || (count && !commands)) {
        s.callbackError = "Invalid libretro Vulkan command buffer list";
        return;
    }
    if (count) s.producerCommands.insert(s.producerCommands.end(), commands, commands + count);
}

uint32_t syncIndex(void *) { return 0; }
uint32_t syncMask(void *) { return 1; }
void waitSync(void *handle) {
    auto &s = *static_cast<State *>(handle);
    std::lock_guard<std::mutex> lock(s.frameMutex);
    // video() completes its fence before returning, so sync index zero is immediately reusable.
    if (s.fenceSubmitted) {
        VkResult result = s.WaitForFences(s.context.device, 1, &s.fence, VK_TRUE, 10000000000ULL);
        if (result != VK_SUCCESS) s.callbackError = "Vulkan sync-index fence failed";
    }
}
void lockQueue(void *handle) { static_cast<State *>(handle)->queueMutex.lock(); }
void unlockQueue(void *handle) { static_cast<State *>(handle)->queueMutex.unlock(); }
void setSignal(void *handle, VkSemaphore semaphore) {
    auto &s = *static_cast<State *>(handle);
    std::lock_guard<std::mutex> lock(s.frameMutex);
    s.signalSemaphore = semaphore;
}
uintptr_t framebuffer() { return 0; }
retro_proc_address_t procAddress(const char *name) {
    return reinterpret_cast<retro_proc_address_t>(state.getInstanceProcAddr ? state.getInstanceProcAddr(state.instance, name) : nullptr);
}

void submit(const std::vector<VkCommandBuffer> &commands, bool waitForProducer) {
    std::vector<VkPipelineStageFlags> waitStages(state.waitSemaphores.size(), VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    VkSubmitInfo info{};
    info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    if (waitForProducer) {
        info.waitSemaphoreCount = static_cast<uint32_t>(state.waitSemaphores.size());
        info.pWaitSemaphores = state.waitSemaphores.data();
        info.pWaitDstStageMask = waitStages.data();
    }
    info.commandBufferCount = static_cast<uint32_t>(commands.size());
    info.pCommandBuffers = commands.data();
    if (state.signalSemaphore != VK_NULL_HANDLE) {
        info.signalSemaphoreCount = 1;
        info.pSignalSemaphores = &state.signalSemaphore;
    }
    check(state.ResetFences(state.context.device, 1, &state.fence), "Reset readback fence");
    {
        std::lock_guard<std::mutex> lock(state.queueMutex);
        check(state.QueueSubmit(state.context.queue, 1, &info, state.fence), "Submit Vulkan readback");
    }
    state.fenceSubmitted = true;
    check(state.WaitForFences(state.context.device, 1, &state.fence, VK_TRUE, 10000000000ULL), "Wait for Vulkan readback");
    state.fenceSubmitted = false;
    state.waitSemaphores.clear(); // Binary producer semaphores are consumed at most once.
    state.producerCommands.clear();
    state.signalSemaphore = VK_NULL_HANDLE;
}
} // namespace

bool environment(unsigned command, void *data) {
    switch (command) {
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto *hardware = static_cast<retro_hw_render_callback *>(data);
        if (!hardware || hardware->context_type != RETRO_HW_CONTEXT_VULKAN || !hardware->context_reset) return false;
        hardware->get_current_framebuffer = framebuffer;
        hardware->get_proc_address = procAddress;
        state.hardware = *hardware;
        state.hardwareRegistered = true;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        auto *base = static_cast<retro_hw_render_context_negotiation_interface *>(data);
        if (!base || base->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN || base->interface_version < 1) return false;
        auto *negotiation = static_cast<retro_hw_render_context_negotiation_interface_vulkan *>(data);
        state.negotiation = {};
        state.negotiation.interface_type = negotiation->interface_type;
        state.negotiation.interface_version = negotiation->interface_version;
        state.negotiation.get_application_info = negotiation->get_application_info;
        state.negotiation.create_device = negotiation->create_device;
        state.negotiation.destroy_device = negotiation->destroy_device;
        if (base->interface_version >= 2) {
            state.negotiation.create_instance = negotiation->create_instance;
            state.negotiation.create_device2 = negotiation->create_device2;
        }
        state.negotiationRegistered = true;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        if (!data || state.context.device == VK_NULL_HANDLE) return false;
        *static_cast<const retro_hw_render_interface **>(data) = reinterpret_cast<const retro_hw_render_interface *>(&state.interface);
        return true;
    case RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT: {
        auto *support = static_cast<retro_hw_render_context_negotiation_interface *>(data);
        if (!support) return false;
        support->interface_version = support->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN ? 2 : 0;
        return true;
    }
    default: return false;
    }
}

void initialize(const std::string &libraryPath) {
    if (!state.hardwareRegistered || !state.negotiationRegistered)
        throw std::runtime_error("Core did not register libretro Vulkan hardware/device negotiation");
    state.library = dlopen(libraryPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!state.library) throw std::runtime_error(std::string("Cannot load MoltenVK: ") + dlerror());
    state.getInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(state.library, "vkGetInstanceProcAddr"));
    if (!state.getInstanceProcAddr) throw std::runtime_error("MoltenVK lacks vkGetInstanceProcAddr");
#define INSTANCE(name) state.name = instanceFunction<PFN_vk##name>("vk" #name)
    INSTANCE(CreateInstance); INSTANCE(EnumerateInstanceExtensionProperties);
    VkApplicationInfo fallback{};
    fallback.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    fallback.pApplicationName = "MH4U Runtime";
    fallback.apiVersion = VK_API_VERSION_1_1;
    const VkApplicationInfo *application = state.negotiation.get_application_info ? state.negotiation.get_application_info() : nullptr;
    if (!application) application = &fallback;
    if (state.negotiation.create_instance)
        state.instance = state.negotiation.create_instance(state.getInstanceProcAddr, application, createInstanceWrapper, &state);
    else {
        VkInstanceCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        info.pApplicationInfo = application;
        state.instance = createInstanceWrapper(&state, &info);
    }
    if (!state.instance) throw std::runtime_error("Vulkan instance negotiation failed");
    INSTANCE(DestroyInstance); INSTANCE(EnumeratePhysicalDevices); INSTANCE(GetPhysicalDeviceProperties);
    INSTANCE(GetPhysicalDeviceMemoryProperties); INSTANCE(GetPhysicalDeviceQueueFamilyProperties);
    INSTANCE(EnumerateDeviceExtensionProperties); INSTANCE(CreateDevice);
#undef INSTANCE
    state.getDeviceProcAddr = instanceFunction<PFN_vkGetDeviceProcAddr>("vkGetDeviceProcAddr");
    uint32_t count = 0;
    check(state.EnumeratePhysicalDevices(state.instance, &count, nullptr), "Enumerate Vulkan GPUs");
    if (!count) throw std::runtime_error("MoltenVK exposes no physical GPU");
    std::vector<VkPhysicalDevice> devices(count);
    check(state.EnumeratePhysicalDevices(state.instance, &count, devices.data()), "Read Vulkan GPUs");
    VkPhysicalDevice gpu = devices.front();
    if (state.negotiation.create_device2)
        state.deviceNegotiated = state.negotiation.create_device2(&state.context, state.instance, gpu, VK_NULL_HANDLE, state.getInstanceProcAddr, createDeviceWrapper, &state);
    else if (state.negotiation.create_device) {
        VkPhysicalDeviceFeatures required{};
        state.deviceNegotiated = state.negotiation.create_device(&state.context, state.instance, gpu, VK_NULL_HANDLE, state.getInstanceProcAddr, nullptr, 0, nullptr, 0, &required);
    }
    if (!state.deviceNegotiated || !state.context.device || !state.context.queue || state.context.gpu != gpu)
        throw std::runtime_error("Core Vulkan device negotiation failed; software remains available with --renderer software");
#define DEVICE(name) state.name = deviceFunction<PFN_vk##name>("vk" #name)
    DEVICE(DestroyDevice); DEVICE(DeviceWaitIdle); DEVICE(CreateCommandPool); DEVICE(DestroyCommandPool);
    DEVICE(ResetCommandPool); DEVICE(AllocateCommandBuffers); DEVICE(BeginCommandBuffer); DEVICE(EndCommandBuffer);
    DEVICE(CreateFence); DEVICE(DestroyFence); DEVICE(ResetFences); DEVICE(WaitForFences);
    DEVICE(CreateBuffer); DEVICE(DestroyBuffer); DEVICE(GetBufferMemoryRequirements); DEVICE(AllocateMemory);
    DEVICE(FreeMemory); DEVICE(BindBufferMemory); DEVICE(MapMemory); DEVICE(UnmapMemory);
    DEVICE(CmdPipelineBarrier); DEVICE(CmdCopyImageToBuffer); DEVICE(QueueSubmit);
#undef DEVICE
    VkPhysicalDeviceProperties properties{};
    state.GetPhysicalDeviceProperties(gpu, &properties);
    state.gpuName = properties.deviceName;
    uint32_t familyCount = 0;
    state.GetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, nullptr);
    std::vector<VkQueueFamilyProperties> families(familyCount);
    state.GetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, families.data());
    if (state.context.queue_family_index >= familyCount ||
        (families[state.context.queue_family_index].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) != (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))
        throw std::runtime_error("Negotiated Vulkan queue must support graphics and compute");
    VkCommandPoolCreateInfo pool{};
    pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = state.context.queue_family_index;
    check(state.CreateCommandPool(state.context.device, &pool, nullptr, &state.pool), "Create readback command pool");
    VkCommandBufferAllocateInfo allocation{};
    allocation.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocation.commandPool = state.pool;
    allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    check(state.AllocateCommandBuffers(state.context.device, &allocation, &state.command), "Allocate readback command buffer");
    VkFenceCreateInfo fence{};
    fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    check(state.CreateFence(state.context.device, &fence, nullptr, &state.fence), "Create readback fence");
    VkBufferCreateInfo buffer{};
    buffer.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer.size = stagingBytes;
    buffer.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    buffer.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    check(state.CreateBuffer(state.context.device, &buffer, nullptr, &state.staging), "Create staging buffer");
    VkMemoryRequirements requirements{};
    state.GetBufferMemoryRequirements(state.context.device, state.staging, &requirements);
    VkPhysicalDeviceMemoryProperties memoryProperties{};
    state.GetPhysicalDeviceMemoryProperties(gpu, &memoryProperties);
    uint32_t memoryType = UINT32_MAX;
    for (uint32_t i = 0; i < memoryProperties.memoryTypeCount; ++i)
        if ((requirements.memoryTypeBits & (1u << i)) &&
            (memoryProperties.memoryTypes[i].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { memoryType = i; break; }
    if (memoryType == UINT32_MAX) throw std::runtime_error("MoltenVK lacks host-coherent staging memory");
    VkMemoryAllocateInfo memory{};
    memory.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    memory.allocationSize = requirements.size;
    memory.memoryTypeIndex = memoryType;
    check(state.AllocateMemory(state.context.device, &memory, nullptr, &state.memory), "Allocate staging memory");
    check(state.BindBufferMemory(state.context.device, state.staging, state.memory, 0), "Bind staging memory");
    check(state.MapMemory(state.context.device, state.memory, 0, VK_WHOLE_SIZE, 0, &state.mapped), "Map staging memory");
    state.interface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    state.interface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    state.interface.handle = &state;
    state.interface.instance = state.instance;
    state.interface.gpu = gpu;
    state.interface.device = state.context.device;
    state.interface.get_instance_proc_addr = state.getInstanceProcAddr;
    state.interface.get_device_proc_addr = state.getDeviceProcAddr;
    state.interface.queue = state.context.queue;
    state.interface.queue_index = state.context.queue_family_index;
    state.interface.set_image = setImage;
    state.interface.get_sync_index = syncIndex;
    state.interface.get_sync_index_mask = syncMask;
    state.interface.set_command_buffers = setCommands;
    state.interface.wait_sync_index = waitSync;
    state.interface.lock_queue = lockQueue;
    state.interface.unlock_queue = unlockQueue;
    state.interface.set_signal_semaphore = setSignal;
    fprintf(stderr, "Vulkan PICA via MoltenVK: %s; synchronous 400x480 staging readback to Metal presenter.\n", state.gpuName.c_str());
    state.coreContextStarted = true;
    state.hardware.context_reset();
}

void video(const void *data, unsigned width, unsigned height, retro_video_refresh_t consumeBGRA) {
    std::lock_guard<std::mutex> lock(state.frameMutex);
    if (!state.callbackError.empty()) throw std::runtime_error(state.callbackError);
    if (!state.context.device) throw std::runtime_error("Vulkan frame submitted before context initialization");
    if (!data) {
        // Duplicate frames reuse the host's previous CPU image, but must still signal requested semaphores.
        if (!state.producerCommands.empty() || state.signalSemaphore != VK_NULL_HANDLE) submit(state.producerCommands, false);
        return;
    }
    if (data != RETRO_HW_FRAME_BUFFER_VALID || !state.image || !width || !height || width > 400 || height > 480)
        throw std::runtime_error("Invalid Vulkan frame; this host bounds native output to 400x480");
    const auto &image = *state.image;
    const auto &view = image.create_info;
    if (!view.image || view.viewType != VK_IMAGE_VIEW_TYPE_2D || view.subresourceRange.levelCount != 1 || view.subresourceRange.layerCount != 1 || view.subresourceRange.aspectMask != VK_IMAGE_ASPECT_COLOR_BIT ||
        (view.components.r != VK_COMPONENT_SWIZZLE_IDENTITY && view.components.r != VK_COMPONENT_SWIZZLE_R) ||
        (view.components.g != VK_COMPONENT_SWIZZLE_IDENTITY && view.components.g != VK_COMPONENT_SWIZZLE_G) ||
        (view.components.b != VK_COMPONENT_SWIZZLE_IDENTITY && view.components.b != VK_COMPONENT_SWIZZLE_B) ||
        (view.format != VK_FORMAT_R8G8B8A8_UNORM && view.format != VK_FORMAT_R8G8B8A8_SRGB && view.format != VK_FORMAT_B8G8R8A8_UNORM && view.format != VK_FORMAT_B8G8R8A8_SRGB) ||
        (image.image_layout != VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL && image.image_layout != VK_IMAGE_LAYOUT_GENERAL))
        throw std::runtime_error("Unsupported Vulkan image format, view, or layout");
    auto started = std::chrono::steady_clock::now();
    const bool waitProducer = state.producerCommands.empty();
    bool ownership = state.sourceFamily != VK_QUEUE_FAMILY_IGNORED && state.sourceFamily != state.context.queue_family_index;
    if (ownership && (!waitProducer || state.waitSemaphores.empty()))
        throw std::runtime_error("Cross-family Vulkan images require producer ownership-transfer semaphores");
    check(state.ResetCommandPool(state.context.device, state.pool, 0), "Reset readback command pool");
    VkCommandBufferBeginInfo begin{};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    check(state.BeginCommandBuffer(state.command, &begin), "Begin readback commands");
    VkImageMemoryBarrier barrier{};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.image = view.image;
    barrier.subresourceRange = view.subresourceRange;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    if (ownership) {
        barrier.oldLayout = barrier.newLayout = image.image_layout;
        barrier.srcQueueFamilyIndex = state.sourceFamily;
        barrier.dstQueueFamilyIndex = state.context.queue_family_index;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        state.CmdPipelineBarrier(state.command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    }
    // GENERAL images must retain their layout, as the libretro contract permits concurrent readers.
    VkImageLayout copyLayout = image.image_layout == VK_IMAGE_LAYOUT_GENERAL ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.oldLayout = image.image_layout;
    barrier.newLayout = copyLayout;
    barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    state.CmdPipelineBarrier(state.command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    VkBufferImageCopy copy{};
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.mipLevel = view.subresourceRange.baseMipLevel;
    copy.imageSubresource.baseArrayLayer = view.subresourceRange.baseArrayLayer;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent = {width, height, 1};
    state.CmdCopyImageToBuffer(state.command, view.image, copyLayout, state.staging, 1, &copy);
    barrier.oldLayout = copyLayout;
    barrier.newLayout = image.image_layout;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    state.CmdPipelineBarrier(state.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    if (ownership) {
        barrier.oldLayout = barrier.newLayout = image.image_layout;
        barrier.srcQueueFamilyIndex = state.context.queue_family_index;
        barrier.dstQueueFamilyIndex = state.sourceFamily;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = 0;
        state.CmdPipelineBarrier(state.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    }
    VkBufferMemoryBarrier host{};
    host.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    host.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    host.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    host.srcQueueFamilyIndex = host.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    host.buffer = state.staging;
    host.size = VK_WHOLE_SIZE;
    state.CmdPipelineBarrier(state.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &host, 0, nullptr);
    check(state.EndCommandBuffer(state.command), "End readback commands");
    std::vector<VkCommandBuffer> commands = state.producerCommands;
    commands.push_back(state.command);
    submit(commands, waitProducer);
    state.bgra.resize(size_t(width) * height * 4);
    auto *source = static_cast<const uint8_t *>(state.mapped);
    bool rgba = view.format == VK_FORMAT_R8G8B8A8_UNORM || view.format == VK_FORMAT_R8G8B8A8_SRGB;
    for (size_t i = 0; i < state.bgra.size(); i += 4) {
        state.bgra[i] = source[i + (rgba ? 2 : 0)];
        state.bgra[i+1] = source[i+1];
        state.bgra[i+2] = source[i + (rgba ? 0 : 2)];
        state.bgra[i+3] = 255;
    }
    ++state.frames;
    state.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    consumeBGRA(state.bgra.data(), width, height, size_t(width) * 4);
}

void destroyCoreContext() noexcept {
    if (!state.coreContextStarted) return;
    state.coreContextStarted = false;
    try { if (state.hardware.context_destroy) state.hardware.context_destroy(); }
    catch (...) { fprintf(stderr, "Core threw while destroying its Vulkan context.\n"); }
}

void shutdown() noexcept {
    if (state.context.device) {
        if (state.DeviceWaitIdle) state.DeviceWaitIdle(state.context.device);
        if (state.mapped && state.UnmapMemory) state.UnmapMemory(state.context.device, state.memory);
        if (state.staging && state.DestroyBuffer) state.DestroyBuffer(state.context.device, state.staging, nullptr);
        if (state.memory && state.FreeMemory) state.FreeMemory(state.context.device, state.memory, nullptr);
        if (state.fence && state.DestroyFence) state.DestroyFence(state.context.device, state.fence, nullptr);
        if (state.pool && state.DestroyCommandPool) state.DestroyCommandPool(state.context.device, state.pool, nullptr);
    }
    if (state.deviceNegotiated && state.negotiation.destroy_device) {
        try { state.negotiation.destroy_device(); }
        catch (...) { fprintf(stderr, "Core threw while destroying auxiliary Vulkan resources.\n"); }
    }
    if (state.context.device && state.DestroyDevice) state.DestroyDevice(state.context.device, nullptr);
    if (state.instance && state.DestroyInstance) state.DestroyInstance(state.instance, nullptr);
    state.context = {};
    state.instance = VK_NULL_HANDLE;
    state.mapped = nullptr;
    state.staging = VK_NULL_HANDLE; state.memory = VK_NULL_HANDLE;
    state.fence = VK_NULL_HANDLE; state.pool = VK_NULL_HANDLE;
    state.deviceNegotiated = false;
    if (state.library) { dlclose(state.library); state.library = nullptr; }
}

uint64_t readbackFrames() { return state.frames; }
double readbackSeconds() { return state.seconds; }
const std::string &deviceName() { return state.gpuName; }
} // namespace VulkanBridge
