#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <AudioToolbox/AudioToolbox.h>
#include <CommonCrypto/CommonDigest.h>
#include <libretro.h>
#include "vulkan_bridge.h"
#include "controller_config.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sandbox.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static volatile sig_atomic_t stopped = 0;
static void stopSignal(int) { stopped = 1; }
static bool headless = false;
static bool useVulkan = false;
static bool keys[128]{};
static uint8_t keyLatchFrames[128]{};
static bool pointerPressed = false;
static int16_t pointerX = 0, pointerY = 0;
static uint8_t pointerLatchFrames = 0;
static int16_t pointerLatchX = 0, pointerLatchY = 0;
static bool controllerCursorAvailable = false, controllerTouchPressed = false;
static float controllerCursorX = .5f, controllerCursorY = .5f;
static uint8_t controllerTouchLatch = 0;
static int16_t controllerTouchX = 0, controllerTouchY = 0;
static uint16_t gamepadButtons = 0;
static int16_t gamepadAxes[2][2]{};
struct ReplayEvent {
    uint64_t frame, duration;
    uint16_t buttons = 0;
    bool hasCircle = false;
    int16_t circle[2]{};
};
static std::vector<ReplayEvent> replay;
static uint16_t replayButtons = 0;
static bool replayHasCircle = false;
static int16_t replayCircle[2]{};
static uint64_t replayFrames = 0;
static std::string stateDir;
static std::string corePath;
static std::string failure;
static std::map<std::string, std::string> options;
static retro_frame_time_callback frameTime{};
static retro_game_geometry geometry{};
static std::vector<uint8_t> pixels;
static unsigned videoWidth = 0, videoHeight = 0;
static uint64_t videoFrames = 0, nonblackFrames = 0, presentedFrames = 0;
static double presentationSeconds = 0;
static std::atomic<uint64_t> audioFrames{0};
static AudioQueueRef audioQueue = nullptr;
static std::atomic<bool> audioAccepting{false};
static std::mutex audioMutex;
static std::deque<int16_t> audioSamples;
static NSWindow *window;
static CAMetalLayer *metalLayer;
static id<MTLDevice> metalDevice;
static id<MTLCommandQueue> metalQueue;
static id<MTLRenderPipelineState> pipeline;
static id<MTLTexture> inputTexture, scaledTexture, lowerTexture;
static bool lowerVisible = false, presentationTesting = false, compositePassed = true;
static unsigned displayWidth = 400, displayHeight = 240;
static id<MTLFXSpatialScaler> scaler;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
static id<MTLFXSpatialScalerBase> scalerProperties;
static id<MTL4FXSpatialScaler> scaler4 API_AVAILABLE(macos(26.0));
static id<MTL4Compiler> compiler4 API_AVAILABLE(macos(26.0));
static id<MTL4CommandQueue> queue4 API_AVAILABLE(macos(26.0));
static id<MTL4CommandAllocator> allocator4 API_AVAILABLE(macos(26.0));
static id<MTL4CommandBuffer> buffer4 API_AVAILABLE(macos(26.0));
static id<MTLResidencySet> residency4 API_AVAILABLE(macos(26.0));
#else
static id<MTLFXSpatialScaler> scalerProperties;
#endif
static bool metal4Ready = false, useMetal4Scaler = false, metal4Enabled = true;
static uint64_t metal4Submissions = 0;
static bool fxEnabled = true, fxUsed = false;
static NSUInteger cachedOutputWidth = 0, cachedOutputHeight = 0;
static bool manuallyPaused = false, localSettingsOpen = false;
static double audioVolume = 1.0;
static bool audioMuted = false;
static void clearNativeInput();
static void present();

static bool runtimePaused() { return manuallyPaused || localSettingsOpen || ControllerConfig::settingsOpen(); }

static void invalidateScaler() {
    cachedOutputWidth = cachedOutputHeight = 0;
}

static void applyAudioLevel() {
    if (audioQueue) AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, audioMuted ? 0.f : float(audioVolume));
}

static void setAudioPaused(bool paused) {
    clearNativeInput();
    if (!audioQueue) return;
    audioAccepting = !paused;
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        audioSamples.clear();
    }
    if (paused) AudioQueuePause(audioQueue);
    else { AudioQueueReset(audioQueue); AudioQueueStart(audioQueue, nullptr); applyAudioLevel(); }
}

static void settingsChanged(bool open) {
    localSettingsOpen = open;
    setAudioPaused(runtimePaused());
}

@interface MH4URuntimeMenuTarget : NSObject
@property(nonatomic, strong) NSMenuItem *pauseItem;
- (void)togglePause:(id)sender;
- (void)showGraphics:(id)sender;
- (void)showAudio:(id)sender;
- (void)spatialChanged:(NSButton *)sender;
- (void)volumeChanged:(NSSlider *)sender;
- (void)muteChanged:(NSButton *)sender;
@end

static MH4URuntimeMenuTarget *runtimeMenuTarget;

@implementation MH4URuntimeMenuTarget
- (void)togglePause:(id)sender {
    (void)sender;
    manuallyPaused = !manuallyPaused;
    self.pauseItem.title = manuallyPaused ? @"Resume Game" : @"Pause Game";
    setAudioPaused(runtimePaused());
}
- (void)spatialChanged:(NSButton *)sender {
    fxEnabled = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:fxEnabled forKey:@"MetalFXSpatialEnabled"];
    invalidateScaler();
    if (!pixels.empty() && window) present();
}
- (void)showGraphics:(id)sender {
    (void)sender;
    settingsChanged(true);
    @try {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Graphics Settings";
        alert.informativeText = @"Changes to spatial upscaling are applied immediately.";
        [alert addButtonWithTitle:@"Done"];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 126)];
        NSButton *spatial = [NSButton checkboxWithTitle:@"MetalFX spatial upscaling" target:self action:@selector(spatialChanged:)];
        spatial.frame = NSMakeRect(0, 96, 430, 24); spatial.state = fxEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSButton *temporal = [NSButton checkboxWithTitle:@"MetalFX temporal upscaling" target:nil action:nil];
        temporal.frame = NSMakeRect(0, 62, 430, 24); temporal.enabled = NO;
        NSTextField *temporalReason = [NSTextField labelWithString:@"Unavailable: the core does not provide motion vectors or depth."];
        temporalReason.frame = NSMakeRect(22, 44, 408, 18); temporalReason.textColor = NSColor.secondaryLabelColor;
        NSButton *frameGeneration = [NSButton checkboxWithTitle:@"Frame generation" target:nil action:nil];
        frameGeneration.frame = NSMakeRect(0, 18, 430, 24); frameGeneration.enabled = NO;
        NSTextField *frameReason = [NSTextField labelWithString:@"Unavailable: this presenter receives completed frames only."];
        frameReason.frame = NSMakeRect(22, 0, 408, 18); frameReason.textColor = NSColor.secondaryLabelColor;
        for (NSView *item in @[spatial, temporal, temporalReason, frameGeneration, frameReason]) [view addSubview:item];
        alert.accessoryView = view;
        [alert runModal];
    } @finally {
        settingsChanged(false);
        [window makeKeyAndOrderFront:nil];
    }
}
- (void)volumeChanged:(NSSlider *)sender {
    audioVolume = sender.doubleValue / 100.0;
    [NSUserDefaults.standardUserDefaults setDouble:audioVolume forKey:@"AudioVolume"];
    applyAudioLevel();
}
- (void)muteChanged:(NSButton *)sender {
    audioMuted = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:audioMuted forKey:@"AudioMuted"];
    applyAudioLevel();
}
- (void)showAudio:(id)sender {
    (void)sender;
    settingsChanged(true);
    @try {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Audio Settings";
        alert.informativeText = @"Volume and mute are saved for future sessions.";
        [alert addButtonWithTitle:@"Done"];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 62)];
        NSTextField *label = [NSTextField labelWithString:@"Volume"];
        label.frame = NSMakeRect(0, 36, 58, 20);
        NSSlider *slider = [NSSlider sliderWithValue:audioVolume * 100.0 minValue:0 maxValue:100 target:self action:@selector(volumeChanged:)];
        slider.frame = NSMakeRect(62, 32, 298, 24); slider.continuous = YES;
        NSButton *mute = [NSButton checkboxWithTitle:@"Mute audio" target:self action:@selector(muteChanged:)];
        mute.frame = NSMakeRect(0, 0, 360, 24); mute.state = audioMuted ? NSControlStateValueOn : NSControlStateValueOff;
        for (NSView *item in @[label, slider, mute]) [view addSubview:item];
        alert.accessoryView = view;
        [alert runModal];
    } @finally {
        settingsChanged(false);
        [window makeKeyAndOrderFront:nil];
    }
}
@end

