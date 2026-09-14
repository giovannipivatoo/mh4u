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
#include "audio_sample_buffer.h"
#include "texture_pack.h"
#include "save_import.h"
#include "temporal_frame.h"
#include "motion_estimator.h"
#include "temporal_processor.h"
#include <memory>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstddef>
#include <cmath>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <limits>
#include <iterator>
#include <mutex>
#include <sandbox.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <unistd.h>
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
    bool hasCStick = false;
    int16_t cstick[2]{};
};
static std::vector<ReplayEvent> replay;
static uint16_t replayButtons = 0;
static bool replayHasCircle = false;
static int16_t replayCircle[2]{};
static bool replayHasCStick = false;
static int16_t replayCStick[2]{};
static uint64_t replayFrames = 0;
static std::string stateDir;
static bool saveImportAvailable = false;
static std::string corePath;
static std::string failure;
static std::map<std::string, std::string> options;
static bool optionsUpdated = false;
static retro_frame_time_callback frameTime{};
static retro_game_geometry geometry{};
static std::vector<uint8_t> pixels;
static unsigned videoWidth = 0, videoHeight = 0;
static uint64_t videoFrames = 0, nonblackFrames = 0, presentedFrames = 0;
static double presentationSeconds = 0;
static std::atomic<uint64_t> audioFrames{0};
static std::atomic<uint64_t> audioCallbacks{0};
static std::atomic<uint64_t> audioConsumedFrames{0};
static std::atomic<uint64_t> audioQueueFailures{0};
static std::atomic<uint64_t> audioUnderrunEvents{0};
static std::atomic<uint64_t> audioUnderrunFrames{0};
static std::atomic<uint64_t> audioRecoveryEvents{0};
static std::atomic<uint64_t> audioDroppedFrames{0};
static std::atomic<uint64_t> audioQueueHighWaterFrames{0};
static std::atomic<uint64_t> audioSourceGapMaxMicros{0};
static AudioQueueRef audioQueue = nullptr;
static std::atomic<bool> audioAccepting{false};
static std::atomic<bool> audioStopping{true};
static std::atomic<bool> audioMeasuring{false};
static bool audioPaused = true;
static std::chrono::steady_clock::time_point audioLastSourceBatch{};
static std::mutex audioMutex;
static MH4U::AudioSampleBuffer audioSamples;
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
static bool fxEnabled = true, fxUsed = false, fxCommandLineOverride = false;
static bool temporalEnabled = false, generationEnabled = false, temporalOverride = false;
static bool temporalCoreAvailable = false, temporalHistoryReset = true;
static uint64_t temporalStartFrame = 0, temporalFrames = 0, generatedFrames = 0, generatedPresentations = 0;
static uint64_t temporalFallbackFrames = 0, temporalDuplicateFrames = 0, temporalResetFrames = 0;
static double temporalSeconds = 0, motionSeconds = 0, nativeFrameSeconds = 1.0 / 60.0;
static std::string temporalStatus = "Off", temporalCapturePath;
static std::vector<uint8_t> temporalPreviousColor;
static std::unique_ptr<MH4U::TemporalProcessor> temporalProcessor;
static id<MTLTexture> temporalOutput, generatedOutput, upperOverride;
static id<MTLTexture> lastGeneratedOutput;
static bool motionWarmed = false;
static void warmMotion();
static uint64_t previousDepthSequence = UINT64_MAX;
static unsigned temporalProcessorWidth = 0, temporalProcessorHeight = 0;
struct TemporalScaleStats {
    uint64_t frames = 0, generated = 0, presented = 0, fallback = 0, depthCallbacks = 0;
    unsigned inputWidth = 0, inputHeight = 0, outputWidth = 0, outputHeight = 0;
    float firstDepthMin = 0, firstDepthMax = 0;
    uint64_t firstDepthSubpixelDifferences = 0;
};
static TemporalScaleStats temporalScales[5];
static void resetTemporalHistory();
static void updateTemporal(NSUInteger width, NSUInteger height);
static unsigned resolutionFactor = 1;
static bool resolutionCommandLineOverride = false;
struct ResolutionChange { uint64_t frame; unsigned scale; };
struct DimensionChange { uint64_t frame; unsigned width, height; };
static std::vector<DimensionChange> dimensionChanges;
static uint64_t currentRunIndex = 0;
static NSUInteger cachedOutputWidth = 0, cachedOutputHeight = 0;
static bool manuallyPaused = false, localSettingsOpen = false;
static bool resetPacing = false;
static std::function<void()> menuTrackingFrame;
static NSTimer *menuTrackingTimer;
static NSMenu *trackedMenu;
static id menuTrackingBeginObserver, menuTrackingEndObserver;
static unsigned menuTrackingDepth = 0;
static bool menuTrackingFrameRunning = false;
static std::exception_ptr menuTrackingFailure;
static std::chrono::steady_clock::time_point menuTrackingStarted, menuTrackingLastTick, menuTrackingDeadline;
static double menuTrackingNestedSeconds = 0, menuTrackingTickSeconds = 0, menuTrackingMaxTickSeconds = 0;
static double audioVolume = 1.0;
static bool audioMuted = false;
static bool customTextures = false, old3DS = false;
static bool customTexturesOverride = false, systemProfileOverride = false;
static size_t (*stateSize)() = nullptr;
static bool (*stateSerialize)(void *, size_t) = nullptr;
static bool (*stateUnserialize)(const void *, size_t) = nullptr;
static std::string coreIdentityName, coreIdentityVersion;
static std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> coreIdentitySHA{};
static std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> stateConfigSHA{};
static uint64_t stateSaves = 0, stateLoads = 0;
struct StateAction { uint64_t frame; unsigned slot; };
static void clearNativeInput();
static void present();
static void saveState(unsigned slot);
static void loadState(unsigned slot);
static OSStatus fillAudioBuffer(AudioQueueRef queue, AudioQueueBufferRef buffer, bool measure);

static bool runtimePaused() { return manuallyPaused || localSettingsOpen || ControllerConfig::settingsOpen(); }

static void stopMenuTrackingFrames() {
    [menuTrackingTimer invalidate];
    menuTrackingTimer = nil;
    trackedMenu = nil;
    menuTrackingDepth = 0;
}

static void cancelTrackedMenu() {
    [trackedMenu cancelTracking];
    [NSApp.mainMenu cancelTracking];
}

static void installMenuTrackingFrames(double interval, std::function<void()> frame) {
    menuTrackingFrame = std::move(frame);
    menuTrackingFailure = {};
    menuTrackingNestedSeconds = menuTrackingTickSeconds = menuTrackingMaxTickSeconds = 0;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    menuTrackingBeginObserver = [center addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
        usingBlock:^(NSNotification *notification) {
            trackedMenu = notification.object;
            if (menuTrackingDepth++ || !menuTrackingFrame) return;
            menuTrackingStarted = menuTrackingLastTick = std::chrono::steady_clock::now();
            menuTrackingDeadline = menuTrackingStarted + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(interval));
            menuTrackingTimer = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *) {
                if (menuTrackingFrameRunning || !menuTrackingFrame) return;
                auto now = std::chrono::steady_clock::now();
                menuTrackingTickSeconds = std::chrono::duration<double>(now - menuTrackingLastTick).count();
                menuTrackingMaxTickSeconds = std::max(menuTrackingMaxTickSeconds, menuTrackingTickSeconds);
                menuTrackingLastTick = now;
                menuTrackingFrameRunning = true;
                try { menuTrackingFrame(); }
                catch (...) { menuTrackingFailure = std::current_exception(); cancelTrackedMenu(); }
                menuTrackingFrameRunning = false;
                menuTrackingDeadline += std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(interval));
                auto after = std::chrono::steady_clock::now();
                if (std::chrono::duration<double>(after - menuTrackingDeadline).count() > interval)
                    menuTrackingDeadline = after;
                double delay = std::max(0.0, std::chrono::duration<double>(menuTrackingDeadline - after).count());
                menuTrackingTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
            }];
            [NSRunLoop.mainRunLoop addTimer:menuTrackingTimer forMode:NSEventTrackingRunLoopMode];
        }];
    menuTrackingEndObserver = [center addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil
        usingBlock:^(NSNotification *) {
            if (menuTrackingDepth && --menuTrackingDepth) return;
            menuTrackingNestedSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - menuTrackingStarted).count();
            stopMenuTrackingFrames();
            resetPacing = true;
        }];
}

static void uninstallMenuTrackingFrames() {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (menuTrackingBeginObserver) [center removeObserver:menuTrackingBeginObserver];
    if (menuTrackingEndObserver) [center removeObserver:menuTrackingEndObserver];
    menuTrackingBeginObserver = menuTrackingEndObserver = nil;
    stopMenuTrackingFrames();
    menuTrackingFrame = {};
}

static void invalidateScaler() {
    resetTemporalHistory();
    cachedOutputWidth = cachedOutputHeight = 0;
}

static void setResolutionFactor(unsigned scale, bool persist) {
    resolutionFactor = std::clamp(scale, 1u, 4u);
    if (persist) [NSUserDefaults.standardUserDefaults setInteger:resolutionFactor forKey:@"InternalResolutionFactor"];
    options["citra_resolution_factor"] = std::to_string(resolutionFactor);
    optionsUpdated = true;
    invalidateScaler();
}

static void applyAudioLevel() {
    if (!audioQueue) return;
    OSStatus status = AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, audioMuted ? 0.f : float(audioVolume));
    if (status) throw std::runtime_error("AudioQueueSetParameter failed: " + std::to_string(status));
}

static void setAudioPaused(bool paused) {
    resetTemporalHistory();
    clearNativeInput();
    uint16_t releasedButtons = 0;
    int16_t releasedAxes[2][2]{};
    ControllerConfig::poll(releasedButtons, releasedAxes, false);
    if (!audioQueue) return;
    if (audioPaused == paused) return;
    audioAccepting = false;
    audioMeasuring = false;
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        audioSamples.clear();
    }
    audioLastSourceBatch = {};
    // Pause preserves the primed buffers and Start resumes them without Reset's callback race.
    OSStatus status = paused ? AudioQueuePause(audioQueue) : AudioQueueStart(audioQueue, nullptr);
    if (status) throw std::runtime_error(std::string(paused ? "AudioQueuePause" : "AudioQueueStart") +
        " failed: " + std::to_string(status));
    audioPaused = paused;
    if (!paused) { audioAccepting = audioMeasuring = true; applyAudioLevel(); }
}

static void settingsChanged(bool open) {
    localSettingsOpen = open;
    if (!open) resetPacing = true;
    setAudioPaused(runtimePaused());
}

@interface MH4URuntimeMenuTarget : NSObject
@property(nonatomic, strong) NSMenuItem *pauseItem;
@property(nonatomic, strong) NSTextField *graphicsStatus;
@property(nonatomic, strong) NSButton *temporalToggle;
@property(nonatomic, strong) NSButton *generationToggle;
@property(nonatomic, strong) NSPopUpButton *resolutionSelector;
- (void)togglePause:(id)sender;
- (void)saveState:(NSMenuItem *)sender;
- (void)loadState:(NSMenuItem *)sender;
- (void)showGraphics:(id)sender;
- (void)showAudio:(id)sender;
- (void)showTextures:(id)sender;
- (void)importGameSave:(id)sender;
- (void)openSaveBackups:(id)sender;
- (void)spatialChanged:(NSButton *)sender;
- (void)resolutionChanged:(NSPopUpButton *)sender;
- (void)temporalChanged:(NSButton *)sender;
- (void)generationChanged:(NSButton *)sender;
- (void)volumeChanged:(NSSlider *)sender;
- (void)muteChanged:(NSButton *)sender;
- (void)updateGraphicsStatus;
@end

static MH4URuntimeMenuTarget *runtimeMenuTarget;

@implementation MH4URuntimeMenuTarget

static void validatePackConfig(const std::filesystem::path& selected) {
    const std::filesystem::path config = TexturePack::sourceRoot(selected) / "pack.json";
    if (!std::filesystem::exists(config)) return;
    NSData *data = [NSData dataWithContentsOfFile:@(config.c_str())];
    NSError *error = nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![json isKindOfClass:NSDictionary.class]) throw std::runtime_error("pack.json is not a JSON object");
    id packOptions = ((NSDictionary *)json)[@"options"];
    for (NSString *key in @[@"skip_mipmap", @"flip_png_files", @"use_new_hash"]) {
        id value = [packOptions isKindOfClass:NSDictionary.class] ? ((NSDictionary *)packOptions)[key] : nil;
        if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
            throw std::runtime_error("pack.json must contain boolean skip_mipmap, flip_png_files, and use_new_hash options");
    }
    id textures = ((NSDictionary *)json)[@"textures"];
    if (!textures) return;
    if (![textures isKindOfClass:NSDictionary.class]) throw std::runtime_error("pack.json textures must be an object");
    for (NSString *key in (NSDictionary *)textures) {
        if (key.length == 0 || key.length > 16 || [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound)
            throw std::runtime_error("pack.json contains an invalid texture hash");
        id value = ((NSDictionary *)textures)[key];
        if ([value isKindOfClass:NSString.class]) continue;
        if (![value isKindOfClass:NSArray.class]) throw std::runtime_error("pack.json texture mappings must be strings or arrays of strings");
        for (id item in (NSArray *)value)
            if (![item isKindOfClass:NSString.class]) throw std::runtime_error("pack.json texture mapping arrays must contain only strings");
    }
}