static void stopAudio() {
    audioAccepting = false;
    if (audioQueue) { AudioQueueDispose(audioQueue, true); audioQueue = nullptr; }
}

static void logMessage(enum retro_log_level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

static bool environment(unsigned command, void *data) {
    switch (command) {
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
        *static_cast<const char **>(data) = stateDir.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH:
        *static_cast<const char **>(data) = corePath.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        static_cast<retro_log_callback *>(data)->log = logMessage; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
        *static_cast<bool *>(data) = true; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
        *static_cast<unsigned *>(data) = RETRO_LANGUAGE_ENGLISH; return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        *static_cast<unsigned *>(data) = 2; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2: {
        auto *definitions = static_cast<retro_core_options_v2 *>(data)->definitions;
        for (auto *d = definitions; d && d->key; ++d)
            options.try_emplace(d->key, d->default_value ? d->default_value : d->values[0].value);
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *variable = static_cast<retro_variable *>(data);
        auto it = options.find(variable->key);
        variable->value = it == options.end() ? nullptr : it->second.c_str();
        return variable->value != nullptr;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *static_cast<bool *>(data) = false; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        return *static_cast<retro_pixel_format *>(data) == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        *static_cast<retro_hw_context_type *>(data) = useVulkan ? RETRO_HW_CONTEXT_VULKAN : RETRO_HW_CONTEXT_NONE; return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER:
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
    case RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT:
        return useVulkan && VulkanBridge::environment(command, data);
    case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK:
        frameTime = *static_cast<retro_frame_time_callback *>(data); return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        geometry = *static_cast<retro_game_geometry *>(data); return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        geometry = static_cast<retro_system_av_info *>(data)->geometry; return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE:
        fprintf(stderr, "Core: %s\n", static_cast<retro_message *>(data)->msg); return true;
    case RETRO_ENVIRONMENT_SHUTDOWN:
        stopped = 1; return true;
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: return true;
    default: return false;
    }
}

static NSRect imageRect(NSSize size) {
    double aspect = double(displayWidth) / displayHeight;
    double width = std::min(double(size.width), double(size.height) * aspect);
    double height = width / aspect;
    return NSMakeRect((size.width - width) / 2, (size.height - height) / 2, width, height);
}

static NSRect lowerScreenRect(NSSize size) {
    double width = std::min(double(size.width) * 0.36, double(size.height) * 0.48 * 4.0 / 3.0);
    double margin = std::min(16.0, double(size.width) * 0.02);
    return NSMakeRect(size.width - width - margin, margin, width, width * 0.75);
}

static void toggleLowerScreen() {
    lowerVisible = !lowerVisible;
    controllerTouchPressed = false;
    controllerTouchLatch = 0;
    pointerPressed = false;
    pointerLatchFrames = 0;
    ControllerConfig::setLowerScreenVisible(lowerVisible);
}

static void setFullscreen(bool enabled) {
    if (bool(window.styleMask & NSWindowStyleMaskFullScreen) != enabled)
        [window toggleFullScreen:nil];
}

static void setKeyState(unsigned code, bool pressed) {
    if (code >= 128) return;
    keys[code] = pressed;
    if (pressed) keyLatchFrames[code] = 2;
}

static bool keyPressed(unsigned code) { return keys[code] || keyLatchFrames[code] != 0; }

static void setPointerState(bool pressed, int16_t x, int16_t y) {
    pointerPressed = pressed;
    pointerX = x; pointerY = y;
    if (pressed) {
        pointerLatchFrames = 2;
        pointerLatchX = x; pointerLatchY = y;
    }
}

static void updateLowerPointer(NSPoint p, NSSize size, bool pressed) {
    NSRect r = lowerScreenRect(size);
    bool inside = lowerVisible && r.size.width > 0 && r.size.height > 0 && NSPointInRect(p, r);
    if (inside) {
        // The core still receives the original 400x480 canvas: lower LCD is x=40..359, y=240..479.
        double x = 40.0 + (p.x - r.origin.x) / r.size.width * 320.0;
        double y = 240.0 + (1.0 - (p.y - r.origin.y) / r.size.height) * 240.0;
        int16_t px = std::clamp(x / 400.0 * 65534.0 - 32767.0, -32767.0, 32767.0);
        int16_t py = std::clamp(y / 480.0 * 65534.0 - 32767.0, -32767.0, 32767.0);
        setPointerState(pressed, px, py);
    } else {
        setPointerState(false, pointerX, pointerY);
        pointerLatchFrames = 0;
    }
}

static void updateControllerPointer(bool available, bool pressed, float x, float y) {
    controllerCursorAvailable = available && std::isfinite(x) && std::isfinite(y);
    if (!controllerCursorAvailable || !lowerVisible) {
        controllerTouchPressed = false;
        controllerTouchLatch = 0;
        return;
    }
    controllerCursorX = std::clamp(x, 0.f, 1.f);
    controllerCursorY = std::clamp(y, 0.f, 1.f);
    controllerTouchPressed = pressed;
    if (pressed || !controllerTouchLatch) {
        // Clamp to the centers of the outermost LCD pixels, including at touchpad extremes.
        double guestX = 40.0 + std::clamp(double(controllerCursorX) * 320.0, .5, 319.5);
        double guestY = 240.0 + std::clamp(double(controllerCursorY) * 240.0, .5, 239.5);
        controllerTouchX = guestX / 400.0 * 65534.0 - 32767.0;
        controllerTouchY = guestY / 480.0 * 65534.0 - 32767.0;
    }
    if (pressed) controllerTouchLatch = 2;
}

static void clearNativeInput() {
    controllerTouchPressed = false;
    controllerTouchLatch = 0;
    controllerCursorAvailable = false;
    std::fill(std::begin(keys), std::end(keys), false);
    std::fill(std::begin(keyLatchFrames), std::end(keyLatchFrames), 0);
    pointerPressed = false;
    pointerLatchFrames = 0;
}

static void finishInputFrame() {
    if (controllerTouchLatch) --controllerTouchLatch;
    for (auto &frames : keyLatchFrames) if (frames) --frames;
    if (pointerLatchFrames) --pointerLatchFrames;
}

@interface GameView : NSView <NSWindowDelegate>
@end
@implementation GameView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) {
        if (window.styleMask & NSWindowStyleMaskFullScreen) setFullscreen(false);
        else stopped = 1;
    }
    else setKeyState(event.keyCode, true);
}
- (void)keyUp:(NSEvent *)event { setKeyState(event.keyCode, false); }
- (void)windowDidResignKey:(NSNotification *)note {
    (void)note;
    clearNativeInput();
}
- (void)windowDidEnterFullScreen:(NSNotification *)note {
    (void)note; if (!presentationTesting) ControllerConfig::setFullscreenPreferred(true);
}
- (void)windowDidExitFullScreen:(NSNotification *)note {
    (void)note; if (!presentationTesting) ControllerConfig::setFullscreenPreferred(false);
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; stopped = 1; return YES; }
- (void)quit:(id)sender { (void)sender; stopped = 1; }
- (void)updatePointer:(NSEvent *)event pressed:(BOOL)pressed {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    updateLowerPointer(p, self.bounds.size, pressed);
}
- (void)mouseDown:(NSEvent *)event { [self updatePointer:event pressed:YES]; }
- (void)mouseDragged:(NSEvent *)event { [self updatePointer:event pressed:YES]; }
- (void)mouseUp:(NSEvent *)event { [self updatePointer:event pressed:NO]; }
@end

static void pollInput() {
    if (headless) return;
    gamepadButtons = 0;
    std::memset(gamepadAxes, 0, sizeof(gamepadAxes));
    ControllerConfig::poll(gamepadButtons, gamepadAxes, window.isKeyWindow && NSApp.isActive);
    const auto cursor = ControllerConfig::touchCursor();
    updateControllerPointer(cursor.available, cursor.pressed, cursor.x, cursor.y);
}

static int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    if (device == RETRO_DEVICE_JOYPAD) {
        // Physical positions: J/K/U/I = B/A/Y/X; Q/E = L/R; 1/3 = ZL/ZR.
        const unsigned keycodes[16] = {38, 32, 48, 36, 126, 125, 123, 124, 40, 34, 12, 14, 18, 20, 4, 49};
        uint16_t buttons = gamepadButtons | replayButtons;
        for (unsigned n = 0; n < 16; ++n) if (keyPressed(keycodes[n])) buttons |= 1u << n;
        return id == RETRO_DEVICE_ID_JOYPAD_MASK ? static_cast<int16_t>(buttons) : id < 16 && (buttons & (1u << id)) ? 1 : 0;
    }
    if (device == RETRO_DEVICE_ANALOG && index < 2 && id < 2) {
        if (index == 0) {
            if (replayHasCircle) return replayCircle[id];
            int keyAxis = id == 0 ? int(keyPressed(2)) - int(keyPressed(0)) : int(keyPressed(1)) - int(keyPressed(13));
            if (keyAxis) return keyAxis * 32767;
        }
        return gamepadAxes[index][id];
    }
    if (device == RETRO_DEVICE_POINTER && index == 0) {
        if (controllerTouchPressed || controllerTouchLatch) {
            if (id == RETRO_DEVICE_ID_POINTER_X) return controllerTouchX;
            if (id == RETRO_DEVICE_ID_POINTER_Y) return controllerTouchY;
            if (id == RETRO_DEVICE_ID_POINTER_PRESSED || id == RETRO_DEVICE_ID_POINTER_COUNT) return 1;
        }
        bool latched = !pointerPressed && pointerLatchFrames != 0;
        if (id == RETRO_DEVICE_ID_POINTER_X) return latched ? pointerLatchX : pointerX;
        if (id == RETRO_DEVICE_ID_POINTER_Y) return latched ? pointerLatchY : pointerY;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return pointerPressed || latched;
        if (id == RETRO_DEVICE_ID_POINTER_COUNT) return pointerPressed || latched ? 1 : 0;
    }
    return 0;
}

static int inputSelfTest() {
    auto require = [](bool condition, const char *message) {
        if (!condition) throw std::runtime_error(std::string("Input self-test failed: ") + message);
    };
    auto a = [] { return inputState(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A); };
    auto touch = [](unsigned id) { return inputState(0, RETRO_DEVICE_POINTER, 0, id); };
    clearNativeInput();
    setKeyState(40, true); setKeyState(40, false); // Both events arrive before one guest frame.
    require(a() == 1, "quick A press was lost");
    finishInputFrame(); require(a() == 1, "quick A press did not last two frames");
    finishInputFrame(); require(a() == 0, "quick A press remained stuck");
    setKeyState(40, true);
    for (int i = 0; i < 5; ++i) finishInputFrame();
    require(a() == 1, "held A released when its latch expired");
    setKeyState(40, false); require(a() == 0, "held A did not release");
    setKeyState(13, true); setKeyState(13, false);
    require(inputState(0, RETRO_DEVICE_ANALOG, 0, RETRO_DEVICE_ID_ANALOG_Y) == -32767, "quick analog key was lost");
    setPointerState(true, 1234, -4321); setPointerState(false, 9000, 10000);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 1 && touch(RETRO_DEVICE_ID_POINTER_COUNT) == 1, "quick click was lost");
    require(touch(RETRO_DEVICE_ID_POINTER_X) == 1234 && touch(RETRO_DEVICE_ID_POINTER_Y) == -4321, "released click lost press coordinates");
    finishInputFrame(); require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 1, "click did not last two frames");
    finishInputFrame(); require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "click remained stuck");
    setKeyState(40, true); setPointerState(true, 0, 0);
    clearNativeInput();
    require(a() == 0 && touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "focus loss did not clear input");
    NSSize bounds = NSMakeSize(1000, 600);
    NSRect lower = lowerScreenRect(bounds);
    lowerVisible = true;
    updateLowerPointer(NSMakePoint(NSMidX(lower), NSMidY(lower)), bounds, true);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 1 && std::abs(touch(RETRO_DEVICE_ID_POINTER_X)) <= 1 &&
        std::abs(touch(RETRO_DEVICE_ID_POINTER_Y) - 16383) <= 1, "overlay center mapped to wrong guest screen");
    updateLowerPointer(NSMakePoint(10, 590), bounds, true);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "top screen or letterbox accepted touch");
    lowerVisible = false;
    updateLowerPointer(NSMakePoint(NSMidX(lower), NSMidY(lower)), bounds, true);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "hidden lower screen accepted touch");
    require(std::abs(imageRect(bounds).size.width / imageRect(bounds).size.height - 5.0 / 3.0) < 0.001,
        "top LCD aspect ratio changed");
    lowerVisible = true;
    updateControllerPointer(true, false, .25f, .75f);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "touchpad movement clicked without R3");
    updateControllerPointer(true, true, 1.f, 1.f);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 1 && controllerTouchX < 26213 && controllerTouchY < 32767,
        "R3 endpoint left the lower LCD");
    const int16_t clickedX = controllerTouchX;
    updateControllerPointer(true, false, 0.f, 0.f);
    require(touch(RETRO_DEVICE_ID_POINTER_X) == clickedX, "released R3 click moved before latch expired");
    finishInputFrame(); finishInputFrame();
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "R3 remained stuck after release");
    setPointerState(true, 1234, 2345);
    updateControllerPointer(true, false, .5f, .5f);
    require(touch(RETRO_DEVICE_ID_POINTER_X) == 1234, "idle touchpad overwrote mouse touch");
    updateControllerPointer(true, true, .5f, .5f);
    require(std::abs(touch(RETRO_DEVICE_ID_POINTER_X)) <= 1, "R3 cursor center mapping wrong");
    clearNativeInput();
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "focus loss retained R3 touch");
    updateControllerPointer(true, true, .5f, .5f);
    lowerVisible = false;
    updateControllerPointer(true, true, .5f, .5f);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "hidden overlay retained R3 touch");
    lowerVisible = true;
    updateControllerPointer(true, true, .5f, .5f);
    updateControllerPointer(false, false, .5f, .5f);
    require(touch(RETRO_DEVICE_ID_POINTER_PRESSED) == 0, "disconnect retained R3 touch");
    lowerVisible = false;
    require(ControllerConfig::selfTest() == 0, "controller mapping or toggle edge regression");
    puts("{\"mode\":\"input-self-test\",\"passed\":true,\"minimum_tap_frames\":2}");
    return 0;
}