static void packConfigSelfTest() {
    const std::filesystem::path base = std::filesystem::current_path() / ".local" / "mh4u-pack-config-self-test";
    std::filesystem::remove_all(base);
    try {
        const std::filesystem::path root = base / "0004000000126100";
        std::filesystem::create_directories(root);
        std::ofstream(root / "image.png") << "png";
        std::ofstream(root / "pack.json") << R"({"options":{"skip_mipmap":"no","flip_png_files":true,"use_new_hash":true}})";
        bool rejected = false;
        try { validatePackConfig(root); } catch (const std::exception&) { rejected = true; }
        if (!rejected) throw std::runtime_error("Texture pack self-test accepted an invalid pack.json");
        std::filesystem::remove_all(base);
    } catch (...) {
        std::filesystem::remove_all(base);
        throw;
    }
}

- (void)importGameSave:(id)sender {
    (void)sender;
    settingsChanged(true);
    @try {
        try {
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.title = @"Import MH4U Game Save";
            panel.message = @"Choose a folder containing user1, user2, user3 and system, or an individual user file. Use extracted game saves, not savestates or encrypted SD-card files.";
            panel.canChooseDirectories = YES; panel.canChooseFiles = YES;
            panel.allowsMultipleSelection = NO; panel.prompt = @"Review Import";
            if ([panel runModal] != NSModalResponseOK) return;
            std::filesystem::path source = panel.URL.fileSystemRepresentation;
            auto info = SaveImport::inspect(source);
            NSMutableArray *names = [NSMutableArray array];
            for (const auto& name : info.files) [names addObject:@(name.c_str())];
            NSAlert *review = [NSAlert new];
            review.messageText = @"Import at Next Launch?";
            review.informativeText = [NSString stringWithFormat:
                @"Files: %@ (%llu bytes).\n\nThese files will replace the same-named game saves at the next launch. Other slots and extra data stay as they are. A backup of your current game saves will be created first. Any previously queued import will be replaced.\n\nAfter restarting, use Continue in MH4U to load the imported characters. Existing savestates contain the previous session.",
                [names componentsJoinedByString:@", "], (unsigned long long)info.bytes];
            [review addButtonWithTitle:@"Import for Next Launch"]; [review addButtonWithTitle:@"Cancel"];
            if ([review runModal] != NSAlertFirstButtonReturn) return;
            SaveImport::stage(source, stateDir);
            NSAlert *done = [NSAlert new]; done.messageText = @"Import Queued";
            done.informativeText = @"Close and reopen MH4U Runtime to apply the import. Your current game saves have not changed. Backups will be available from Game → Open Save Backups. File names and sizes were checked; MH4U checks the save contents when loading them.";
            [done runModal];
        } catch (const std::exception& error) {
            NSAlert *alert = [NSAlert new]; alert.alertStyle = NSAlertStyleCritical;
            alert.messageText = @"Save Not Imported"; alert.informativeText = @(error.what()); [alert runModal];
        }
    } @finally { settingsChanged(false); [window makeKeyAndOrderFront:nil]; }
}

- (void)openSaveBackups:(id)sender {
    (void)sender;
    try {
        auto path = SaveImport::backupsDirectory(stateDir);
        std::filesystem::create_directories(path);
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(path.c_str()) isDirectory:YES]];
    } catch (const std::exception& error) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"Cannot Open Backups";
        alert.informativeText = @(error.what()); [alert runModal];
    }
}

- (void)showTextures:(id)sender {
    (void)sender;
    settingsChanged(true);
    @try {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Texture Settings";
        alert.informativeText = @"Large packs can take several minutes to copy. Changes apply after restarting MH4U Runtime.";
        [alert addButtonWithTitle:@"Install Texture Pack…"];
        [alert addButtonWithTitle:@"Done"];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 92)];
        NSButton *enabled = [NSButton checkboxWithTitle:@"Use custom textures" target:nil action:nil];
        enabled.frame = NSMakeRect(0, 64, 460, 24); enabled.state = customTextures ? NSControlStateValueOn : NSControlStateValueOff;
        NSTextField *label = [NSTextField labelWithString:@"System profile"];
        label.frame = NSMakeRect(0, 35, 100, 20);
        NSPopUpButton *profile = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, 31, 180, 26) pullsDown:NO];
        [profile addItemsWithTitles:@[@"Old 3DS", @"New 3DS"]]; [profile selectItemAtIndex:old3DS ? 0 : 1];
        NSTextField *path = [NSTextField wrappingLabelWithString:@"Packs are copied into this runtime’s private Azahar texture directory."];
        path.frame = NSMakeRect(0, 0, 460, 30); path.textColor = NSColor.secondaryLabelColor;
        for (NSView *item in @[enabled, label, profile, path]) [view addSubview:item];
        alert.accessoryView = view;
        NSModalResponse response = [alert runModal];
        customTextures = enabled.state == NSControlStateValueOn;
        old3DS = profile.indexOfSelectedItem == 0;
        [NSUserDefaults.standardUserDefaults setBool:customTextures forKey:@"CustomTexturesEnabled"];
        [NSUserDefaults.standardUserDefaults setBool:old3DS forKey:@"UseOld3DSProfile"];
        if (response == NSAlertFirstButtonReturn) {
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
            panel.message = @"Choose the extracted Citra or Azahar texture-pack directory.";
            if ([panel runModal] == NSModalResponseOK) {
                NSAlert *done = [NSAlert new];
                try {
                    validatePackConfig(panel.URL.fileSystemRepresentation);
                    TexturePack::InstallResult result = TexturePack::install(panel.URL.fileSystemRepresentation, stateDir, true);
                    customTextures = true;
                    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"CustomTexturesEnabled"];
                    done.messageText = @"Texture Pack Ready";
                    done.informativeText = [NSString stringWithFormat:@"Copied %llu supported files (%.2f GB). Restart MH4U Runtime to activate them.",
                        (unsigned long long)result.files, double(result.bytes) / 1000000000.0];
                } catch (const std::exception& exception) {
                    done.alertStyle = NSAlertStyleCritical; done.messageText = @"Texture Pack Not Installed";
                    done.informativeText = @(exception.what());
                }
                [done runModal];
            }
        }
    } @finally { settingsChanged(false); [window makeKeyAndOrderFront:nil]; }
}
- (void)updateGraphicsStatus {
    [self.resolutionSelector selectItemAtIndex:resolutionFactor - 1];
    self.temporalToggle.state = temporalEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.generationToggle.state = generationEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!self.graphicsStatus) return;
    if (temporalEnabled) { self.graphicsStatus.stringValue = @(temporalStatus.c_str()); return; }
    if (!fxEnabled) self.graphicsStatus.stringValue = @"Disabled.";
    else if (scalerProperties) self.graphicsStatus.stringValue = useMetal4Scaler ? @"Active: Metal 4FX." : @"Active: legacy MetalFX.";
    else if (metalDevice && ![MTLFXSpatialScalerDescriptor supportsDevice:metalDevice]) self.graphicsStatus.stringValue = @"Unavailable on this device.";
    else self.graphicsStatus.stringValue = @"Not needed at the current window and internal resolution.";
}
- (void)togglePause:(id)sender {
    (void)sender;
    manuallyPaused = !manuallyPaused;
    if (!manuallyPaused) resetPacing = true;
    self.pauseItem.title = manuallyPaused ? @"Resume Game" : @"Pause Game";
    setAudioPaused(runtimePaused());
}
- (void)saveState:(NSMenuItem *)sender {
    localSettingsOpen = true;
    setAudioPaused(true);
    NSAlert *alert = [NSAlert new];
    try {
        saveState([sender.representedObject unsignedIntValue]);
        alert.messageText = @"State Saved";
        alert.informativeText = @"The running session was saved. Normal in-game and SD-card files are separate and are not rolled back by loading this state.";
    } catch (const std::exception& exception) {
        alert.alertStyle = NSAlertStyleCritical; alert.messageText = @"State Not Saved"; alert.informativeText = @(exception.what());
    }
    @try { [alert runModal]; } @finally { localSettingsOpen = false; setAudioPaused(runtimePaused()); resetPacing = true; [window makeKeyAndOrderFront:nil]; }
}
- (void)loadState:(NSMenuItem *)sender {
    localSettingsOpen = true;
    setAudioPaused(true);
    NSAlert *alert = [NSAlert new];
    try {
        loadState([sender.representedObject unsignedIntValue]);
        alert.messageText = @"State Loaded";
        alert.informativeText = @"The running session was restored. Normal in-game and SD-card files remain at their current contents.";
    } catch (const std::exception& exception) {
        alert.alertStyle = NSAlertStyleCritical; alert.messageText = @"State Not Loaded"; alert.informativeText = @(exception.what());
    }
    @try { [alert runModal]; } @finally { localSettingsOpen = false; setAudioPaused(runtimePaused()); resetPacing = true; [window makeKeyAndOrderFront:nil]; }
}
- (void)spatialChanged:(NSButton *)sender {
    fxEnabled = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:fxEnabled forKey:@"MetalFXSpatialEnabled"];
    invalidateScaler();
    if (!pixels.empty() && window) present();
    [self updateGraphicsStatus];
}
- (void)temporalChanged:(NSButton *)sender {
    temporalEnabled = sender.state == NSControlStateValueOn;
    if (temporalEnabled) warmMotion();
    else generationEnabled = false;
    [NSUserDefaults.standardUserDefaults setBool:temporalEnabled forKey:@"ExperimentalTemporalEnabled"];
    [NSUserDefaults.standardUserDefaults setBool:generationEnabled forKey:@"ExperimentalFlowGenerationEnabled"];
    invalidateScaler();
    temporalStatus = temporalEnabled ? "Temporal pending resume at the selected resolution." : "Temporal disabled.";
    [self updateGraphicsStatus];
}
- (void)generationChanged:(NSButton *)sender {
    generationEnabled = sender.state == NSControlStateValueOn;
    if (generationEnabled) { temporalEnabled = true; warmMotion(); }
    [NSUserDefaults.standardUserDefaults setBool:temporalEnabled forKey:@"ExperimentalTemporalEnabled"];
    [NSUserDefaults.standardUserDefaults setBool:generationEnabled forKey:@"ExperimentalFlowGenerationEnabled"];
    invalidateScaler();
    temporalStatus = generationEnabled ? "Experimental optical-flow generation pending resume." : "Frame generation disabled.";
    [self updateGraphicsStatus];
}
- (void)resolutionChanged:(NSPopUpButton *)sender {
    setResolutionFactor(unsigned(sender.indexOfSelectedItem + 1), true);
    [self updateGraphicsStatus];
    self.graphicsStatus.stringValue = @"Resolution change pending until gameplay resumes.";
}
- (void)showGraphics:(id)sender {
    (void)sender;
    settingsChanged(true);
    @try {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Graphics Settings";
        alert.informativeText = @"Changes are applied when gameplay resumes.";
        [alert addButtonWithTitle:@"Done"];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 184)];
        NSTextField *resolutionLabel = [NSTextField labelWithString:@"Internal resolution"];
        resolutionLabel.frame = NSMakeRect(0, 158, 130, 20);
        NSPopUpButton *resolution = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(136, 154, 210, 26) pullsDown:NO];
        [resolution addItemsWithTitles:@[@"1× — 400 × 240", @"2× — 800 × 480", @"3× — 1200 × 720", @"4× — 1600 × 960"]];
        [resolution selectItemAtIndex:resolutionFactor - 1];
        resolution.target = self; resolution.action = @selector(resolutionChanged:); self.resolutionSelector = resolution;
        NSButton *spatial = [NSButton checkboxWithTitle:@"MetalFX spatial upscaling" target:self action:@selector(spatialChanged:)];
        spatial.frame = NSMakeRect(0, 120, 430, 24); spatial.state = fxEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSTextField *spatialStatus = [NSTextField labelWithString:@""];
        spatialStatus.frame = NSMakeRect(22, 102, 558, 18); spatialStatus.textColor = NSColor.secondaryLabelColor;
        self.graphicsStatus = spatialStatus; [self updateGraphicsStatus];
        NSButton *temporal = [NSButton checkboxWithTitle:@"MetalFX temporal — estimated motion (experimental, 1×–4×)" target:self action:@selector(temporalChanged:)];
        temporal.frame = NSMakeRect(0, 68, 580, 24); temporal.enabled = temporalCoreAvailable && MH4U::TemporalProcessor::supports(metalDevice, std::max(800u, 400u * resolutionFactor), std::max(480u, 240u * resolutionFactor), 400 * resolutionFactor, 240 * resolutionFactor); self.temporalToggle = temporal; temporal.state = temporalEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSTextField *temporalReason = [NSTextField labelWithString:temporalCoreAvailable ? @"Preserves the selected resolution. Motion estimation can add latency." : @"Requires a core with synchronized depth streaming."];
        temporalReason.frame = NSMakeRect(22, 50, 558, 18); temporalReason.textColor = NSColor.secondaryLabelColor;
        NSButton *frameGeneration = [NSButton checkboxWithTitle:@"Frame generation — optical flow (experimental, 1×–4×)" target:self action:@selector(generationChanged:)];
        frameGeneration.frame = NSMakeRect(0, 18, 580, 24); frameGeneration.enabled = temporal.enabled; self.generationToggle = frameGeneration; frameGeneration.state = generationEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSTextField *frameReason = [NSTextField labelWithString:@"Uses optical-flow interpolation. MetalFX frame interpolation is not yet available."];
        frameReason.frame = NSMakeRect(22, 0, 558, 18); frameReason.textColor = NSColor.secondaryLabelColor;
        for (NSView *item in @[resolutionLabel, resolution, spatial, spatialStatus, temporal, temporalReason, frameGeneration, frameReason]) [view addSubview:item];
        alert.accessoryView = view;
        [alert runModal];
    } @finally {
        self.graphicsStatus = nil; self.temporalToggle = nil; self.generationToggle = nil; self.resolutionSelector = nil;
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
        slider.accessibilityLabel = @"Volume";
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
    audioMeasuring = false;
    audioStopping = true;
    if (audioQueue) {
        OSStatus status = AudioQueueDispose(audioQueue, true);
        if (status) { ++audioQueueFailures; fprintf(stderr, "AudioQueueDispose failed: %d\n", int(status)); }
        audioQueue = nullptr;
    }
    audioPaused = true;
    std::lock_guard<std::mutex> lock(audioMutex);
    audioSamples.clear();
}