static void audioOutput(void *, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    std::lock_guard<std::mutex> lock(audioMutex);
    auto *out = static_cast<int16_t *>(buffer->mAudioData);
    for (unsigned i = 0; i < buffer->mAudioDataBytesCapacity / sizeof(int16_t); ++i) {
        out[i] = audioSamples.empty() ? 0 : audioSamples.front();
        if (!audioSamples.empty()) audioSamples.pop_front();
    }
    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

static size_t audioBatch(const int16_t *data, size_t frames) {
    audioFrames += frames;
    if (audioAccepting) {
        std::lock_guard<std::mutex> lock(audioMutex);
        size_t count = std::min(frames * 2, size_t(65536) - audioSamples.size());
        audioSamples.insert(audioSamples.end(), data, data + count);
    }
    return frames;
}
static void audioSample(int16_t l, int16_t r) { int16_t sample[] = {l, r}; audioBatch(sample, 1); }

static void startAudio(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) throw std::runtime_error("Invalid core audio sample rate");
    AudioStreamBasicDescription format{};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = format.mBytesPerFrame = 4;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    OSStatus status = AudioQueueNewOutput(&format, audioOutput, nullptr, nullptr, nullptr, 0, &audioQueue);
    if (status) throw std::runtime_error("AudioQueueNewOutput failed: " + std::to_string(status));
    for (int i = 0; i < 3; ++i) {
        AudioQueueBufferRef buffer;
        status = AudioQueueAllocateBuffer(audioQueue, 2048, &buffer);
        if (status) throw std::runtime_error("AudioQueueAllocateBuffer failed");
        audioOutput(nullptr, audioQueue, buffer);
    }
    if (AudioQueueStart(audioQueue, nullptr)) throw std::runtime_error("AudioQueueStart failed");
    audioAccepting = true;
    applyAudioLevel();
}

static void setupWindow() {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"MetalFXSpatialEnabled"]) fxEnabled = [defaults boolForKey:@"MetalFXSpatialEnabled"];
    if ([defaults objectForKey:@"AudioVolume"]) audioVolume = std::clamp([defaults doubleForKey:@"AudioVolume"], 0.0, 1.0);
    audioMuted = [defaults boolForKey:@"AudioMuted"];
    fprintf(stderr, "Application identity: bundle=%s running=%s pid=%d\n",
        NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "(unbundled)",
        NSRunningApplication.currentApplication.bundleIdentifier.UTF8String ?: "(unbundled)",
        NSRunningApplication.currentApplication.processIdentifier);
    metalDevice = MTLCreateSystemDefaultDevice();
    if (!metalDevice) throw std::runtime_error("No Metal GPU is available");
    metalQueue = [metalDevice newCommandQueue];
    NSError *error = nil;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        if (fxEnabled && metal4Enabled && [metalDevice supportsFamily:MTLGPUFamilyMetal4] && [MTLFXSpatialScalerDescriptor supportsMetal4FX:metalDevice]) {
            compiler4 = [metalDevice newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
            queue4 = [metalDevice newMTL4CommandQueue];
            allocator4 = [metalDevice newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&error];
            buffer4 = [metalDevice newCommandBuffer];
            residency4 = [metalDevice newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
            metal4Ready = compiler4 && queue4 && allocator4 && buffer4 && residency4;
            if (!metal4Ready) fprintf(stderr, "Metal 4 setup unavailable; using legacy MetalFX: %s\n", error ? error.localizedDescription.UTF8String : "object creation failed");
        }
    }
#endif
    id<MTLLibrary> library = [metalDevice newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "struct V { float4 p [[position]]; float2 uv; };\n"
         "vertex V vert(uint i [[vertex_id]]) { float2 p=float2((i<<1)&2,i&2); return {float4(p*2-1,0,1),float2(p.x,1-p.y)}; }\n"
         "fragment float4 frag(V v [[stage_in]],texture2d<float> t [[texture(0)]],constant float4 &cursor [[buffer(0)]]) {"
         " constexpr sampler s(filter::linear); float4 color=float4(t.sample(s,v.uv).rgb,1);"
         " if(cursor.z>0) { float d=length((v.uv-cursor.xy)/cursor.zw);"
         " if(d<1.5 || (d>=4 && d<=6)) return float4(1);"
         " if(d<=7) return float4(0,0,0,1); } return color; }"
        options:nil error:&error];
    if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vert"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"frag"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipeline = [metalDevice newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline || !metalQueue) throw std::runtime_error("Metal presentation setup failed");
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"MH4U Runtime";
    window.releasedWhenClosed = NO;
    GameView *view = [[GameView alloc] initWithFrame:window.contentView.bounds];
    view.wantsLayer = YES;
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = metalDevice;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = !presentationTesting;
    view.layer = metalLayer;
    window.contentView = view;
    window.delegate = view;
    NSMenu *menu = [NSMenu new];
    NSMenuItem *applicationItem = [NSMenuItem new];
    [menu addItem:applicationItem];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"MH4U Runtime"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit MH4U Runtime" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = view;
    [applicationMenu addItem:quit];
    applicationItem.submenu = applicationMenu;
    if (!presentationTesting) {
        ControllerConfig::installMenu(menu, window, toggleLowerScreen, setFullscreen, settingsChanged);
        runtimeMenuTarget = [MH4URuntimeMenuTarget new];
        NSMenuItem *gameRoot = [[NSMenuItem alloc] initWithTitle:@"Game" action:nil keyEquivalent:@""];
        NSMenu *gameMenu = [[NSMenu alloc] initWithTitle:@"Game"];
        NSMenuItem *pause = [[NSMenuItem alloc] initWithTitle:@"Pause Game" action:@selector(togglePause:) keyEquivalent:@"p"];
        pause.target = runtimeMenuTarget; runtimeMenuTarget.pauseItem = pause;
        [gameMenu addItem:pause]; gameRoot.submenu = gameMenu; [menu addItem:gameRoot];
        NSMenu *settings = [menu itemWithTitle:@"Settings"].submenu;
        [settings insertItem:[NSMenuItem separatorItem] atIndex:0];
        NSMenuItem *audio = [[NSMenuItem alloc] initWithTitle:@"Audio…" action:@selector(showAudio:) keyEquivalent:@""];
        audio.target = runtimeMenuTarget; [settings insertItem:audio atIndex:0];
        NSMenuItem *graphics = [[NSMenuItem alloc] initWithTitle:@"Graphics…" action:@selector(showGraphics:) keyEquivalent:@""];
        graphics.target = runtimeMenuTarget; [settings insertItem:graphics atIndex:0];
    }
    NSApp.mainMenu = menu;
    [window makeFirstResponder:view];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    if (!presentationTesting) {
        lowerVisible = ControllerConfig::lowerScreenVisible();
        if (ControllerConfig::fullscreenPreferred()) setFullscreen(true);
    }
    fprintf(stderr, "Metal presenter: %s. WASD move; arrows D-pad; J/K/U/I B/A/Y/X; Q/E L/R; Enter Start; Tab Select; click lower screen; Esc quits.\n", metalDevice.name.UTF8String);
}

static void present() {
    displayWidth = videoWidth;
    displayHeight = videoHeight / 2;
    if (!displayWidth || !displayHeight) return;
    NSSize size = [window.contentView convertSizeToBacking:window.contentView.bounds.size];
    if (size.width < 1 || size.height < 1) return;
    metalLayer.drawableSize = size;
    NSRect r = imageRect(size);
    NSUInteger outputWidth = std::max(1.0, std::round(r.size.width));
    NSUInteger outputHeight = std::max(1.0, std::round(r.size.height));
    if (!inputTexture || inputTexture.width != displayWidth || inputTexture.height != displayHeight ||
        cachedOutputWidth != outputWidth || cachedOutputHeight != outputHeight) {
        cachedOutputWidth = outputWidth;
        cachedOutputHeight = outputHeight;
        scaler = nil;
        scalerProperties = nil;
        useMetal4Scaler = false;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) scaler4 = nil;
#endif
        scaledTexture = nil;
        if (fxEnabled && outputWidth > displayWidth && outputHeight > displayHeight && [MTLFXSpatialScalerDescriptor supportsDevice:metalDevice]) {
            MTLFXSpatialScalerDescriptor *fx = [MTLFXSpatialScalerDescriptor new];
            fx.inputWidth = displayWidth; fx.inputHeight = displayHeight;
            fx.outputWidth = outputWidth; fx.outputHeight = outputHeight;
            fx.colorTextureFormat = fx.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
            fx.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
            if (@available(macOS 26.0, *)) {
                if (metal4Ready) {
                    scaler4 = [fx newSpatialScalerWithDevice:metalDevice compiler:compiler4];
                    scalerProperties = scaler4;
                    useMetal4Scaler = scaler4 != nil;
                }
            }
#endif
            if (!scalerProperties) {
                scaler = [fx newSpatialScalerWithDevice:metalDevice];
                scalerProperties = scaler;
            }
            if (scalerProperties) {
                MTLTextureDescriptor *out = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:outputWidth height:outputHeight mipmapped:NO];
                out.storageMode = MTLStorageModePrivate;
                out.usage = scalerProperties.outputTextureUsage | MTLTextureUsageShaderRead;
                scaledTexture = [metalDevice newTextureWithDescriptor:out];
                if (!scaledTexture) { scalerProperties = nil; useMetal4Scaler = false; }
            }
        }
        MTLTextureDescriptor *in = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:displayWidth height:displayHeight mipmapped:NO];
        in.storageMode = MTLStorageModeShared;
        in.usage = MTLTextureUsageShaderRead | (scalerProperties ? scalerProperties.colorTextureUsage : 0);
        inputTexture = [metalDevice newTextureWithDescriptor:in];
        if (!inputTexture) { failure = "Metal input texture allocation failed"; stopped = 1; return; }
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) {
            if (useMetal4Scaler) {
                [residency4 removeAllAllocations];
                [residency4 addAllocation:inputTexture];
                [residency4 addAllocation:scaledTexture];
                [residency4 commit];
            }
        }
#endif
    }
    [inputTexture replaceRegion:MTLRegionMake2D(0, 0, displayWidth, displayHeight) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:displayWidth * 4];
    unsigned lowerWidth = displayWidth * 4 / 5;
    if (!lowerTexture || lowerTexture.width != lowerWidth || lowerTexture.height != displayHeight) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:lowerWidth height:displayHeight mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead;
        lowerTexture = [metalDevice newTextureWithDescriptor:desc];
        if (!lowerTexture) { failure = "Metal lower screen allocation failed"; stopped = 1; return; }
    }
    if (lowerVisible || presentationTesting)
        [lowerTexture replaceRegion:MTLRegionMake2D(0, 0, lowerWidth, displayHeight) mipmapLevel:0
            withBytes:pixels.data() + (displayHeight * displayWidth + displayWidth / 10) * 4 bytesPerRow:displayWidth * 4];
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable) return;
    id<MTLCommandBuffer> command = [metalQueue commandBuffer];
    if (scalerProperties) {
        scalerProperties.colorTexture = inputTexture;
        scalerProperties.outputTexture = scaledTexture;
        scalerProperties.inputContentWidth = displayWidth; scalerProperties.inputContentHeight = displayHeight;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) {
            if (useMetal4Scaler) {
                [allocator4 reset];
                [buffer4 beginCommandBufferWithAllocator:allocator4];
                [buffer4 useResidencySet:residency4];
                [scaler4 encodeToCommandBuffer:buffer4];
                [buffer4 endCommandBuffer];
                dispatch_semaphore_t completed = dispatch_semaphore_create(0);
                __block NSError *submissionError = nil;
                MTL4CommitOptions *commitOptions = [MTL4CommitOptions new];
                [commitOptions addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
                    submissionError = feedback.error;
                    dispatch_semaphore_signal(completed);
                }];
                id<MTL4CommandBuffer> buffers[] = {buffer4};
                [queue4 commit:buffers count:1 options:commitOptions];
                // Complete the Metal 4 upscale before the legacy presentation queue reads it.
                if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
                    failure = "Metal 4 upscale timed out"; stopped = 1; return;
                }
                if (submissionError) {
                    failure = submissionError.localizedDescription.UTF8String; stopped = 1; return;
                }
                ++metal4Submissions;
            } else [scaler encodeToCommandBuffer:command];
        } else [scaler encodeToCommandBuffer:command];
#else
        [scaler encodeToCommandBuffer:command];
#endif
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setViewport:MTLViewport{r.origin.x, r.origin.y, r.size.width, r.size.height, 0, 1}];
    const float noCursor[4] = {};
    [encoder setFragmentBytes:noCursor length:sizeof(noCursor) atIndex:0];
    [encoder setFragmentTexture:scalerProperties ? scaledTexture : inputTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (lowerVisible) {
        NSRect lower = [window.contentView convertRectToBacking:lowerScreenRect(window.contentView.bounds.size)];
        [encoder setViewport:MTLViewport{lower.origin.x, size.height - NSMaxY(lower), lower.size.width, lower.size.height, 0, 1}];
        if (controllerCursorAvailable) {
            NSRect points = lowerScreenRect(window.contentView.bounds.size);
            const float cursor[4] = {controllerCursorX, controllerCursorY, float(1.0 / points.size.width), float(1.0 / points.size.height)};
            [encoder setFragmentBytes:cursor length:sizeof(cursor) atIndex:0];
        }
        [encoder setFragmentTexture:lowerTexture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    id<MTLBuffer> compositeReadback = nil;
    if (presentationTesting) {
        compositeReadback = [metalDevice newBufferWithLength:1536 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> read = [command blitCommandEncoder];
        NSRect lower = [window.contentView convertRectToBacking:lowerScreenRect(window.contentView.bounds.size)];
        if (lowerVisible) {
            NSPoint click = [window.contentView convertPointFromBacking:NSMakePoint(NSMidX(lower), NSMidY(lower))];
            updateLowerPointer(click, window.contentView.bounds.size, true);
            compositePassed &= pointerPressed && std::abs(pointerX) <= 1 && std::abs(pointerY - 16383) <= 1;
            click = [window.contentView convertPointFromBacking:NSMakePoint(NSMaxX(lower) - 1, NSMidY(lower))];
            updateLowerPointer(click, window.contentView.bounds.size, true);
            compositePassed &= pointerPressed && pointerX > 25000;
            clearNativeInput();
        }
        for (unsigned i = 0; i < (lowerVisible ? 4u : 2u); ++i) {
            NSRect sample = i < 2 ? r : lower;
            NSUInteger x = sample.origin.x + sample.size.width * (i % 2 ? 0.75 : 0.25);
            NSUInteger y = size.height - (sample.origin.y + sample.size.height * (i < 2 ? 0.75 : 0.5));
            [read copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0)
                sourceSize:MTLSizeMake(1, 1, 1) toBuffer:compositeReadback destinationOffset:i * 256
                destinationBytesPerRow:256 destinationBytesPerImage:256];
        }
        if (lowerVisible) {
            double scale = lower.size.width / lowerScreenRect(window.contentView.bounds.size).size.width;
            for (unsigned i = 0; i < 2; ++i) {
                NSUInteger x = NSMidX(lower) + i * 3.0 * scale;
                NSUInteger y = size.height - NSMidY(lower);
                [read copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0)
                    sourceSize:MTLSizeMake(1, 1, 1) toBuffer:compositeReadback destinationOffset:(4 + i) * 256
                    destinationBytesPerRow:256 destinationBytesPerImage:256];
            }
        }
        [read endEncoding];
    }
    [command presentDrawable:drawable];
    [command commit];
    // ponytail: one in-flight frame avoids shared-texture overwrite; pipeline when profiling warrants it.
    [command waitUntilCompleted];
    if (compositeReadback && command.status == MTLCommandBufferStatusCompleted) {
        const uint8_t expected[4][3] = {{0,0,255}, {0,255,0}, {255,0,0}, {255,255,255}};
        for (unsigned i = 0; i < (lowerVisible ? 4u : 2u); ++i)
            for (unsigned c = 0; c < 3; ++c)
                compositePassed &= std::abs(int(static_cast<uint8_t *>(compositeReadback.contents)[i * 256 + c]) - expected[i][c]) <= 16;
    }
    if (compositeReadback && lowerVisible && command.status == MTLCommandBufferStatusCompleted) {
        for (unsigned i = 0; i < 2; ++i)
            for (unsigned c = 0; c < 3; ++c)
                compositePassed &= std::abs(int(static_cast<uint8_t *>(compositeReadback.contents)[(4 + i) * 256 + c]) - (i ? 0 : 255)) <= 16;
    }
    if (command.status != MTLCommandBufferStatusCompleted) {
        failure = command.error ? command.error.localizedDescription.UTF8String : "Metal submission failed";
        stopped = 1;
    } else {
        ++presentedFrames;
        fxUsed = fxUsed || scalerProperties != nil;
    }
}

static void softwareVideo(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return; // libretro duplicate frame; preserve the last genuine frame.
    if (data == RETRO_HW_FRAME_BUFFER_VALID || width == 0 || height == 0 || width > 8192 || height > 8192 || pitch < size_t(width) * 4) {
        failure = "Core submitted an unsupported or invalid software frame"; stopped = 1; return;
    }
    videoWidth = width; videoHeight = height;
    pixels.resize(size_t(width) * height * 4);
    bool nonblack = false;
    for (unsigned y = 0; y < height; ++y) {
        auto *dst = pixels.data() + size_t(y) * width * 4;
        std::memcpy(dst, static_cast<const uint8_t *>(data) + y * pitch, size_t(width) * 4);
        for (unsigned x = 0; x < width; ++x) {
            nonblack = nonblack || dst[4*x] || dst[4*x+1] || dst[4*x+2];
            dst[4*x+3] = 255;
        }
    }
    ++videoFrames;
    nonblackFrames += nonblack;
    if (!headless) {
        auto started = std::chrono::steady_clock::now();
        present();
        presentationSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    }
}

static void video(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!useVulkan) { softwareVideo(data, width, height, pitch); return; }
    try { VulkanBridge::video(data, width, height, softwareVideo); }
    catch (const std::exception &error) { failure = error.what(); stopped = 1; }
}