static void logMessage(enum retro_log_level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

// The private callback owns no frontend memory; copy only a bounded, upright top LCD.
static std::mutex temporalDepthMutex;
static mh4u_temporal_depth_frame temporalDepthMetadata{};
static std::vector<uint8_t> temporalDepthColor;
static std::vector<float> temporalDepth;
static bool temporalDepthReceived = false;
static uint64_t temporalDepthFrames = 0, temporalAlignmentRejected = 0;
static bool temporalDepthEnabled(void *) {
    return temporalEnabled && currentRunIndex >= temporalStartFrame;
}
static void receiveTemporalDepth(void *, const mh4u_temporal_depth_frame *frame) {
    constexpr uint32_t required = MH4U_TEMPORAL_DEPTH_TOP_UPRIGHT | MH4U_TEMPORAL_DEPTH_COLOR_BGRA8 |
        MH4U_TEMPORAL_DEPTH_DEPTH_R32F | MH4U_TEMPORAL_DEPTH_VALIDATED_SCALE;
    if (!frame || frame->abi_version != MH4U_TEMPORAL_DEPTH_ABI_VERSION || frame->struct_size != sizeof(*frame) ||
        frame->scale < 1 || frame->scale > 4 || frame->width != 400 * frame->scale || frame->height != 240 * frame->scale || (frame->flags & required) != required ||
        frame->color_row_bytes != frame->width * 4 || frame->depth_row_bytes != frame->width * 4 || !frame->color_bgra8 || !frame->depth_r32f) return;
    std::lock_guard<std::mutex> lock(temporalDepthMutex);
    temporalDepthMetadata = *frame;
    temporalDepthMetadata.color_bgra8 = nullptr; temporalDepthMetadata.depth_r32f = nullptr;
    temporalDepthColor.assign(frame->color_bgra8, frame->color_bgra8 + size_t(frame->width) * frame->height * 4);
    temporalDepth.assign(frame->depth_r32f, frame->depth_r32f + size_t(frame->width) * frame->height);
    temporalDepthReceived = true;
    ++temporalDepthFrames;
    ++temporalScales[frame->scale].depthCallbacks;
}
static void resetTemporalHistory() {
    temporalHistoryReset = true;
    temporalPreviousColor.clear();
    previousDepthSequence = UINT64_MAX;
    temporalOutput = generatedOutput = lastGeneratedOutput = nil;
}
static void warmMotion() {
    if (motionWarmed || !metalDevice || !metalQueue) return;
    std::vector<uint8_t> blank(64 * 64 * 4, 0);
    MotionEstimator::Result ignored; std::string error;
    motionWarmed = MotionEstimator::estimateCurrentToPrevious(blank.data(), 256, blank.data(), 256,
        64, 64, metalDevice, metalQueue, ignored, error);
}
static void updateTemporal(NSUInteger width, NSUInteger height) {
    generatedOutput = lastGeneratedOutput = nil;
    auto fallback = [&](const char *reason) {
        temporalStatus = reason; ++temporalFallbackFrames; ++temporalScales[resolutionFactor].fallback; resetTemporalHistory();
    };
    if (!temporalEnabled || currentRunIndex < temporalStartFrame) {
        if (temporalOutput) resetTemporalHistory();
        return;
    }
    auto started = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(temporalDepthMutex);
    const unsigned inputWidth = videoWidth, inputHeight = videoHeight / 2;
    const size_t inputPixels = size_t(inputWidth) * inputHeight, colorRow = size_t(inputWidth) * 4;
    if (!temporalDepthReceived || temporalDepthMetadata.width != inputWidth || temporalDepthMetadata.height != inputHeight ||
        temporalDepthMetadata.scale != resolutionFactor) {
        fallback("Spatial fallback: no synchronized scene depth"); return;
    }
    // Require the captured 3D color to agree with the currently presented top LCD.
    // RGB565 conversion can lose up to seven channel levels. A different buffer/HUD fails closed.
    size_t mismatched = 0;
    for (size_t i = 0; i < inputPixels * 4; i += 4)
        if (std::abs(int(pixels[i]) - temporalDepthColor[i]) > 10 ||
            std::abs(int(pixels[i+1]) - temporalDepthColor[i+1]) > 10 ||
            std::abs(int(pixels[i+2]) - temporalDepthColor[i+2]) > 10) ++mismatched;
    if (mismatched > inputPixels / 100) {
        ++temporalAlignmentRejected; fallback("Spatial fallback: scene/color mismatch"); return;
    }
    // PICA Z depth is meaningful for temporal rejection without reconstructing a camera.
    // W buffering has a different convention; do not silently treat it as perspective Z.
    if (temporalDepthMetadata.pica_depth_mode != MH4U_PICA_Z_BUFFERING ||
        temporalDepthMetadata.pica_viewport_depth_scale != -1.f || temporalDepthMetadata.pica_viewport_depth_offset != 0.f) {
        fallback("Spatial fallback: unsupported depth convention"); return;
    }
    std::vector<uint8_t> current(pixels.begin(), pixels.begin() + inputPixels * 4);
    if (!temporalHistoryReset && (temporalDepthMetadata.sequence == previousDepthSequence || current == temporalPreviousColor) && temporalOutput &&
        temporalOutput.width == width && temporalOutput.height == height) {
        previousDepthSequence = temporalDepthMetadata.sequence;
        ++temporalDuplicateFrames; return;
    }
    try {
        bool reset = temporalHistoryReset || temporalPreviousColor.size() != current.size() ||
            (previousDepthSequence != UINT64_MAX && temporalDepthMetadata.sequence != previousDepthSequence + 1);
        MotionEstimator::Result motion;
        if (!reset) {
            std::string error;
            if (!MotionEstimator::estimateCurrentToPrevious(temporalPreviousColor.data(), colorRow,
                    current.data(), colorRow, inputWidth, inputHeight, metalDevice, metalQueue, motion, error)) {
                temporalStatus = error; ++temporalFallbackFrames; resetTemporalHistory(); return;
            }
            motionSeconds += motion.elapsedMilliseconds / 1000.0;
            // Reject discontinuities by checking the estimated warp against the previous color.
            double residual = 0; size_t samples = 0;
            for (unsigned y = 4; y + 4 < inputHeight; y += 4 * resolutionFactor) for (unsigned x = 4; x + 4 < inputWidth; x += 4 * resolutionFactor) {
                size_t i = y * inputWidth + x;
                int px = int(std::lround(x + motion.xy[i * 2])), py = int(std::lround(y + motion.xy[i * 2 + 1]));
                if (px < 0 || py < 0 || px >= int(inputWidth) || py >= int(inputHeight)) continue;
                for (unsigned c = 0; c < 3; ++c) {
                    residual += std::abs(int(current[i * 4 + c]) - temporalPreviousColor[(py * inputWidth + px) * 4 + c]); ++samples;
                }
            }
            reset = !samples || residual / samples > 25.0;
        }
        if (reset) { motion.xy.assign(inputPixels * 2, 0.f); ++temporalResetFrames; }
        if (!temporalProcessor || !temporalOutput || temporalProcessorWidth != inputWidth || temporalProcessorHeight != inputHeight || temporalOutput.width != width || temporalOutput.height != height) {
            temporalProcessor = std::make_unique<MH4U::TemporalProcessor>(metalDevice, metalQueue, width, height, inputWidth, inputHeight);
            temporalProcessorWidth = inputWidth; temporalProcessorHeight = inputHeight;
            reset = true;
        }
        temporalOutput = temporalProcessor->process(current.data(), colorRow, temporalDepth.data(), colorRow,
            motion.xy.data(), colorRow * 2, false, reset, reset ? nullptr : motion.valid.data());
        ++temporalFrames;
        auto &scaleStats = temporalScales[resolutionFactor];
        // Record one successful depth sample per scale without retaining scene data.
        if (!scaleStats.frames) {
            auto range = std::minmax_element(temporalDepth.begin(), temporalDepth.end());
            scaleStats.firstDepthMin = *range.first; scaleStats.firstDepthMax = *range.second;
            for (unsigned y = 0; y < inputHeight; ++y) for (unsigned x = 0; x < inputWidth; ++x) {
                size_t i = size_t(y) * inputWidth + x;
                if ((x % resolutionFactor && temporalDepth[i] != temporalDepth[i - 1]) ||
                    (y % resolutionFactor && temporalDepth[i] != temporalDepth[i - inputWidth]))
                    ++scaleStats.firstDepthSubpixelDifferences;
            }
        }
        ++scaleStats.frames; scaleStats.inputWidth = inputWidth; scaleStats.inputHeight = inputHeight;
        scaleStats.outputWidth = temporalOutput.width; scaleStats.outputHeight = temporalOutput.height;
        if (generationEnabled && !reset && motion.meanMagnitude > .05 * resolutionFactor && motion.validFraction > .1) {
            generatedOutput = temporalProcessor->interpolateEstimatedMotion();
            if (generatedOutput) { ++generatedFrames; ++scaleStats.generated; lastGeneratedOutput = generatedOutput; }
        }
        previousDepthSequence = temporalDepthMetadata.sequence;
        temporalPreviousColor = std::move(current);
        temporalHistoryReset = false;
        temporalStatus = generatedOutput ? "Active: temporal + optical-flow generation (experimental)" : "Active: MetalFX temporal with estimated motion";
    } catch (const std::exception &error) {
        temporalStatus = std::string("Spatial fallback: ") + error.what();
        ++temporalFallbackFrames; resetTemporalHistory();
    }
    temporalSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
}

static bool environment(unsigned command, void *data) {
    switch (command) {
    case RETRO_ENVIRONMENT_GET_MH4U_TEMPORAL_DEPTH_SINK: {
        auto *sink = static_cast<mh4u_temporal_depth_sink *>(data);
        if (!sink || sink->abi_version != MH4U_TEMPORAL_DEPTH_ABI_VERSION || sink->struct_size != sizeof(*sink)) return false;
        sink->enabled = temporalDepthEnabled; sink->callback = receiveTemporalDepth; sink->user = nullptr;
        temporalCoreAvailable = true;
        return true;
    }
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
        *static_cast<bool *>(data) = optionsUpdated;
        optionsUpdated = false;
        return true;
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
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: return true;
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS: {
        auto *quirks = static_cast<uint64_t *>(data);
        if (!quirks) return false;
        constexpr uint64_t supported = RETRO_SERIALIZATION_QUIRK_INCOMPLETE |
            RETRO_SERIALIZATION_QUIRK_MUST_INITIALIZE | RETRO_SERIALIZATION_QUIRK_CORE_VARIABLE_SIZE |
            RETRO_SERIALIZATION_QUIRK_ENDIAN_DEPENDENT | RETRO_SERIALIZATION_QUIRK_PLATFORM_DEPENDENT;
        *quirks = (*quirks & supported) | RETRO_SERIALIZATION_QUIRK_FRONT_VARIABLE_SIZE;
        return true;
    }
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
        if (index == 1 && replayHasCStick) return replayCStick[id];
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

static int menuTrackingSelfTest() {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *testWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 160, 100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [testWindow makeKeyAndOrderFront:nil];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tracking Test"];
    [menu addItemWithTitle:@"Keep Running" action:nil keyEquivalent:@""];
    unsigned frames = 0;
    __block bool watchdogFired = false;
    installMenuTrackingFrames(.005, [&] {
        if (++frames == 3) cancelTrackedMenu();
    });
    NSTimer *watchdog = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer *) {
        watchdogFired = true;
        cancelTrackedMenu();
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSEventTrackingRunLoopMode];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(20, 20) inView:testWindow.contentView];
    [watchdog invalidate];
    uninstallMenuTrackingFrames();
    [testWindow orderOut:nil];
    if (menuTrackingFailure) {
        auto failure = menuTrackingFailure;
        menuTrackingFailure = {};
        std::rethrow_exception(failure);
    }
    if (watchdogFired || frames < 3) throw std::runtime_error("Menu tracking self-test did not advance frames");
    printf("{\"mode\":\"menu-tracking-self-test\",\"passed\":true,\"frames_during_tracking\":%u}\n", frames);
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
    replayHasCStick = true; replayCStick[0] = 12345; replayCStick[1] = -23456;
    require(inputState(0, RETRO_DEVICE_ANALOG, 1, RETRO_DEVICE_ID_ANALOG_X) == 12345 &&
        inputState(0, RETRO_DEVICE_ANALOG, 1, RETRO_DEVICE_ID_ANALOG_Y) == -23456,
        "replayed C-stick did not reach analog index 1");
    require(inputState(0, RETRO_DEVICE_ANALOG, 0, RETRO_DEVICE_ID_ANALOG_X) != 12345,
        "replayed C-stick overwrote the Circle Pad");
    replayHasCStick = false;
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
    manuallyPaused = true; localSettingsOpen = true;
    require(runtimePaused(), "settings did not pause the runtime");
    settingsChanged(false);
    require(runtimePaused(), "closing settings incorrectly cleared a manual pause");
    manuallyPaused = false;
    require(!runtimePaused(), "resume left the runtime paused");
    optionsUpdated = true;
    bool updated = false;
    require(environment(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) && updated,
        "core option update was not reported");
    updated = true;
    require(environment(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) && !updated,
        "core option update was not one-shot");
    for (unsigned scale = 1; scale <= VulkanBridge::maxResolutionScale; ++scale)
        require(VulkanBridge::validFrameDimensions(400 * scale, 480 * scale), "valid resolution scale was rejected");
    require(!VulkanBridge::validFrameDimensions(0, 0), "zero-sized frame was accepted");
    require(!VulkanBridge::validFrameDimensions(2000, 2400), "5x frame was accepted");
    require(!VulkanBridge::validFrameDimensions(800, 480), "mismatched frame aspect was accepted");
    require(!VulkanBridge::validFrameDimensions(std::numeric_limits<unsigned>::max(), std::numeric_limits<unsigned>::max()),
        "overflow-sized frame was accepted");
    puts("{\"mode\":\"input-self-test\",\"passed\":true,\"minimum_tap_frames\":2}");
    return 0;
}

static OSStatus fillAudioBuffer(AudioQueueRef queue, AudioQueueBufferRef buffer, bool measure) {
    if (audioStopping) return noErr;
    if (measure) ++audioCallbacks;
    auto *out = static_cast<int16_t *>(buffer->mAudioData);
    const size_t frames = buffer->mAudioDataBytesCapacity / (2 * sizeof(int16_t));
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        const auto result = MH4U::dequeueStereo(audioSamples, out, frames);
        audioConsumedFrames += result.sourceFrames;
        if (measure && audioMeasuring) {
            audioUnderrunFrames += result.underrunFrames;
            if (result.underrunStarted) ++audioUnderrunEvents;
            if (result.recoveryStarted) ++audioRecoveryEvents;
        }
    }
    buffer->mAudioDataByteSize = static_cast<UInt32>(frames * 2 * sizeof(int16_t));
    return AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

static void audioOutput(void *, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    if (OSStatus status = fillAudioBuffer(queue, buffer, true); status) ++audioQueueFailures;
}

static size_t audioBatch(const int16_t *data, size_t frames) {
    audioFrames += frames;
    if (audioAccepting && data && frames) {
        const auto now = std::chrono::steady_clock::now();
        if (audioLastSourceBatch != std::chrono::steady_clock::time_point{}) {
            const uint64_t gap = std::chrono::duration_cast<std::chrono::microseconds>(now - audioLastSourceBatch).count();
            audioSourceGapMaxMicros = std::max(audioSourceGapMaxMicros.load(), gap);
        }
        audioLastSourceBatch = now;
        std::lock_guard<std::mutex> lock(audioMutex);
        const auto result = MH4U::enqueueStereo(audioSamples, data, frames);
        audioDroppedFrames += result.droppedFrames;
        audioQueueHighWaterFrames = std::max<uint64_t>(audioQueueHighWaterFrames.load(), result.queuedFrames);
    }
    return frames;
}
static void audioSample(int16_t l, int16_t r) { int16_t sample[] = {l, r}; audioBatch(sample, 1); }

static void startAudio(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) throw std::runtime_error("Invalid core audio sample rate");
    audioStopping = false;
    audioMeasuring = false;
    audioLastSourceBatch = {};
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
        status = fillAudioBuffer(audioQueue, buffer, false);
        if (status) throw std::runtime_error("AudioQueueEnqueueBuffer failed: " + std::to_string(status));
    }
    if (AudioQueueStart(audioQueue, nullptr)) throw std::runtime_error("AudioQueueStart failed");
    audioPaused = false;
    audioAccepting = true;
    audioMeasuring = true;
    applyAudioLevel();
}