struct Core {
    void *handle = nullptr;
    bool initialized = false, loaded = false;
#define CORE_FN(name) decltype(&retro_##name) name = nullptr
    CORE_FN(api_version); CORE_FN(set_environment); CORE_FN(set_video_refresh);
    CORE_FN(set_audio_sample); CORE_FN(set_audio_sample_batch); CORE_FN(set_input_poll);
    CORE_FN(set_input_state); CORE_FN(init); CORE_FN(deinit); CORE_FN(get_system_info);
    CORE_FN(get_system_av_info); CORE_FN(load_game); CORE_FN(unload_game); CORE_FN(run);
    CORE_FN(set_controller_port_device);
#undef CORE_FN
    explicit Core(const std::string &path) {
        handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) throw std::runtime_error(std::string("Cannot load core: ") + dlerror());
#define LOAD(name) name = reinterpret_cast<decltype(name)>(dlsym(handle, "retro_" #name)); if (!name) { dlclose(handle); handle = nullptr; throw std::runtime_error("Core missing retro_" #name); }
        LOAD(api_version); LOAD(set_environment); LOAD(set_video_refresh); LOAD(set_audio_sample);
        LOAD(set_audio_sample_batch); LOAD(set_input_poll); LOAD(set_input_state); LOAD(init);
        LOAD(deinit); LOAD(get_system_info); LOAD(get_system_av_info); LOAD(load_game);
        LOAD(unload_game); LOAD(run); LOAD(set_controller_port_device);
#undef LOAD
    }
    ~Core() {
        stopAudio();
        VulkanBridge::destroyCoreContext();
        if (loaded) unload_game();
        VulkanBridge::shutdown();
        if (initialized) deinit();
        if (handle) dlclose(handle);
    }
};

static void capture(const std::string &path) {
    if (pixels.empty()) throw std::runtime_error("Cannot capture: core submitted no video frame");
    std::ofstream out(path, std::ios::binary);
    out << "P6\n" << videoWidth << ' ' << videoHeight << "\n255\n";
    for (size_t i = 0; i < pixels.size(); i += 4) {
        const char rgb[] = {char(pixels[i+2]), char(pixels[i+1]), char(pixels[i])};
        out.write(rgb, 3);
    }
    out.close();
    if (!out) throw std::runtime_error("Cannot write capture: " + path);
}

static int presentationSelfTest(uint64_t frames, const std::string &capturePath) {
    if (headless) throw std::runtime_error("--self-test requires a display");
    presentationTesting = true;
    lowerVisible = true;
    setupWindow();
    const uint8_t colors[4][4] = {{0, 0, 255, 255}, {0, 255, 0, 255}, {255, 0, 0, 255}, {255, 255, 255, 255}};
    std::vector<uint8_t> pattern(400 * 480 * 4);
    for (unsigned y = 0; y < 480; ++y)
        for (unsigned x = 0; x < 400; ++x)
            std::memcpy(pattern.data() + (y * 400 + x) * 4, colors[(y >= 240) * 2 + (x >= 200)], 4);
    for (uint64_t i = 0; i < frames; ++i) {
        lowerVisible = i != 1; // Exercise the hidden overlay as well as both visible screens.
        // Exercise downscale fallback and return to upscaling after a resize.
        if (i == 1) [window setContentSize:NSMakeSize(120, 144)];
        if (i == 2) [window setContentSize:NSMakeSize(600, 720)];
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
        [NSApp updateWindows];
        updateControllerPointer(true, false, .5f, .5f);
        softwareVideo(pattern.data(), 400, 480, 1600);
        if (!failure.empty()) throw std::runtime_error(failure);
    }
    id<MTLTexture> output = scalerProperties ? scaledTexture : inputTexture;
    id<MTLBuffer> readback = [metalDevice newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [metalQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    for (unsigned i = 0; i < 4; ++i)
        [blit copyFromTexture:(i < 2 ? output : lowerTexture) sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake((i < 2 ? output.width : lowerTexture.width) * (1 + 2 * (i % 2)) / 4, (i < 2 ? output.height : lowerTexture.height) / 2, 0)
            sourceSize:MTLSizeMake(1, 1, 1) toBuffer:readback destinationOffset:i * 256
            destinationBytesPerRow:256 destinationBytesPerImage:256];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    bool passed = command.status == MTLCommandBufferStatusCompleted && presentedFrames == frames && compositePassed;
    for (unsigned i = 0; i < 4; ++i)
        for (unsigned c = 0; c < 3; ++c)
            passed = passed && std::abs(int(static_cast<uint8_t *>(readback.contents)[i * 256 + c]) - colors[i][c]) <= 16;
    if (!capturePath.empty()) capture(capturePath);
    printf("{\"mode\":\"presentation-self-test\",\"passed\":%s,\"presented_frames\":%llu,\"metal4_upscale_submissions\":%llu,\"metalfx_spatial_used\":%s,\"gpu_color_readback_passed\":%s}\n",
        passed ? "true" : "false", (unsigned long long)presentedFrames, (unsigned long long)metal4Submissions,
        fxUsed ? "true" : "false", passed ? "true" : "false");
    return passed ? 0 : 1;
}

static void validateGame(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    constexpr uint64_t expectedSize = 2727489536ULL;
    constexpr char expectedSHA256[] = "b60784a71f09135af012817cc4a7c06cd0723131ff590528174aee9057f035c2";
    file.seekg(0, std::ios::end);
    if (!file || file.tellg() != std::streampos(expectedSize))
        throw std::runtime_error("Game identity mismatch: expected the supplied 2727489536-byte main.cxi");
    file.seekg(0);
    uint8_t header[512]{};
    file.read(reinterpret_cast<char *>(header), sizeof(header));
    if (!file || std::memcmp(header + 0x100, "NCCH", 4) != 0)
        throw std::runtime_error("Expected the locally prepared MH4U main.cxi; run the workspace preparation command first");
    uint64_t title = 0;
    for (unsigned i = 0; i < 8; ++i) title |= uint64_t(header[0x118 + i]) << (8 * i);
    if (title != 0x0004000000126100ULL)
        throw std::runtime_error("This specialized runtime requires the supplied European MH4U title (0004000000126100)");
    constexpr char expectedProduct[16] = "CTR-P-BFGP";
    if (std::memcmp(header + 0x150, expectedProduct, sizeof(expectedProduct)) != 0)
        throw std::runtime_error("Game identity mismatch: expected product CTR-P-BFGP");
    if (!(header[0x18f] & 4))
        throw std::runtime_error("The supplied game partition is encrypted; this runtime does not obtain decryption keys");
    file.seekg(0);
    CC_SHA256_CTX context;
    if (!CC_SHA256_Init(&context)) throw std::runtime_error("Cannot initialize game SHA-256 validation");
    std::vector<char> chunk(1024 * 1024);
    uint64_t hashed = 0;
    while (file) {
        file.read(chunk.data(), chunk.size());
        auto count = file.gcount();
        if (count > 0 && !CC_SHA256_Update(&context, chunk.data(), static_cast<CC_LONG>(count)))
            throw std::runtime_error("Cannot compute game SHA-256");
        hashed += count;
    }
    if (!file.eof() || file.bad() || hashed != expectedSize)
        throw std::runtime_error("Game file changed or could not be read completely during validation");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!CC_SHA256_Final(digest, &context)) throw std::runtime_error("Cannot finish game SHA-256 validation");
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) std::snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (std::strcmp(hex, expectedSHA256) != 0)
        throw std::runtime_error("Game SHA-256 mismatch: only the locally prepared supplied image is accepted");
    fprintf(stderr, "Verified supplied MH4U main.cxi: size, title, product, plaintext flag, SHA-256.\n");
}

static void denyNetwork() {
    char *error = nullptr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = sandbox_init("(version 1)(allow default)(deny network*)", 0, &error);
    if (result != 0) {
        std::string message = error ? error : "unknown sandbox error";
        if (error) sandbox_free_error(error);
        throw std::runtime_error("Cannot enforce offline execution: " + message);
    }
#pragma clang diagnostic pop
}

static void loadReplay(const std::string &path) {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:@(path.c_str()) options:0 error:&error];
    if (!data) throw std::runtime_error("Cannot read input script: " + path);
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![document isKindOfClass:[NSArray class]] || [document count] > 10000)
        throw std::runtime_error("Input script must be a JSON array of at most 10000 events");
    const std::map<std::string, unsigned> buttons = {
        {"B", RETRO_DEVICE_ID_JOYPAD_B}, {"A", RETRO_DEVICE_ID_JOYPAD_A},
        {"X", RETRO_DEVICE_ID_JOYPAD_X}, {"Y", RETRO_DEVICE_ID_JOYPAD_Y},
        {"L", RETRO_DEVICE_ID_JOYPAD_L}, {"R", RETRO_DEVICE_ID_JOYPAD_R},
        {"ZL", RETRO_DEVICE_ID_JOYPAD_L2}, {"ZR", RETRO_DEVICE_ID_JOYPAD_R2},
        {"START", RETRO_DEVICE_ID_JOYPAD_START}, {"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT},
        {"UP", RETRO_DEVICE_ID_JOYPAD_UP}, {"DOWN", RETRO_DEVICE_ID_JOYPAD_DOWN},
        {"LEFT", RETRO_DEVICE_ID_JOYPAD_LEFT}, {"RIGHT", RETRO_DEVICE_ID_JOYPAD_RIGHT}
    };
    for (id item in document) {
        if (![item isKindOfClass:[NSDictionary class]]) throw std::runtime_error("Each input event must be a JSON object");
        auto integer = [&](NSString *key) -> uint64_t {
            id number = item[key];
            if (![number isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID())
                throw std::runtime_error(std::string("Input event requires integer ") + key.UTF8String);
            double value = [number doubleValue];
            if (!std::isfinite(value) || value < 0 || value > 1000000000 || std::floor(value) != value)
                throw std::runtime_error("Input event frame/duration must be integers in [0, 1000000000]");
            return uint64_t(value);
        };
        ReplayEvent event{integer(@"frame"), integer(@"duration")};
        if (!event.duration) throw std::runtime_error("Input event duration must be positive");
        id names = item[@"buttons"];
        if (names) {
            if (![names isKindOfClass:[NSArray class]]) throw std::runtime_error("Input event buttons must be an array");
            for (id name in names) {
                if (![name isKindOfClass:[NSString class]]) throw std::runtime_error("Input button names must be strings");
                auto it = buttons.find([name uppercaseString].UTF8String);
                if (it == buttons.end()) throw std::runtime_error(std::string("Unknown input button: ") + [name UTF8String]);
                event.buttons |= 1u << it->second;
            }
        }
        id circle = item[@"circle"];
        if (circle) {
            if (![circle isKindOfClass:[NSArray class]] || [circle count] != 2)
                throw std::runtime_error("Input event circle must be [x,y] in [-1,1] (positive y is down)");
            event.hasCircle = true;
            for (unsigned i = 0; i < 2; ++i) {
                id number = circle[i];
                if (![number isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID())
                    throw std::runtime_error("Input circle coordinates must be numbers");
                double value = [number doubleValue];
                if (!std::isfinite(value) || value < -1 || value > 1) throw std::runtime_error("Input circle coordinates must be in [-1,1]");
                event.circle[i] = std::lround(value * 32767);
            }
        }
        replay.push_back(event);
    }
}

static void applyReplay(uint64_t frame) {
    replayButtons = 0;
    replayHasCircle = false;
    bool active = false;
    for (const auto &event : replay) {
        if (frame >= event.frame && frame - event.frame < event.duration) {
            active = true;
            replayButtons |= event.buttons;
            if (event.hasCircle) {
                replayHasCircle = true;
                std::copy(std::begin(event.circle), std::end(event.circle), replayCircle);
            }
        }
    }
    replayFrames += active;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        bool showStartupAlert = false;
        try {
            NSString *workspace = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MH4UWorkspace"];
            showStartupAlert = argc == 1 && workspace.length;
            if (workspace.length) std::filesystem::current_path(workspace.fileSystemRepresentation);
            denyNetwork();
            std::string game = ".local/game/main.cxi", cpu = "jit", capturePath, inputScript, renderer = "vulkan";
            std::string vulkanLibrary = ".local/vulkan/libMoltenVK.dylib";
            corePath = ".local/core-vulkan-build/bin/Release/azahar_libretro.dylib";
            stateDir = ".local/state";
            uint64_t frameLimit = 0;
            bool audioEnabled = true, selfTest = false, testInput = false;
            for (int i = 1; i < argc; ++i) {
                std::string arg = argv[i];
                auto value = [&]() -> std::string { if (++i >= argc) throw std::runtime_error("Missing value for " + arg); return argv[i]; };
                if (arg == "--core") corePath = value();
                else if (arg == "--renderer") renderer = value();
                else if (arg == "--vulkan-library") vulkanLibrary = value();
                else if (arg == "--game") game = value();
                else if (arg == "--state-dir") stateDir = value();
                else if (arg == "--cpu") cpu = value();
                else if (arg == "--capture") capturePath = value();
                else if (arg == "--input-script") inputScript = value();
                else if (arg == "--frames") {
                    std::string n = value();
                    if (n.empty() || n.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("--frames requires a positive integer");
                    frameLimit = std::stoull(n);
                    if (!frameLimit) throw std::runtime_error("--frames must be greater than zero");
                }
                else if (arg == "--headless") headless = true;
                else if (arg == "--no-audio") audioEnabled = false;
                else if (arg == "--no-metalfx") fxEnabled = false;
                else if (arg == "--no-metal4") metal4Enabled = false;
                else if (arg == "--self-test") selfTest = true;
                else if (arg == "--input-self-test") testInput = true;
                else if (arg == "--help") {
                    puts("MH4U Runtime --core PATH --game PATH [--cpu jit|interpreter] [--renderer software|vulkan] [--vulkan-library PATH] [--state-dir DIR] [--headless --frames N] [--capture FRAME.ppm] [--input-script EVENTS.json] [--no-audio] [--no-metalfx] [--no-metal4]\nMH4U Runtime --self-test [--frames N] [--no-metal4] [--no-metalfx]\nMH4U Runtime --input-self-test");
                    return 0;
                } else throw std::runtime_error("Unknown option: " + arg);
            }
            if (cpu != "jit" && cpu != "interpreter") throw std::runtime_error("--cpu must be jit or interpreter");
            if (renderer != "software" && renderer != "vulkan") throw std::runtime_error("--renderer must be software or vulkan");
            useVulkan = renderer == "vulkan";
            if (testInput) return inputSelfTest();
            if (!inputScript.empty()) loadReplay(inputScript);
            if (selfTest) return presentationSelfTest(frameLimit ? frameLimit : 5, capturePath);
            if (headless && !frameLimit) throw std::runtime_error("--headless requires --frames N");
            if (!std::filesystem::is_regular_file(game)) throw std::runtime_error("Game file does not exist: " + game);
            validateGame(game);
            corePath = std::filesystem::absolute(corePath).string();
            game = std::filesystem::absolute(game).string();
            stateDir = std::filesystem::absolute(stateDir).string();
            std::filesystem::create_directories(stateDir);
            options = {
                {"citra_graphics_api", useVulkan ? "Vulkan" : "Software"}, {"citra_use_cpu_jit", cpu == "jit" ? "enabled" : "disabled"},
                {"citra_use_shader_jit", "enabled"}, {"citra_resolution_factor", "1"},
                {"citra_layout_option", "default"}, {"citra_is_new_3ds", "New 3DS"},
                {"citra_language_value", "English"}, {"citra_audio_emulation", "hle"},
                {"citra_input_type", "none"}, {"citra_enable_motion", "disabled"},
                {"citra_enable_mouse_touchscreen", "disabled"}, {"citra_enable_touch_touchscreen", "enabled"},
                {"citra_use_libretro_save_path", "LibRetro Default"}, {"citra_analog_function", "c_stick"}
            };
            std::signal(SIGINT, stopSignal);
            std::signal(SIGTERM, stopSignal);
            Core core(corePath);
            if (core.api_version() != RETRO_API_VERSION) throw std::runtime_error("Unsupported libretro API version");
            core.set_environment(environment);
            core.set_video_refresh(video);
            core.set_audio_sample(audioSample);
            core.set_audio_sample_batch(audioBatch);
            core.set_input_poll(pollInput);
            core.set_input_state(inputState);
            if (!headless) setupWindow();
            core.init(); core.initialized = true;
            retro_system_info info{}; core.get_system_info(&info);
            fprintf(stderr, "Core: %s %s; CPU %s; requested PICA renderer %s; state %s\n", info.library_name, info.library_version, cpu.c_str(), renderer.c_str(), stateDir.c_str());
            if (!info.need_fullpath) throw std::runtime_error("This host requires a core accepting full game paths");
            retro_game_info gameInfo{game.c_str(), nullptr, 0, nullptr};
            if (!core.load_game(&gameInfo)) throw std::runtime_error("Core rejected the supplied game; see core diagnostics above");
            core.loaded = true;
            if (useVulkan) VulkanBridge::initialize(std::filesystem::absolute(vulkanLibrary).string());
            core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
            retro_system_av_info av{}; core.get_system_av_info(&av); geometry = av.geometry;
            if (!std::isfinite(av.timing.fps) || av.timing.fps <= 0 || av.timing.fps > 1000) throw std::runtime_error("Invalid core frame rate");
            if (!headless && audioEnabled) startAudio(av.timing.sample_rate);
            auto start = std::chrono::steady_clock::now();
            auto previous = start;
            auto nextFrame = start;
            uint64_t runs = 0, frameOverruns = 0;
            double coreSeconds = 0, eventSeconds = 0, sleepSeconds = 0, maxFrameWorkSeconds = 0;
            const auto framePeriod = std::chrono::microseconds(int64_t(1000000.0 / av.timing.fps));
            while (!stopped && (!frameLimit || runs < frameLimit)) {
                @autoreleasepool {
                    auto eventStart = std::chrono::steady_clock::now();
                    if (!headless) {
                        NSEvent *event;
                        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
                        [NSApp updateWindows];
                    }
                    if (stopped) break;
                    auto now = std::chrono::steady_clock::now();
                    eventSeconds += std::chrono::duration<double>(now - eventStart).count();
                    if (frameTime.callback) frameTime.callback(runs ? std::chrono::duration_cast<std::chrono::microseconds>(now - previous).count() : frameTime.reference);
                    previous = now;
                    applyReplay(runs);
                    auto coreStart = std::chrono::steady_clock::now();
                    double presentationBefore = presentationSeconds;
                    core.run(); ++runs;
                    auto workEnd = std::chrono::steady_clock::now();
                    coreSeconds += std::chrono::duration<double>(workEnd - coreStart).count() - (presentationSeconds - presentationBefore);
                    maxFrameWorkSeconds = std::max(maxFrameWorkSeconds, std::chrono::duration<double>(workEnd - eventStart).count());
                    finishInputFrame();
                    if (!headless) {
                        if (workEnd - eventStart > framePeriod) ++frameOverruns;
                        nextFrame += framePeriod;
                        // Include Cocoa work and reclaim sleep drift; discard long-stall backlog.
                        if (workEnd - nextFrame > framePeriod) nextFrame = workEnd;
                        auto sleepStart = std::chrono::steady_clock::now();
                        std::this_thread::sleep_until(nextFrame);
                        sleepSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - sleepStart).count();
                    }
                }
            }
            double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            stopAudio();
            if (!failure.empty()) throw std::runtime_error(failure);
            if (!capturePath.empty()) capture(capturePath);
            uint64_t hash = 14695981039346656037ULL;
            for (uint8_t byte : pixels) { hash ^= byte; hash *= 1099511628211ULL; }
            NSDictionary *result = @{
                @"runtime": @"MH4U Runtime", @"cpu": @(cpu.c_str()),
                @"network_policy": @"deny network*",
                @"input_script_events": @(replay.size()), @"input_replay_frames": @(replayFrames),
                @"pica_renderer": @(renderer.c_str()), @"presenter": headless ? @"none" : @"Metal",
                @"vulkan_device": @(VulkanBridge::deviceName().c_str()),
                @"vulkan_readback_frames": @(VulkanBridge::readbackFrames()),
                @"vulkan_readback_seconds": @(VulkanBridge::readbackSeconds()),
                @"metalfx_spatial_used": @(fxUsed), @"retro_run_calls": @(runs),
                @"metal4_upscale_submissions": @(metal4Submissions),
                @"video_frames": @(videoFrames), @"nonblack_frames": @(nonblackFrames),
                @"presented_frames": @(presentedFrames), @"audio_sample_frames": @(audioFrames.load()),
                @"core_run_excluding_presentation_seconds": @(coreSeconds),
                @"presentation_seconds": @(presentationSeconds), @"event_pump_seconds": @(eventSeconds),
                @"pacing_sleep_seconds": @(sleepSeconds), @"frame_work_overruns": @(frameOverruns),
                @"max_frame_work_seconds": @(maxFrameWorkSeconds), @"target_fps": @(av.timing.fps),
                @"elapsed_seconds": @(elapsed), @"width": @(videoWidth), @"height": @(videoHeight),
                @"final_frame_fnv1a64": [NSString stringWithFormat:@"%016llx", (unsigned long long)hash],
                @"frame_limit_reached": @(frameLimit && runs == frameLimit)
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
            if (!videoFrames) throw std::runtime_error("Core returned without submitting any video frame");
            return 0;
        } catch (const std::exception &error) {
            stopAudio();
            fprintf(stderr, "MH4U Runtime: %s\n", error.what());
            if (showStartupAlert) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.alertStyle = NSAlertStyleCritical;
                alert.messageText = @"MH4U Runtime error";
                alert.informativeText = @(error.what());
                [alert runModal];
            }
            return 1;
        }
    }
}