static int audioSelfTest() {
    auto require = [](bool condition, const char *message) {
        if (!condition) throw std::runtime_error(std::string("Audio self-test failed: ") + message);
    };
    audioCallbacks = audioConsumedFrames = audioQueueFailures = 0;
    audioUnderrunEvents = audioUnderrunFrames = audioRecoveryEvents = 0;
    audioDroppedFrames = audioQueueHighWaterFrames = audioSourceGapMaxMicros = 0;
    audioVolume = .37;
    audioMuted = false;
    startAudio(48000);
    auto waitFor = [](const std::atomic<uint64_t>& counter, uint64_t after) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        while (counter.load() <= after && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
    };
    AudioQueueParameterValue level = -1;
    require(AudioQueueGetParameter(audioQueue, kAudioQueueParam_Volume, &level) == noErr && std::abs(level - .37f) < .01f,
        "volume was not applied to AudioQueue");
    uint64_t startedCallbacks = audioCallbacks.load();
    waitFor(audioCallbacks, startedCallbacks);
    require(audioCallbacks.load() > startedCallbacks, "output callbacks did not start");
    std::array<int16_t, MH4U::audioRebufferFrames * 2> samples{};
    uint64_t consumed = audioConsumedFrames.load();
    audioBatch(samples.data(), samples.size() / 2);
    waitFor(audioConsumedFrames, consumed);
    require(audioConsumedFrames.load() > consumed, "initial buffered samples were not consumed");
    uint64_t underruns = audioUnderrunEvents.load();
    waitFor(audioUnderrunEvents, underruns);
    require(audioUnderrunEvents.load() > underruns, "source stall did not start an underrun episode");
    uint64_t recoveries = audioRecoveryEvents.load();
    audioBatch(samples.data(), samples.size() / 2);
    waitFor(audioRecoveryEvents, recoveries);
    require(audioRecoveryEvents.load() > recoveries, "full rebuffer did not recover AudioQueue output");
    for (unsigned cycle = 0; cycle < 8; ++cycle) {
        setAudioPaused(true);
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        uint64_t pausedCallbacks = audioCallbacks.load();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        require(audioCallbacks.load() == pausedCallbacks, "callbacks continued while paused");
        audioMuted = cycle % 2 == 0;
        audioVolume = .2 + cycle * .1;
        applyAudioLevel();
        require(AudioQueueGetParameter(audioQueue, kAudioQueueParam_Volume, &level) == noErr &&
            std::abs(level - (audioMuted ? 0.f : float(audioVolume))) < .01f,
            "repeated mute or volume change was not applied");
        setAudioPaused(false);
        const uint64_t resumedCallbacks = audioCallbacks.load();
        waitFor(audioCallbacks, resumedCallbacks + 3);
        require(audioCallbacks.load() > resumedCallbacks + 3, "callbacks did not remain active after resume");
        consumed = audioConsumedFrames.load();
        audioBatch(samples.data(), samples.size() / 2);
        waitFor(audioConsumedFrames, consumed);
        require(audioConsumedFrames.load() > consumed, "resumed queue did not consume new samples");
    }
    stopAudio();
    require(audioQueueFailures.load() == 0, "AudioQueue operation failed during playback or teardown");
    require(audioDroppedFrames.load() == 0 && audioQueueHighWaterFrames.load() >= MH4U::audioRebufferFrames,
        "normal recovery unexpectedly overflowed or missed its rebuffer target");
    printf("{\"mode\":\"audio-self-test\",\"passed\":true,\"cycles\":8,\"callbacks\":%llu,\"consumed_frames\":%llu,\"underrun_events\":%llu,\"recovery_events\":%llu,\"queue_errors\":0}\n",
        (unsigned long long)audioCallbacks.load(), (unsigned long long)audioConsumedFrames.load(),
        (unsigned long long)audioUnderrunEvents.load(), (unsigned long long)audioRecoveryEvents.load());
    return 0;
}

static void setupWindow() {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!presentationTesting) {
        if (!fxCommandLineOverride && [defaults objectForKey:@"MetalFXSpatialEnabled"]) fxEnabled = [defaults boolForKey:@"MetalFXSpatialEnabled"];
        if (!resolutionCommandLineOverride && [defaults objectForKey:@"InternalResolutionFactor"])
            resolutionFactor = std::clamp<NSInteger>([defaults integerForKey:@"InternalResolutionFactor"], 1, 4);
        if ([defaults objectForKey:@"AudioVolume"]) audioVolume = std::clamp([defaults doubleForKey:@"AudioVolume"], 0.0, 1.0);
        audioMuted = [defaults boolForKey:@"AudioMuted"];
    }
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
        if (metal4Enabled && [metalDevice supportsFamily:MTLGPUFamilyMetal4] && [MTLFXSpatialScalerDescriptor supportsMetal4FX:metalDevice]) {
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
        [gameMenu addItem:pause]; [gameMenu addItem:[NSMenuItem separatorItem]];
        for (unsigned slot = 1; slot <= 3; ++slot) {
            NSString *key = slot == 1 ? @"s" : @"";
            NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Save State — Slot %u", slot] action:@selector(saveState:) keyEquivalent:key];
            save.target = runtimeMenuTarget; save.representedObject = @(slot); [gameMenu addItem:save];
        }
        [gameMenu addItem:[NSMenuItem separatorItem]];
        for (unsigned slot = 1; slot <= 3; ++slot) {
            NSString *key = slot == 1 ? @"l" : @"";
            NSMenuItem *load = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Load State — Slot %u", slot] action:@selector(loadState:) keyEquivalent:key];
            load.target = runtimeMenuTarget; load.representedObject = @(slot); [gameMenu addItem:load];
        }
        [gameMenu addItem:[NSMenuItem separatorItem]];
        gameMenu.autoenablesItems = NO;
        NSMenuItem *importSave = [[NSMenuItem alloc] initWithTitle:@"Import Game Save…" action:@selector(importGameSave:) keyEquivalent:@""];
        importSave.target = runtimeMenuTarget; importSave.enabled = saveImportAvailable; [gameMenu addItem:importSave];
        NSMenuItem *backups = [[NSMenuItem alloc] initWithTitle:@"Open Save Backups…" action:@selector(openSaveBackups:) keyEquivalent:@""];
        backups.target = runtimeMenuTarget; backups.enabled = saveImportAvailable; [gameMenu addItem:backups];
        gameRoot.submenu = gameMenu; [menu addItem:gameRoot];
        NSMenu *settings = [menu itemWithTitle:@"Settings"].submenu;
        [settings insertItem:[NSMenuItem separatorItem] atIndex:0];
        NSMenuItem *audio = [[NSMenuItem alloc] initWithTitle:@"Audio…" action:@selector(showAudio:) keyEquivalent:@""];
        audio.target = runtimeMenuTarget; [settings insertItem:audio atIndex:0];
        NSMenuItem *graphics = [[NSMenuItem alloc] initWithTitle:@"Graphics…" action:@selector(showGraphics:) keyEquivalent:@""];
        graphics.target = runtimeMenuTarget; [settings insertItem:graphics atIndex:0];
        NSMenuItem *textures = [[NSMenuItem alloc] initWithTitle:@"Textures…" action:@selector(showTextures:) keyEquivalent:@""];
        textures.target = runtimeMenuTarget; [settings insertItem:textures atIndex:0];
    }
    NSApp.mainMenu = menu;
    [window makeFirstResponder:view];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp finishLaunching];
    if (!presentationTesting) [NSApp activateIgnoringOtherApps:YES];
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    if (!presentationTesting) {
        lowerVisible = ControllerConfig::lowerScreenVisible();
        if (ControllerConfig::fullscreenPreferred()) setFullscreen(true);
    }
    fprintf(stderr, "Metal presenter: %s. WASD move; arrows D-pad; J/K/U/I B/A/Y/X; Q/E L/R; Enter Start; Tab Select; click lower screen; Esc quits.\n", metalDevice.name.UTF8String);
}

static bool canPresentWindow() {
    return presentationTesting || (window.visible && !window.miniaturized &&
        (window.occlusionState & NSWindowOcclusionStateVisible));
}

static void present() {
    // Avoid blocking the emulation/audio producer in nextDrawable while fully occluded.
    if (!canPresentWindow()) return;
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
    if (scalerProperties && !upperOverride) {
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
    [encoder setFragmentTexture:upperOverride ?: (scalerProperties ? scaledTexture : inputTexture) atIndex:0];
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
                // Center is white; 6.5 logical pixels away is inside the one-pixel black outline.
                NSUInteger x = NSMidX(lower) + i * 6.5 * scale;
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
        bool frameCompositePassed = true;
        for (unsigned i = 0; i < (lowerVisible ? 4u : 2u); ++i)
            for (unsigned c = 0; c < 3; ++c)
                frameCompositePassed &= std::abs(int(static_cast<uint8_t *>(compositeReadback.contents)[i * 256 + c]) - expected[i][c]) <= 16;
        if (lowerVisible)
            for (unsigned i = 0; i < 2; ++i)
                for (unsigned c = 0; c < 3; ++c)
                    frameCompositePassed &= std::abs(int(static_cast<uint8_t *>(compositeReadback.contents)[(4 + i) * 256 + c]) - (i ? 0 : 255)) <= 16;
        if (!frameCompositePassed) {
            auto *actual = static_cast<uint8_t *>(compositeReadback.contents);
            fprintf(stderr, "Composite readback mismatch: lower=%s samples=[%u,%u,%u] [%u,%u,%u] [%u,%u,%u] [%u,%u,%u] cursor=[%u,%u,%u] [%u,%u,%u].\n",
                lowerVisible ? "true" : "false", actual[0], actual[1], actual[2], actual[256], actual[257], actual[258],
                actual[512], actual[513], actual[514], actual[768], actual[769], actual[770],
                actual[1024], actual[1025], actual[1026], actual[1280], actual[1281], actual[1282]);
        }
        compositePassed &= frameCompositePassed;
    }
    if (command.status != MTLCommandBufferStatusCompleted) {
        failure = command.error ? command.error.localizedDescription.UTF8String : "Metal submission failed";
        stopped = 1;
    } else {
        ++presentedFrames;
        fxUsed = fxUsed || (scalerProperties != nil && !upperOverride);
    }
}

static void finishVideo(unsigned width, unsigned height, bool nonblack) {
    if (width != videoWidth || height != videoHeight)
        dimensionChanges.push_back({currentRunIndex, width, height});
    videoWidth = width; videoHeight = height;
    ++videoFrames;
    nonblackFrames += nonblack;
    auto started = std::chrono::steady_clock::now();
    if (temporalEnabled) updateTemporal(std::max(800u, videoWidth), std::max(480u, videoHeight / 2));
    if (!headless) {
        if (generatedOutput && !runtimePaused()) {
            upperOverride = generatedOutput;
            uint64_t before = presentedFrames;
            present();
            if (presentedFrames > before) { ++generatedPresentations; ++temporalScales[resolutionFactor].presented; }
            // Two ordered presentations within a core interval. Input/core advance only once.
            std::this_thread::sleep_for(std::chrono::duration<double>(nativeFrameSeconds * .5));
        }
        upperOverride = temporalOutput;
        if (!stopped) present();
        upperOverride = nil;
    }
    presentationSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
}

static void softwareVideo(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return; // libretro duplicate frame; preserve the last genuine frame.
    if (data == RETRO_HW_FRAME_BUFFER_VALID || !VulkanBridge::validFrameDimensions(width, height) || pitch < size_t(width) * 4) {
        failure = "Core submitted an unsupported or invalid software frame"; stopped = 1; return;
    }
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
    finishVideo(width, height, nonblack);
}

static void vulkanVideo(std::vector<uint8_t> &frame, unsigned width, unsigned height) {
    // The bridge owns tightly packed BGRA pixels and has already made alpha opaque.
    pixels.swap(frame);
    bool nonblack = false;
    for (size_t i = 0; i < pixels.size(); i += 4) {
        if (pixels[i] || pixels[i + 1] || pixels[i + 2]) {
            nonblack = true;
            break;
        }
    }
    finishVideo(width, height, nonblack);
}


static int videoSelfTest() {
    headless = true;
    temporalEnabled = false;
    auto require = [](bool condition, const char *message) {
        if (!condition) throw std::runtime_error(std::string("Video self-test failed: ") + message);
    };
    constexpr unsigned width = 400, height = 480;
    constexpr size_t pitch = width * 4 + 16;
    std::vector<uint8_t> padded(pitch * height, 0);
    padded[(height - 1) * pitch + (width - 1) * 4] = 73;
    softwareVideo(padded.data(), width, height, pitch);
    require(pixels.size() == width * height * 4 && pixels[pixels.size() - 4] == 73 &&
            pixels[3] == 255 && nonblackFrames == 1, "software pitch/color/alpha handling");
    auto opaqueBlack = [](unsigned scale) {
        std::vector<uint8_t> frame(size_t(400 * scale) * (480 * scale) * 4, 0);
        for (size_t i = 3; i < frame.size(); i += 4) frame[i] = 255;
        return frame;
    };
    auto frame = opaqueBlack(1);
    vulkanVideo(frame, width, height);
    std::fill(frame.begin(), frame.end(), 99); // Producer may reuse its returned buffer immediately.
    require(pixels[0] == 0 && pixels[3] == 255 && nonblackFrames == 1,
            "opaque black or producer buffer lifetime");
    frame = opaqueBlack(4);
    frame[frame.size() - 2] = 91;
    vulkanVideo(frame, width * 4, height * 4);
    require(videoWidth == 1600 && videoHeight == 1920 && pixels[pixels.size() - 2] == 91 &&
            nonblackFrames == 2, "scaled frame or final-pixel detection");
    frame = opaqueBlack(1);
    vulkanVideo(frame, width, height);
    auto *lastFrame = pixels.data();
    softwareVideo(nullptr, width, height, width * 4);
    require(videoWidth == width && videoHeight == height && videoFrames == 4 &&
            nonblackFrames == 2 && pixels.data() == lastFrame && pixels.size() == width * height * 4,
            "downscale or duplicate frame preservation");
    puts("{\"mode\":\"video-self-test\",\"passed\":true}");
    return 0;
}

static void video(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!useVulkan) { softwareVideo(data, width, height, pitch); return; }
    try { VulkanBridge::video(data, width, height, vulkanVideo); }
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
    CORE_FN(set_controller_port_device); CORE_FN(serialize_size); CORE_FN(serialize); CORE_FN(unserialize);
#undef CORE_FN
    explicit Core(const std::string &path) {
        handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) throw std::runtime_error(std::string("Cannot load core: ") + dlerror());
#define LOAD(name) name = reinterpret_cast<decltype(name)>(dlsym(handle, "retro_" #name)); if (!name) { dlclose(handle); handle = nullptr; throw std::runtime_error("Core missing retro_" #name); }
        LOAD(api_version); LOAD(set_environment); LOAD(set_video_refresh); LOAD(set_audio_sample);
        LOAD(set_audio_sample_batch); LOAD(set_input_poll); LOAD(set_input_state); LOAD(init);
        LOAD(deinit); LOAD(get_system_info); LOAD(get_system_av_info); LOAD(load_game);
        LOAD(unload_game); LOAD(run); LOAD(set_controller_port_device);
        LOAD(serialize_size); LOAD(serialize); LOAD(unserialize);
#undef LOAD
    }
    ~Core() {
        // Destroy MetalFX while its framework services are still alive, before static teardown.
        resetTemporalHistory();
        upperOverride = nil;
        temporalProcessor.reset();
        stopAudio();
        VulkanBridge::destroyCoreContext();
        if (loaded) unload_game();
        VulkanBridge::shutdown();
        if (initialized) deinit();
        if (handle) dlclose(handle);
    }
};

struct StateHeader {
    char magic[8];
    uint32_t version, headerSize;
    uint64_t payloadSize;
    uint8_t coreSHA[CC_SHA256_DIGEST_LENGTH], configSHA[CC_SHA256_DIGEST_LENGTH], payloadSHA[CC_SHA256_DIGEST_LENGTH];
    char coreName[64], coreVersion[64];
};
static_assert(std::is_trivially_copyable_v<StateHeader>);
static constexpr uint64_t maxStateBytes = 1024ULL * 1024 * 1024;

static std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> sha256(const void *data, size_t size) {
    std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256(data, static_cast<CC_LONG>(size), digest.data());
    return digest;
}

static std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> sha256File(const std::string& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read core for savestate compatibility check: " + path);
    CC_SHA256_CTX context;
    if (!CC_SHA256_Init(&context)) throw std::runtime_error("Cannot initialize core SHA-256");
    std::array<char, 1024 * 1024> chunk{};
    while (input) {
        input.read(chunk.data(), chunk.size());
        std::streamsize count = input.gcount();
        if (count > 0 && !CC_SHA256_Update(&context, chunk.data(), static_cast<CC_LONG>(count)))
            throw std::runtime_error("Cannot hash core for savestate compatibility check");
    }
    if (!input.eof() || input.bad()) throw std::runtime_error("Cannot read core completely for savestate compatibility check");
    std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
    if (!CC_SHA256_Final(digest.data(), &context)) throw std::runtime_error("Cannot finish core SHA-256");
    return digest;
}

static std::filesystem::path statePath(unsigned slot) {
    if (slot < 1 || slot > 9) throw std::runtime_error("Savestate slot must be from 1 to 9");
    return std::filesystem::path(stateDir) / "savestates" / ("slot" + std::to_string(slot) + ".mh4ustate");
}

static void writeAll(int fd, const void *bytes, size_t size) {
    const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
    while (size) {
        ssize_t count = ::write(fd, cursor, size);
        if (count < 0) { if (errno == EINTR) continue; throw std::runtime_error("Cannot write savestate"); }
        if (!count) throw std::runtime_error("Savestate write made no progress");
        cursor += count; size -= size_t(count);
    }
}

static void saveState(unsigned slot) {
    if (!stateSize || !stateSerialize) throw std::runtime_error("No game session is available to save");
    size_t size = stateSize();
    if (!size || size > maxStateBytes) throw std::runtime_error("Core returned an invalid or oversized savestate");
    std::vector<uint8_t> payload(size);
    if (!stateSerialize(payload.data(), payload.size())) throw std::runtime_error("Core could not create the savestate");
    StateHeader header{};
    std::memcpy(header.magic, "MH4UST\0", 8); header.version = 1; header.headerSize = sizeof(header); header.payloadSize = payload.size();
    std::memcpy(header.coreSHA, coreIdentitySHA.data(), coreIdentitySHA.size());
    std::memcpy(header.configSHA, stateConfigSHA.data(), stateConfigSHA.size());
    auto payloadSHA = sha256(payload.data(), payload.size()); std::memcpy(header.payloadSHA, payloadSHA.data(), payloadSHA.size());
    std::snprintf(header.coreName, sizeof(header.coreName), "%s", coreIdentityName.c_str());
    std::snprintf(header.coreVersion, sizeof(header.coreVersion), "%s", coreIdentityVersion.c_str());
    auto target = statePath(slot); std::filesystem::create_directories(target.parent_path());
    std::string pattern = (target.parent_path() / ".slot.tmp.XXXXXX").string();
    std::vector<char> temporary(pattern.begin(), pattern.end()); temporary.push_back('\0');
    int fd = mkstemp(temporary.data());
    if (fd < 0) throw std::runtime_error("Cannot create temporary savestate");
    try {
        writeAll(fd, &header, sizeof(header)); writeAll(fd, payload.data(), payload.size());
        if (fsync(fd)) throw std::runtime_error("Cannot flush savestate to disk");
        if (close(fd)) { fd = -1; throw std::runtime_error("Cannot close savestate"); }
        fd = -1;
        if (rename(temporary.data(), target.c_str())) throw std::runtime_error("Cannot atomically replace savestate");
        int directory = open(target.parent_path().c_str(), O_RDONLY);
        if (directory < 0) throw std::runtime_error("Savestate replaced but its directory could not be opened for flushing");
        int directorySync = fsync(directory), directoryClose = close(directory);
        if (directorySync || directoryClose) throw std::runtime_error("Savestate replaced but its directory could not be flushed");
    } catch (...) { if (fd >= 0) close(fd); unlink(temporary.data()); throw; }
    ++stateSaves;
    fprintf(stderr, "Saved state slot %u (%llu bytes).\n", slot, (unsigned long long)payload.size());
}

static void loadState(unsigned slot) {
    if (!stateUnserialize) throw std::runtime_error("No game session is available to load");
    auto path = statePath(slot);
    std::error_code error;
    uintmax_t fileSize = std::filesystem::file_size(path, error);
    if (error) throw std::runtime_error("Savestate slot " + std::to_string(slot) + " does not exist");
    if (fileSize < sizeof(StateHeader) || fileSize > sizeof(StateHeader) + maxStateBytes) throw std::runtime_error("Savestate file is truncated or oversized");
    std::ifstream input(path, std::ios::binary);
    StateHeader header{}; input.read(reinterpret_cast<char *>(&header), sizeof(header));
    StateHeader expected{}; std::memcpy(expected.magic, "MH4UST\0", 8);
    std::snprintf(expected.coreName, sizeof(expected.coreName), "%s", coreIdentityName.c_str());
    std::snprintf(expected.coreVersion, sizeof(expected.coreVersion), "%s", coreIdentityVersion.c_str());
    if (!input || std::memcmp(header.magic, expected.magic, 8) || header.version != 1 || header.headerSize != sizeof(header) ||
        header.payloadSize != fileSize - sizeof(header) || header.payloadSize > maxStateBytes)
        throw std::runtime_error("Savestate header is invalid or incompatible");
    if (std::memcmp(header.coreSHA, coreIdentitySHA.data(), coreIdentitySHA.size()) ||
        std::memcmp(header.configSHA, stateConfigSHA.data(), stateConfigSHA.size()) ||
        std::memcmp(header.coreName, expected.coreName, sizeof(header.coreName)) ||
        std::memcmp(header.coreVersion, expected.coreVersion, sizeof(header.coreVersion)))
        throw std::runtime_error("Savestate was created by a different core build or runtime configuration");
    std::vector<uint8_t> payload(header.payloadSize); input.read(reinterpret_cast<char *>(payload.data()), payload.size());
    if (!input || input.peek() != EOF) throw std::runtime_error("Savestate payload is truncated or malformed");
    auto digest = sha256(payload.data(), payload.size());
    if (std::memcmp(header.payloadSHA, digest.data(), digest.size())) throw std::runtime_error("Savestate checksum does not match");
    bool resumeAudio = audioQueue && audioAccepting.load();
    if (resumeAudio) setAudioPaused(true);
    if (!stateUnserialize(payload.data(), payload.size())) { stopped = 1; throw std::runtime_error("Core rejected the savestate; restart the session before continuing"); }
    clearNativeInput();
    { std::lock_guard<std::mutex> lock(audioMutex); audioSamples.clear(); }
    { std::lock_guard<std::mutex> lock(temporalDepthMutex); temporalDepthReceived = false; temporalDepthColor.clear(); temporalDepth.clear(); }
    resetTemporalHistory(); pixels.clear(); videoWidth = videoHeight = 0; resetPacing = true;
    if (resumeAudio) setAudioPaused(false);
    ++stateLoads;
    fprintf(stderr, "Loaded state slot %u (%llu bytes).\n", slot, (unsigned long long)payload.size());
}

static std::vector<uint8_t> selfTestPayload{1, 3, 3, 7};
static bool selfTestSerializeSucceeds = true;
static unsigned selfTestUnserializeCalls = 0;
static size_t selfTestStateSize() { return selfTestPayload.size(); }
static bool selfTestSerialize(void *data, size_t size) {
    if (!selfTestSerializeSucceeds || size != selfTestPayload.size()) return false;
    std::memcpy(data, selfTestPayload.data(), size); return true;
}
static bool selfTestUnserialize(const void *data, size_t size) {
    ++selfTestUnserializeCalls;
    return size == selfTestPayload.size() && !std::memcmp(data, selfTestPayload.data(), size);
}

static int savestateSelfTest() {
    auto oldDir = stateDir; auto oldSize = stateSize; auto oldSerialize = stateSerialize; auto oldUnserialize = stateUnserialize;
    auto oldName = coreIdentityName; auto oldVersion = coreIdentityVersion; auto oldCoreSHA = coreIdentitySHA; auto oldConfigSHA = stateConfigSHA;
    struct Restore {
        std::string dir, name, version; decltype(stateSize) size; decltype(stateSerialize) serialize; decltype(stateUnserialize) unserialize;
        decltype(coreIdentitySHA) coreSHA, configSHA;
        ~Restore() { stateDir = dir; stateSize = size; stateSerialize = serialize; stateUnserialize = unserialize;
            coreIdentityName = name; coreIdentityVersion = version; coreIdentitySHA = coreSHA; stateConfigSHA = configSHA; }
    } restore{oldDir, oldName, oldVersion, oldSize, oldSerialize, oldUnserialize, oldCoreSHA, oldConfigSHA};
    auto base = std::filesystem::current_path() / ".local" / ("savestate-self-test-" + std::to_string(getpid()));
    std::filesystem::remove_all(base);
    auto check = [](bool condition, const char *message) { if (!condition) throw std::runtime_error(message); };
    auto read = [](const std::filesystem::path& path) {
        std::ifstream input(path, std::ios::binary);
        return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    };
    auto write = [](const std::filesystem::path& path, const std::vector<uint8_t>& bytes) {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        output.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
        if (!output) throw std::runtime_error("Savestate self-test could not write fixture");
    };
    try {
        stateDir = base.string(); stateSize = selfTestStateSize; stateSerialize = selfTestSerialize; stateUnserialize = selfTestUnserialize;
        coreIdentityName = "self-test-core"; coreIdentityVersion = "1"; coreIdentitySHA.fill(0x11); stateConfigSHA.fill(0x22);
        selfTestSerializeSucceeds = true; selfTestUnserializeCalls = 0; stopped = 0;
        saveState(1); auto valid = read(statePath(1)); loadState(1);
        check(selfTestUnserializeCalls == 1, "Savestate self-test roundtrip did not reach unserialize exactly once");
        selfTestSerializeSucceeds = false;
        bool failed = false; try { saveState(1); } catch (...) { failed = true; }
        check(failed && read(statePath(1)) == valid, "Failed serialization replaced the prior slot");
        selfTestSerializeSucceeds = true;
        auto reject = [&](std::vector<uint8_t> bytes, const char *message) {
            write(statePath(1), bytes); unsigned calls = selfTestUnserializeCalls; bool rejected = false;
            try { loadState(1); } catch (...) { rejected = true; }
            check(rejected && selfTestUnserializeCalls == calls && !stopped, message);
        };
        auto truncated = valid; truncated.pop_back(); reject(truncated, "Truncated savestate reached the core");
        auto corrupt = valid; corrupt.back() ^= 1; reject(corrupt, "Bad savestate checksum reached the core");
        auto wrongCore = valid; wrongCore[offsetof(StateHeader, coreSHA)] ^= 1; reject(wrongCore, "Wrong core metadata reached the core");
        auto wrongConfig = valid; wrongConfig[offsetof(StateHeader, configSHA)] ^= 1; reject(wrongConfig, "Wrong config metadata reached the core");
        std::filesystem::remove_all(base);
        puts("{\"mode\":\"savestate-self-test\",\"passed\":true,\"preflight_rejections\":4,\"prior_slot_preserved\":true}");
        return 0;
    } catch (...) { std::filesystem::remove_all(base); throw; }
}

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

static void captureProcessed(id<MTLTexture> texture, const std::string &path) {
    if (!texture) throw std::runtime_error("No processed image available for capture: " + path);
    const size_t row = (texture.width * 4 + 255) & ~size_t(255);
    id<MTLBuffer> buffer = [metalDevice newBufferWithLength:row * texture.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [metalQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(texture.width,texture.height,1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row * texture.height];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) throw std::runtime_error("Processed image readback failed");
    std::ofstream out(path, std::ios::binary);
    out << "P6\n" << texture.width << ' ' << texture.height << "\n255\n";
    for (NSUInteger y=0; y<texture.height; ++y) for (NSUInteger x=0; x<texture.width; ++x) {
        const auto *p = static_cast<const uint8_t *>(buffer.contents) + y * row + x * 4;
        const char rgb[] = {char(p[2]), char(p[1]), char(p[0])}; out.write(rgb, 3);
    }
    if (!out) throw std::runtime_error("Cannot write processed capture: " + path);
}

static int presentationSelfTest(uint64_t frames, const std::string &capturePath) {
    if (headless) throw std::runtime_error("--self-test requires a display");
    presentationTesting = true;
    lowerVisible = true;
    setupWindow();
    presentationTesting = false;
    [window orderOut:nil];
    const bool hiddenWindowSkipped = !canPresentWindow();
    presentationTesting = true;
    [window makeKeyAndOrderFront:nil];
    const uint8_t colors[4][4] = {{0, 0, 255, 255}, {0, 255, 0, 255}, {255, 0, 0, 255}, {255, 255, 255, 255}};
    const unsigned testWidth = 400 * resolutionFactor, testHeight = 480 * resolutionFactor;
    std::vector<uint8_t> pattern(size_t(testWidth) * testHeight * 4);
    const bool initialFx = fxEnabled;
    bool sawFxDisabled = false, sawFxRestored = !initialFx;
    for (unsigned y = 0; y < testHeight; ++y)
        for (unsigned x = 0; x < testWidth; ++x)
            std::memcpy(pattern.data() + (size_t(y) * testWidth + x) * 4,
                colors[(y >= testHeight / 2) * 2 + (x >= testWidth / 2)], 4);
    for (uint64_t i = 0; i < frames; ++i) {
        lowerVisible = i != 1; // Exercise the hidden overlay as well as both visible screens.
        // Exercise downscale fallback and return to upscaling after a resize.
        if (i == 1) [window setContentSize:NSMakeSize(120, 144)];
        if (i == 2) [window setContentSize:NSMakeSize(600, 720)];
        if (initialFx && i == 2) { fxEnabled = false; invalidateScaler(); }
        if (initialFx && i == 3) { fxEnabled = true; invalidateScaler(); }
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
        [NSApp updateWindows];
        updateControllerPointer(true, false, .5f, .5f);
        softwareVideo(pattern.data(), testWidth, testHeight, testWidth * 4);
        if (initialFx && i == 2) sawFxDisabled = scalerProperties == nil;
        if (initialFx && i >= 3) sawFxRestored = scalerProperties != nil;
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
    fxEnabled = initialFx;
    bool pixelPassed = true;
    bool passed = hiddenWindowSkipped && command.status == MTLCommandBufferStatusCompleted && presentedFrames == frames && compositePassed &&
        (!initialFx || frames < 4 || (sawFxDisabled && sawFxRestored));
    for (unsigned i = 0; i < 4; ++i)
        for (unsigned c = 0; c < 3; ++c)
            pixelPassed = pixelPassed && std::abs(int(static_cast<uint8_t *>(readback.contents)[i * 256 + c]) - colors[i][c]) <= 16;
    passed = passed && pixelPassed;
    if (!pixelPassed) {
        auto *actual = static_cast<uint8_t *>(readback.contents);
        fprintf(stderr, "Final texture readback mismatch: actual=[%u,%u,%u] [%u,%u,%u] [%u,%u,%u] [%u,%u,%u].\n",
            actual[0], actual[1], actual[2], actual[256], actual[257], actual[258],
            actual[512], actual[513], actual[514], actual[768], actual[769], actual[770]);
    }
    if (!capturePath.empty()) capture(capturePath);
    printf("{\"mode\":\"presentation-self-test\",\"passed\":%s,\"resolution_factor\":%u,\"width\":%u,\"height\":%u,\"presented_frames\":%llu,\"hidden_window_skipped\":%s,\"metal4_upscale_submissions\":%llu,\"metalfx_spatial_used\":%s,\"metalfx_toggle_restored\":%s,\"gpu_color_readback_passed\":%s}\n",
        passed ? "true" : "false", resolutionFactor, testWidth, testHeight, (unsigned long long)presentedFrames,
        hiddenWindowSkipped ? "true" : "false", (unsigned long long)metal4Submissions, fxUsed ? "true" : "false",
        sawFxRestored ? "true" : "false", pixelPassed ? "true" : "false");
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
        auto stick = [&](NSString *key, bool &present, int16_t (&axes)[2]) {
            id coordinates = item[key];
            if (!coordinates) return;
            if (![coordinates isKindOfClass:[NSArray class]] || [coordinates count] != 2)
                throw std::runtime_error(std::string("Input event ") + key.UTF8String + " must be [x,y] in [-1,1] (positive y is down)");
            present = true;
            for (unsigned i = 0; i < 2; ++i) {
                id number = coordinates[i];
                if (![number isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID())
                    throw std::runtime_error(std::string("Input ") + key.UTF8String + " coordinates must be numbers");
                double value = [number doubleValue];
                if (!std::isfinite(value) || value < -1 || value > 1)
                    throw std::runtime_error(std::string("Input ") + key.UTF8String + " coordinates must be in [-1,1]");
                axes[i] = std::lround(value * 32767);
            }
        };
        stick(@"circle", event.hasCircle, event.circle);
        stick(@"cstick", event.hasCStick, event.cstick);
        replay.push_back(event);
    }
}

static void applyReplay(uint64_t frame) {
    replayButtons = 0;
    replayHasCircle = false;
    replayHasCStick = false;
    bool active = false;
    for (const auto &event : replay) {
        if (frame >= event.frame && frame - event.frame < event.duration) {
            active = true;
            replayButtons |= event.buttons;
            if (event.hasCircle) {
                replayHasCircle = true;
                std::copy(std::begin(event.circle), std::end(event.circle), replayCircle);
            }
            if (event.hasCStick) {
                replayHasCStick = true;
                std::copy(std::begin(event.cstick), std::end(event.cstick), replayCStick);
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
            std::string game = ".local/game/main.cxi", cpu = "jit", capturePath, inputScript, renderer = "vulkan", texturePack, importSave;
            std::string vulkanLibrary = ".local/vulkan/libMoltenVK.dylib";
            corePath = ".local/core-vulkan-build/bin/Release/azahar_libretro.dylib";
            stateDir = ".local/state";
            if (workspace.length) {
                NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
                stateDir = [support stringByAppendingPathComponent:@"MH4U Runtime/.local/state"].fileSystemRepresentation;
            }
            uint64_t frameLimit = 0, windowStartFrame = 0;
            std::vector<ResolutionChange> resolutionChanges;
            std::vector<StateAction> stateSaveActions, stateLoadActions;
            bool audioEnabled = true, selfTest = false, testInput = false, testMenu = false, testVideo = false, testAudio = false, testTextures = false, testSavestates = false, settingsPreview = false, texturesPreview = false, dumpTextures = false;
            bool stateDirExplicit = false, testSaveImport = false, saveImportPreview = false;
            for (int i = 1; i < argc; ++i) {
                std::string arg = argv[i];
                auto value = [&]() -> std::string { if (++i >= argc) throw std::runtime_error("Missing value for " + arg); return argv[i]; };
                if (arg == "--core") corePath = value();
                else if (arg == "--renderer") renderer = value();
                else if (arg == "--vulkan-library") vulkanLibrary = value();
                else if (arg == "--game") game = value();
                else if (arg == "--state-dir") { stateDir = value(); stateDirExplicit = true; }
                else if (arg == "--texture-pack") texturePack = value();
                else if (arg == "--custom-textures") { customTextures = true; customTexturesOverride = true; }
                else if (arg == "--no-custom-textures") { customTextures = false; customTexturesOverride = true; }
                else if (arg == "--old-3ds") { old3DS = true; systemProfileOverride = true; }
                else if (arg == "--new-3ds") { old3DS = false; systemProfileOverride = true; }
                else if (arg == "--dump-textures") dumpTextures = true;
                else if (arg == "--cpu") cpu = value();
                else if (arg == "--capture") capturePath = value();
                else if (arg == "--input-script") inputScript = value();
                else if (arg == "--savestate-save" || arg == "--savestate-load") {
                    std::string action = value(); size_t colon = action.find(':');
                    std::string frame = action.substr(0, colon), slot = colon == std::string::npos ? "" : action.substr(colon + 1);
                    if (colon == std::string::npos || action.find(':', colon + 1) != std::string::npos || frame.empty() ||
                        frame.find_first_not_of("0123456789") != std::string::npos || slot.size() != 1 || slot[0] < '1' || slot[0] > '9')
                        throw std::runtime_error(arg + " requires FRAME:SLOT with SLOT from 1 to 9");
                    (arg == "--savestate-save" ? stateSaveActions : stateLoadActions).push_back({std::stoull(frame), unsigned(slot[0] - '0')});
                }
                else if (arg == "--resolution") {
                    std::string scale = value();
                    if (scale.size() != 1 || scale[0] < '1' || scale[0] > '4')
                        throw std::runtime_error("--resolution must be 1, 2, 3, or 4");
                    resolutionFactor = scale[0] - '0';
                    resolutionCommandLineOverride = true;
                }
                else if (arg == "--resolution-change") {
                    std::string change = value();
                    size_t colon = change.find(':');
                    std::string frame = change.substr(0, colon), scale = colon == std::string::npos ? "" : change.substr(colon + 1);
                    if (colon == std::string::npos || change.find(':', colon + 1) != std::string::npos || frame.empty() ||
                        frame.find_first_not_of("0123456789") != std::string::npos || scale.size() != 1 || scale[0] < '1' || scale[0] > '4')
                        throw std::runtime_error("--resolution-change requires FRAME:SCALE with SCALE from 1 to 4");
                    resolutionChanges.push_back({std::stoull(frame), unsigned(scale[0] - '0')});
                }
                else if (arg == "--frames") {
                    std::string n = value();
                    if (n.empty() || n.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("--frames requires a positive integer");
                    frameLimit = std::stoull(n);
                    if (!frameLimit) throw std::runtime_error("--frames must be greater than zero");
                }
                else if (arg == "--window-start") {
                    std::string n = value();
                    if (n.empty() || n.find_first_not_of("0123456789") != std::string::npos)
                        throw std::runtime_error("--window-start requires a positive frame index");
                    windowStartFrame = std::stoull(n);
                    if (!windowStartFrame) throw std::runtime_error("--window-start requires a positive frame index");
                }
                else if (arg == "--headless") headless = true;
                else if (arg == "--no-audio") audioEnabled = false;
                else if (arg == "--no-metalfx") { fxEnabled = false; fxCommandLineOverride = true; }
                else if (arg == "--experimental-temporal") { temporalEnabled = true; temporalOverride = true; }
                else if (arg == "--experimental-frame-generation") { temporalEnabled = generationEnabled = true; temporalOverride = true; }
                else if (arg == "--no-temporal") { temporalEnabled = generationEnabled = false; temporalOverride = true; }
                else if (arg == "--temporal-start") {
                    std::string n = value();
                    if (n.empty() || n.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("--temporal-start requires a nonnegative frame index");
                    temporalStartFrame = std::stoull(n);
                }
                else if (arg == "--temporal-capture") temporalCapturePath = value();
                else if (arg == "--no-metal4") metal4Enabled = false;
                else if (arg == "--self-test") selfTest = true;
                else if (arg == "--input-self-test") testInput = true;
                else if (arg == "--menu-tracking-self-test") testMenu = true;
                else if (arg == "--video-self-test") testVideo = true;
                else if (arg == "--audio-self-test") testAudio = true;
                else if (arg == "--texture-pack-self-test") testTextures = true;
                else if (arg == "--savestate-self-test") testSavestates = true;
                else if (arg == "--save-import-self-test") testSaveImport = true;
                else if (arg == "--import-save") { importSave = value(); if (importSave.empty()) throw std::runtime_error("--import-save requires a source path"); }
                else if (arg == "--save-import-preview") saveImportPreview = true;
                else if (arg == "--settings-preview") settingsPreview = true;
                else if (arg == "--textures-preview") texturesPreview = true;
                else if (arg == "--help") {
                    puts("MH4U Runtime --core PATH --game PATH [--cpu jit|interpreter] [--renderer software|vulkan] [--vulkan-library PATH] [--state-dir DIR] [--texture-pack DIR] [--custom-textures|--no-custom-textures] [--old-3ds|--new-3ds] [--dump-textures] [--headless --frames N] [--window-start FRAME] [--capture FRAME.ppm] [--input-script EVENTS.json] [--savestate-save FRAME:SLOT ...] [--savestate-load FRAME:SLOT ...] [--resolution 1|2|3|4] [--resolution-change FRAME:SCALE ...] [--experimental-temporal|--experimental-frame-generation|--no-temporal] [--temporal-start FRAME] [--temporal-capture PREFIX] [--no-audio] [--no-metalfx] [--no-metal4]\nMH4U Runtime --self-test [--frames N] [--resolution 1|2|3|4] [--no-metal4] [--no-metalfx]\nMH4U Runtime --input-self-test\nMH4U Runtime --menu-tracking-self-test\nMH4U Runtime --video-self-test\nMH4U Runtime --audio-self-test\nMH4U Runtime --texture-pack-self-test\nMH4U Runtime --savestate-self-test\nMH4U Runtime --save-import-self-test\nMH4U Runtime --import-save PATH --state-dir DIR\nMH4U Runtime --save-import-preview --state-dir DIR\nMH4U Runtime --settings-preview\nMH4U Runtime --textures-preview [--state-dir DIR]");
                    return 0;
                } else throw std::runtime_error("Unknown option: " + arg);
            }
            if (cpu != "jit" && cpu != "interpreter") throw std::runtime_error("--cpu must be jit or interpreter");
            if (renderer != "software" && renderer != "vulkan") throw std::runtime_error("--renderer must be software or vulkan");
            if (dumpTextures && (!stateDirExplicit || !frameLimit)) throw std::runtime_error("--dump-textures requires explicit --state-dir DIR and --frames N");
            if (!resolutionChanges.empty()) {
                if (!frameLimit) throw std::runtime_error("--resolution-change requires --frames");
                for (const auto &change : resolutionChanges)
                    if (change.frame >= frameLimit) throw std::runtime_error("--resolution-change frame must be less than --frames");
                std::stable_sort(resolutionChanges.begin(), resolutionChanges.end(),
                    [](const auto &a, const auto &b) { return a.frame < b.frame; });
            }
            if (!stateSaveActions.empty() || !stateLoadActions.empty()) {
                if (!stateDirExplicit || !frameLimit) throw std::runtime_error("Savestate CLI actions require explicit --state-dir DIR and --frames N");
                auto validateActions = [&](std::vector<StateAction>& actions) {
                    for (const auto& action : actions) if (action.frame >= frameLimit)
                        throw std::runtime_error("Savestate action frame must be less than --frames");
                    std::stable_sort(actions.begin(), actions.end(), [](const auto& a, const auto& b) { return a.frame < b.frame; });
                };
                validateActions(stateSaveActions); validateActions(stateLoadActions);
            }
            if (!selfTest) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                if (!resolutionCommandLineOverride && [defaults objectForKey:@"InternalResolutionFactor"])
                    resolutionFactor = std::clamp<NSInteger>([defaults integerForKey:@"InternalResolutionFactor"], 1, 4);
                if (!temporalOverride) {
                    temporalEnabled = [defaults boolForKey:@"ExperimentalTemporalEnabled"];
                    generationEnabled = temporalEnabled && [defaults boolForKey:@"ExperimentalFlowGenerationEnabled"];
                }
                if (!customTexturesOverride) customTextures = [defaults boolForKey:@"CustomTexturesEnabled"];
                if (!systemProfileOverride) old3DS = [defaults boolForKey:@"UseOld3DSProfile"];
            }
            if (temporalStartFrame && (!frameLimit || temporalStartFrame >= frameLimit || !temporalEnabled))
                throw std::runtime_error("--temporal-start requires temporal mode and a larger --frames limit");
            if (!temporalCapturePath.empty() && (!frameLimit || !stateDirExplicit || !temporalEnabled))
                throw std::runtime_error("--temporal-capture requires temporal mode, explicit --state-dir and --frames");
            if (!temporalCapturePath.empty()) {
                auto path = std::filesystem::weakly_canonical(std::filesystem::absolute(temporalCapturePath));
                if (path.string().find("/.local/") == std::string::npos)
                    throw std::runtime_error("--temporal-capture must be inside a private .local directory");
                temporalCapturePath = path.string();
            }
            if (temporalEnabled) {
                if (renderer != "vulkan") throw std::runtime_error("Experimental temporal mode requires Vulkan");
            }
            useVulkan = renderer == "vulkan";
            if (testInput) return inputSelfTest();
            if (testMenu) return menuTrackingSelfTest();
            if (testVideo) return videoSelfTest();
            if (testAudio) return audioSelfTest();
            if (testTextures) { TexturePack::selfTest(); packConfigSelfTest(); puts("{\"mode\":\"texture-pack-self-test\",\"passed\":true}"); return 0; }
            if (testSavestates) return savestateSelfTest();
            if (testSaveImport) return SaveImport::selfTest();
            if (!importSave.empty() || saveImportPreview) {
                if (!stateDirExplicit) throw std::runtime_error("Save import CLI requires explicit --state-dir DIR");
                if ((!importSave.empty() && saveImportPreview) || frameLimit || headless || !stateSaveActions.empty() || !stateLoadActions.empty())
                    throw std::runtime_error("Save import CLI stages files only; run the game separately to apply them");
                stateDir = std::filesystem::absolute(stateDir).string();
                SaveImport::StateLock lock(stateDir); saveImportAvailable = true;
                if (saveImportPreview) {
                    setupWindow(); [runtimeMenuTarget importGameSave:nil];
                    puts("{\"mode\":\"save-import-preview\",\"game_loaded\":false}");
                } else {
                    auto result = SaveImport::stage(importSave, stateDir);
                    printf("{\"mode\":\"save-import\",\"pending\":true,\"files\":%zu,\"bytes\":%llu}\n", result.files.size(), (unsigned long long)result.bytes);
                }
                return 0;
            }
            if (settingsPreview) {
                setupWindow();
                [runtimeMenuTarget showGraphics:nil];
                puts("{\"mode\":\"settings-preview\",\"game_loaded\":false}");
                return 0;
            }
            if (texturesPreview) {
                stateDir = std::filesystem::absolute(stateDir).string();
                setupWindow();
                [runtimeMenuTarget showTextures:nil];
                puts("{\"mode\":\"textures-preview\",\"game_loaded\":false}");
                return 0;
            }
            if (!inputScript.empty()) loadReplay(inputScript);
            if (selfTest) return presentationSelfTest(frameLimit ? frameLimit : 5, capturePath);
            if (windowStartFrame) {
                if (headless || !frameLimit || windowStartFrame >= frameLimit)
                    throw std::runtime_error("--window-start requires a larger --frames limit and cannot be combined with --headless");
                headless = true;
            }
            if (headless && !frameLimit) throw std::runtime_error("--headless requires --frames N");
            if (!std::filesystem::is_regular_file(game)) throw std::runtime_error("Game file does not exist: " + game);
            validateGame(game);
            corePath = std::filesystem::absolute(corePath).string();
            game = std::filesystem::absolute(game).string();
            stateDir = std::filesystem::absolute(stateDir).string();
            std::filesystem::create_directories(stateDir);
            SaveImport::StateLock stateLock(stateDir); saveImportAvailable = true;
            auto saveBackup = SaveImport::activatePending(stateDir);
            if (!saveBackup.empty()) fprintf(stderr, "Imported game saves; backup: %s\n", saveBackup.c_str());
            if (TexturePack::activatePending(stateDir)) fprintf(stderr, "Activated the staged European MH4U texture pack.\n");
            if (!texturePack.empty()) {
                validatePackConfig(texturePack);
                TexturePack::InstallResult installed = TexturePack::install(texturePack, stateDir);
                fprintf(stderr, "Installed %llu custom-texture files (%llu bytes).\n", (unsigned long long)installed.files, (unsigned long long)installed.bytes);
                if (!customTexturesOverride) customTextures = true;
            }
            options = {
                {"citra_graphics_api", useVulkan ? "Vulkan" : "Software"}, {"citra_use_cpu_jit", cpu == "jit" ? "enabled" : "disabled"},
                {"citra_use_shader_jit", "enabled"}, {"citra_resolution_factor", std::to_string(resolutionFactor)},
                {"citra_layout_option", "default"}, {"citra_is_new_3ds", old3DS ? "Old 3DS" : "New 3DS"},
                {"citra_custom_textures", customTextures ? "enabled" : "disabled"},
                {"citra_dump_textures", dumpTextures ? "enabled" : "disabled"},
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
            else if (temporalEnabled) { metalDevice = MTLCreateSystemDefaultDevice(); metalQueue = [metalDevice newCommandQueue]; }
            if (temporalEnabled) warmMotion();
            core.init(); core.initialized = true;
            retro_system_info info{}; core.get_system_info(&info);
            coreIdentityName = info.library_name ? info.library_name : "";
            coreIdentityVersion = info.library_version ? info.library_version : "";
            coreIdentitySHA = sha256File(corePath);
            std::string stateConfig = "cpu=" + cpu + "\nrenderer=" + renderer + "\nsystem=" + options.at("citra_is_new_3ds") +
                "\naudio=" + options.at("citra_audio_emulation") + "\n";
            stateConfigSHA = sha256(stateConfig.data(), stateConfig.size());
            fprintf(stderr, "Core: %s %s; CPU %s; requested PICA renderer %s; state %s\n", info.library_name, info.library_version, cpu.c_str(), renderer.c_str(), stateDir.c_str());
            if (!info.need_fullpath) throw std::runtime_error("This host requires a core accepting full game paths");
            retro_game_info gameInfo{game.c_str(), nullptr, 0, nullptr};
            if (!core.load_game(&gameInfo)) throw std::runtime_error("Core rejected the supplied game; see core diagnostics above");
            core.loaded = true;
            stateSize = core.serialize_size; stateSerialize = core.serialize; stateUnserialize = core.unserialize;
            if (useVulkan) VulkanBridge::initialize(std::filesystem::absolute(vulkanLibrary).string());
            core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
            retro_system_av_info av{}; core.get_system_av_info(&av); geometry = av.geometry;
            if (!std::isfinite(av.timing.fps) || av.timing.fps <= 0 || av.timing.fps > 1000) throw std::runtime_error("Invalid core frame rate");
            nativeFrameSeconds = 1.0 / av.timing.fps;
            if (!headless && audioEnabled) startAudio(av.timing.sample_rate);
            auto start = std::chrono::steady_clock::now();
            auto previous = start;
            auto nextFrame = start;
            uint64_t runs = 0, frameOverruns = 0, pacedFrames = 0;
            size_t resolutionTransitionIndex = 0;
            size_t stateSaveIndex = 0, stateLoadIndex = 0;
            double coreSeconds = 0, eventSeconds = 0, sleepSeconds = 0, maxFrameWorkSeconds = 0;
            double pacedElapsedSeconds = 0, pacedCoreSeconds = 0, pacedPresentationSeconds = 0;
            double pacedEventSeconds = 0, pacedSleepSeconds = 0, maxPacedFrameWorkSeconds = 0;
            const auto framePeriod = std::chrono::microseconds(int64_t(1000000.0 / av.timing.fps));
            uint64_t menuTrackingFrames = 0;
            auto runFrame = [&](bool duringMenu, std::chrono::steady_clock::time_point frameStart, double eventDelta) {
                if (stopped || (frameLimit && runs >= frameLimit)) return false;
                auto now = std::chrono::steady_clock::now();
                if (resetPacing) { previous = nextFrame = now; resetPacing = false; resetTemporalHistory(); }
                if (runtimePaused()) { previous = nextFrame = now; return false; }
                const bool pacedFrame = !headless;
                if (frameTime.callback) frameTime.callback(runs ? std::chrono::duration_cast<std::chrono::microseconds>(now - previous).count() : frameTime.reference);
                previous = now;
                applyReplay(runs);
                while (resolutionTransitionIndex < resolutionChanges.size() && resolutionChanges[resolutionTransitionIndex].frame == runs) {
                    const auto &change = resolutionChanges[resolutionTransitionIndex++];
                    setResolutionFactor(change.scale, false);
                    fprintf(stderr, "Internal resolution change at frame %llu: %ux.\n",
                        (unsigned long long)change.frame, change.scale);
                }
                currentRunIndex = runs;
                while (stateLoadIndex < stateLoadActions.size() && stateLoadActions[stateLoadIndex].frame == runs)
                    loadState(stateLoadActions[stateLoadIndex++].slot);
                auto coreStart = std::chrono::steady_clock::now();
                double presentationBefore = presentationSeconds;
                {
                    std::lock_guard<std::mutex> lock(temporalDepthMutex);
                    temporalDepthReceived = false;
                }
                core.run(); ++runs;
                while (stateSaveIndex < stateSaveActions.size() && stateSaveActions[stateSaveIndex].frame + 1 == runs)
                    saveState(stateSaveActions[stateSaveIndex++].slot);
                auto workEnd = std::chrono::steady_clock::now();
                const double presentationDelta = presentationSeconds - presentationBefore;
                const double coreDelta = std::chrono::duration<double>(workEnd - coreStart).count() - presentationDelta;
                const double workDelta = std::chrono::duration<double>(workEnd - frameStart).count();
                coreSeconds += coreDelta;
                maxFrameWorkSeconds = std::max(maxFrameWorkSeconds, workDelta);
                finishInputFrame();
                double sleepDelta = 0;
                if (!headless && workEnd - frameStart > framePeriod) ++frameOverruns;
                if (!headless && !duringMenu) {
                    nextFrame += framePeriod;
                    // Include Cocoa work and reclaim sleep drift; discard long-stall backlog.
                    if (workEnd - nextFrame > framePeriod) nextFrame = workEnd;
                    auto sleepStart = std::chrono::steady_clock::now();
                    std::this_thread::sleep_until(nextFrame);
                    sleepDelta = std::chrono::duration<double>(std::chrono::steady_clock::now() - sleepStart).count();
                    sleepSeconds += sleepDelta;
                }
                if (pacedFrame) {
                    ++pacedFrames;
                    pacedCoreSeconds += coreDelta;
                    pacedPresentationSeconds += presentationDelta;
                    pacedEventSeconds += eventDelta;
                    pacedSleepSeconds += sleepDelta;
                    pacedElapsedSeconds += duringMenu ? menuTrackingTickSeconds :
                        std::chrono::duration<double>(std::chrono::steady_clock::now() - frameStart).count();
                    maxPacedFrameWorkSeconds = std::max(maxPacedFrameWorkSeconds, workDelta);
                }
                if (duringMenu) ++menuTrackingFrames;
                return true;
            };
            installMenuTrackingFrames(nativeFrameSeconds, [&] {
                auto frameStart = std::chrono::steady_clock::now();
                runFrame(true, frameStart, 0);
                if (stopped || (frameLimit && runs >= frameLimit)) cancelTrackedMenu();
            });
            try {
            while (!stopped && (!frameLimit || runs < frameLimit)) {
                @autoreleasepool {
                    if (headless && windowStartFrame && runs >= windowStartFrame) {
                        headless = false; setupWindow();
                        if (audioEnabled) startAudio(av.timing.sample_rate);
                        resetPacing = true;
                    }
                    auto eventStart = std::chrono::steady_clock::now();
                    const double menuSecondsBefore = menuTrackingNestedSeconds;
                    if (!headless) {
                        NSEvent *event;
                        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
                        [NSApp updateWindows];
                    }
                    if (menuTrackingFailure) {
                        auto trackingFailure = menuTrackingFailure;
                        uninstallMenuTrackingFrames();
                        std::rethrow_exception(trackingFailure);
                    }
                    if (stopped) break;
                    auto now = std::chrono::steady_clock::now();
                    const double nestedMenuDelta = menuTrackingNestedSeconds - menuSecondsBefore;
                    const double eventDelta = std::max(0.0, std::chrono::duration<double>(now - eventStart).count() - nestedMenuDelta);
                    const auto frameStart = eventStart + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(nestedMenuDelta));
                    eventSeconds += eventDelta;
                    if (!runFrame(false, frameStart, eventDelta) && runtimePaused()) {
                        previous = nextFrame = std::chrono::steady_clock::now();
                        std::this_thread::sleep_for(std::chrono::milliseconds(8));
                    }
                }
            }
            } catch (...) {
                uninstallMenuTrackingFrames();
                throw;
            }
            uninstallMenuTrackingFrames();
            double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            stopAudio();
            if (!failure.empty()) throw std::runtime_error(failure);
            if (!capturePath.empty()) capture(capturePath);
            uint64_t hash = 14695981039346656037ULL;
            for (uint8_t byte : pixels) { hash ^= byte; hash *= 1099511628211ULL; }
            NSMutableArray *requestedResolutionChanges = [NSMutableArray array];
            for (const auto &change : resolutionChanges)
                [requestedResolutionChanges addObject:@{@"frame": @(change.frame), @"scale": @(change.scale)}];
            NSMutableArray *actualDimensionChanges = [NSMutableArray array];
            for (const auto &change : dimensionChanges)
                [actualDimensionChanges addObject:@{@"frame": @(change.frame), @"width": @(change.width), @"height": @(change.height)}];
            NSMutableArray *temporalScaleResults = [NSMutableArray array];
            for (unsigned scale = 1; scale <= 4; ++scale) {
                const auto &v = temporalScales[scale];
                [temporalScaleResults addObject:@{@"scale": @(scale), @"temporal_frames": @(v.frames),
                    @"generated_frames": @(v.generated), @"generated_presentations": @(v.presented),
                    @"fallback_frames": @(v.fallback), @"depth_callbacks": @(v.depthCallbacks),
                    @"first_depth_min": @(v.firstDepthMin), @"first_depth_max": @(v.firstDepthMax),
                    @"first_depth_subpixel_differences": @(v.firstDepthSubpixelDifferences),
                    @"input_width": @(v.inputWidth), @"input_height": @(v.inputHeight),
                    @"output_width": @(v.outputWidth), @"output_height": @(v.outputHeight)}];
            }
            NSDictionary *result = @{
                @"runtime": @"MH4U Runtime", @"cpu": @(cpu.c_str()),
                @"network_policy": @"deny network*",
                @"input_script_events": @(replay.size()), @"input_replay_frames": @(replayFrames),
                @"pica_renderer": @(renderer.c_str()), @"presenter": headless ? @"none" : @"Metal",
                @"custom_textures": @(options.at("citra_custom_textures") == "enabled"),
                @"system_profile": @(options.at("citra_is_new_3ds").c_str()),
                @"dump_textures": @(dumpTextures),
                @"vulkan_device": @(VulkanBridge::deviceName().c_str()),
                @"vulkan_readback_frames": @(VulkanBridge::readbackFrames()),
                @"vulkan_readback_seconds": @(VulkanBridge::readbackSeconds()),
                @"temporal_scales": temporalScaleResults,
                @"temporal_core_available": @(temporalCoreAvailable), @"temporal_requested": @(temporalEnabled),
                @"temporal_frames": @(temporalFrames), @"temporal_depth_callbacks": @(temporalDepthFrames),
                @"temporal_fallback_frames": @(temporalFallbackFrames), @"temporal_duplicate_frames": @(temporalDuplicateFrames),
                @"temporal_reset_frames": @(temporalResetFrames), @"temporal_alignment_rejected": @(temporalAlignmentRejected),
                @"temporal_processing_seconds": @(temporalSeconds), @"motion_estimation_seconds": @(motionSeconds),
                @"generated_frames": @(generatedFrames), @"generated_presentations": @(generatedPresentations),
                @"generation_method": @"estimated optical flow; not MetalFX frame interpolation",
                @"temporal_status": @(temporalStatus.c_str()),
                @"metalfx_spatial_used": @(fxUsed), @"retro_run_calls": @(runs),
                @"menu_tracking_frames": @(menuTrackingFrames),
                @"menu_tracking_seconds": @(menuTrackingNestedSeconds),
                @"menu_tracking_max_tick_seconds": @(menuTrackingMaxTickSeconds),
                @"savestate_saves": @(stateSaves), @"savestate_loads": @(stateLoads),
                @"requested_resolution_factor": @(resolutionFactor),
                @"requested_resolution_changes": requestedResolutionChanges,
                @"actual_dimension_changes": actualDimensionChanges,
                @"metal4_upscale_submissions": @(metal4Submissions),
                @"video_frames": @(videoFrames), @"nonblack_frames": @(nonblackFrames),
                @"presented_frames": @(presentedFrames), @"audio_sample_frames": @(audioFrames.load()),
                @"audio_output_callbacks": @(audioCallbacks.load()), @"audio_consumed_frames": @(audioConsumedFrames.load()),
                @"audio_queue_errors": @(audioQueueFailures.load()),
                @"audio_underrun_events": @(audioUnderrunEvents.load()), @"audio_underrun_frames": @(audioUnderrunFrames.load()),
                @"audio_recovery_events": @(audioRecoveryEvents.load()), @"audio_dropped_frames": @(audioDroppedFrames.load()),
                @"audio_queue_high_water_frames": @(audioQueueHighWaterFrames.load()),
                @"audio_source_gap_max_ms": @(double(audioSourceGapMaxMicros.load()) / 1000.0),
                @"core_run_excluding_presentation_seconds": @(coreSeconds),
                @"presentation_seconds": @(presentationSeconds), @"event_pump_seconds": @(eventSeconds),
                @"pacing_sleep_seconds": @(sleepSeconds), @"frame_work_overruns": @(frameOverruns),
                @"max_frame_work_seconds": @(maxFrameWorkSeconds), @"target_fps": @(av.timing.fps),
                @"paced_frames": @(pacedFrames), @"paced_elapsed_seconds": @(pacedElapsedSeconds),
                @"paced_core_run_excluding_presentation_seconds": @(pacedCoreSeconds),
                @"paced_presentation_seconds": @(pacedPresentationSeconds),
                @"paced_event_pump_seconds": @(pacedEventSeconds), @"paced_sleep_seconds": @(pacedSleepSeconds),
                @"max_paced_frame_work_seconds": @(maxPacedFrameWorkSeconds),
                @"elapsed_seconds": @(elapsed), @"width": @(videoWidth), @"height": @(videoHeight),
                @"final_frame_fnv1a64": [NSString stringWithFormat:@"%016llx", (unsigned long long)hash],
                @"frame_limit_reached": @(frameLimit && runs == frameLimit)
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
            if (!temporalCapturePath.empty()) {
                captureProcessed(temporalOutput, temporalCapturePath + "-temporal.ppm");
                if (lastGeneratedOutput) captureProcessed(lastGeneratedOutput, temporalCapturePath + "-generated.ppm");
            }
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
