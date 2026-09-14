#import "controller_config.h"

#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#include <libretro.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>

@interface MH4UControllerMenuTarget : NSObject
@property(nonatomic, strong) NSMenuItem *fullscreenItem;
@property(nonatomic, strong) NSMenuItem *lowerItem;
- (void)showController:(id)sender;
- (void)toggleFullscreen:(id)sender;
- (void)toggleLowerScreen:(id)sender;
@end

namespace ControllerConfig {
namespace {

NSString *const kMappings = @"ControllerMappings";
NSString *const kCircleStick = @"ControllerCircleStick";
NSString *const kCStick = @"ControllerCStick";
NSString *const kHostToggle = @"ControllerLowerScreenToggle";
NSString *const kFullscreen = @"FullscreenPreferred";
NSString *const kLowerVisible = @"LowerScreenVisible";

struct Action { const char *name; unsigned retroId; const char *fallback; };
constexpr Action actions[] = {
    {"A", RETRO_DEVICE_ID_JOYPAD_A, "circle"}, {"B", RETRO_DEVICE_ID_JOYPAD_B, "cross"},
    {"X", RETRO_DEVICE_ID_JOYPAD_X, "triangle"}, {"Y", RETRO_DEVICE_ID_JOYPAD_Y, "square"},
    {"L", RETRO_DEVICE_ID_JOYPAD_L, "l1"}, {"R", RETRO_DEVICE_ID_JOYPAD_R, "r1"},
    {"ZL", RETRO_DEVICE_ID_JOYPAD_L2, "l2"}, {"ZR", RETRO_DEVICE_ID_JOYPAD_R2, "r2"},
    {"Start", RETRO_DEVICE_ID_JOYPAD_START, "options"},
    {"Select", RETRO_DEVICE_ID_JOYPAD_SELECT, "create"},
    {"D-pad Up", RETRO_DEVICE_ID_JOYPAD_UP, "up"},
    {"D-pad Down", RETRO_DEVICE_ID_JOYPAD_DOWN, "down"},
    {"D-pad Left", RETRO_DEVICE_ID_JOYPAD_LEFT, "left"},
    {"D-pad Right", RETRO_DEVICE_ID_JOYPAD_RIGHT, "right"},
};

struct Physical { const char *key; const char *label; };
constexpr Physical physical[] = {
    {"none", "None"}, {"cross", "Cross"}, {"circle", "Circle"},
    {"square", "Square"}, {"triangle", "Triangle"}, {"l1", "L1"},
    {"r1", "R1"}, {"l2", "L2"}, {"r2", "R2"}, {"options", "Options"},
    {"create", "Create"}, {"l3", "L3"}, {"r3", "R3"},
    {"up", "D-pad Up"}, {"down", "D-pad Down"},
    {"left", "D-pad Left"}, {"right", "D-pad Right"},
    {"touchpad", "Touchpad Click"},
};

bool settingsIsOpen = false;
bool releaseGate = true;
bool lastHostPressed = false;
__weak GCController *lastController = nil;
TouchCursor currentTouchCursor;
struct TouchDeltaState {
    bool tracking = false;
    float x = 0.f;
    float y = 0.f;
} touchDelta;
void (*toggleLowerCallback)() = nullptr;
void (*fullscreenCallback)(bool) = nullptr;
void (*settingsCallback)(bool) = nullptr;
NSWindow *ownerWindow = nil;

NSString *str(const char *s) { return [NSString stringWithUTF8String:s]; }

NSDictionary *storedMappings() {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kMappings];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

const char *mappingFor(const Action &action, NSDictionary *mappings) {
    id value = mappings[str(action.name)];
    if (![value isKindOfClass:NSString.class]) return action.fallback;
    for (const auto &item : physical)
        if ([(NSString *)value isEqualToString:str(item.key)]) return item.key;
    return action.fallback;
}

GCControllerButtonInput *buttonFor(GCExtendedGamepad *pad, const char *key) {
    if (!strcmp(key, "cross")) return pad.buttonA;
    if (!strcmp(key, "circle")) return pad.buttonB;
    if (!strcmp(key, "square")) return pad.buttonX;
    if (!strcmp(key, "triangle")) return pad.buttonY;
    if (!strcmp(key, "l1")) return pad.leftShoulder;
    if (!strcmp(key, "r1")) return pad.rightShoulder;
    if (!strcmp(key, "l2")) return pad.leftTrigger;
    if (!strcmp(key, "r2")) return pad.rightTrigger;
    if (!strcmp(key, "options")) return pad.buttonMenu;
    if (!strcmp(key, "create")) return pad.buttonOptions;
    if (!strcmp(key, "l3")) return pad.leftThumbstickButton;
    if (!strcmp(key, "r3")) return pad.rightThumbstickButton;
    if (!strcmp(key, "up")) return pad.dpad.up;
    if (!strcmp(key, "down")) return pad.dpad.down;
    if (!strcmp(key, "left")) return pad.dpad.left;
    if (!strcmp(key, "right")) return pad.dpad.right;
    if (!strcmp(key, "touchpad") && [pad respondsToSelector:NSSelectorFromString(@"touchpadButton")])
        return [pad valueForKey:@"touchpadButton"];
    return nil;
}

const char *validatedChoice(NSString *key, const char *fallback, const Physical *items,
                            size_t count) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([value isKindOfClass:NSString.class])
        for (size_t i = 0; i < count; ++i)
            if ([(NSString *)value isEqualToString:str(items[i].key)]) return items[i].key;
    return fallback;
}

float axis(float value) { return std::abs(value) < .12f ? 0.f : value; }
int16_t scaled(float value) { return static_cast<int16_t>(std::clamp(axis(value), -1.f, 1.f) * 32767.f); }

bool hostEdge(bool enabled, bool anyPhysicalPressed, bool hostPressed, bool &gate, bool &last) {
    if (!enabled) { gate = true; last = false; return false; }
    if (gate) {
        last = hostPressed;
        if (anyPhysicalPressed) return false;
        gate = false;
        last = false;
        return false;
    }
    bool edge = hostPressed && !last;
    last = hostPressed;
    return edge;
}

bool gameplayPress(bool pressed, bool isHostControl) { return pressed && !isHostControl; }

TouchCursor cursorSample(TouchCursor cursor, TouchDeltaState &delta, bool available, bool touching,
                         float x, float y, bool clickAllowed, bool r3Pressed) {
    cursor.available = available;
    cursor.pressed = available && clickAllowed && r3Pressed;
    if (!available || !touching) {
        delta.tracking = false;
        return cursor;
    }
    if (!delta.tracking) {
        delta = {true, x, y};
        return cursor;
    }
    // A wider horizontal gain keeps motion natural from a wide pad onto the 4:3 lower LCD.
    constexpr float xGain = .75f, yGain = .50f;
    cursor.x = std::clamp(cursor.x + (x - delta.x) * xGain, 0.f, 1.f);
    cursor.y = std::clamp(cursor.y - (y - delta.y) * yGain, 0.f, 1.f);
    delta.x = x;
    delta.y = y;
    return cursor;
}

struct TouchSample {
    bool available = false;
    bool touching = false;
    float x = 0.f;
    float y = 0.f;
};

TouchSample readTouch(GCController *controller, GCExtendedGamepad *pad) {
    GCControllerTouchpad *touchpad = controller.physicalInputProfile.touchpads.allValues.firstObject;
    if (touchpad) {
        touchpad.reportsAbsoluteTouchSurfaceValues = YES;
        return {true, touchpad.touchState != GCTouchStateUp,
                touchpad.touchSurface.xAxis.value, touchpad.touchSurface.yAxis.value};
    }
    GCControllerDirectionPad *surface = nil;
    if ([pad isKindOfClass:GCDualSenseGamepad.class])
        surface = ((GCDualSenseGamepad *)pad).touchpadPrimary;
    else if ([pad isKindOfClass:GCDualShockGamepad.class])
        surface = ((GCDualShockGamepad *)pad).touchpadPrimary;
    if (!surface) return {};
    float x = surface.xAxis.value, y = surface.yAxis.value;
    // The legacy profile has no contact flag; zero is the only safe no-contact sample.
    return {true, x != 0.f || y != 0.f, x, y};
}

void enableDualSenseEnhancedReports(GCExtendedGamepad *pad) {
    if (![pad isKindOfClass:GCDualSenseGamepad.class]) return;
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return;
    NSDictionary *match = @{
        @kIOHIDVendorIDKey: @0x054c,
        @kIOHIDProductIDKey: @0x0ce6,
        @kIOHIDPrimaryUsagePageKey: @1,
        @kIOHIDPrimaryUsageKey: @5,
    };
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
    IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    CFSetRef devices = result == kIOReturnSuccess ? IOHIDManagerCopyDevices(manager) : nullptr;
    if (devices) {
        for (id item in (__bridge NSSet *)devices) {
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)item;
            CFStringRef transport = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
            if (!transport || CFGetTypeID(transport) != CFStringGetTypeID() ||
                CFStringCompare(transport, CFSTR(kIOHIDTransportBluetoothValue), 0) != kCFCompareEqualTo)
                continue;
            result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
            if (result == kIOReturnSuccess) {
                // SDL's PS5 initialization uses feature 0x09 to enable full Bluetooth input reports.
                // Only the handshake matters here; discard its identifying response.
                uint8_t feature[64] = {0x09};
                CFIndex length = sizeof(feature);
                result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                               0x09, feature, &length);
                if (result == kIOReturnSuccess)
                    fprintf(stderr, "DualSense Bluetooth: enhanced touchpad reports requested\n");
                IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
            }
            break;
        }
        CFRelease(devices);
    }
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    if (result != kIOReturnSuccess)
        fprintf(stderr, "DualSense touchpad initialization unavailable (0x%08x)\n", result);
}

bool anyPressed(GCExtendedGamepad *pad) {
    for (const auto &item : physical) {
        GCControllerButtonInput *button = buttonFor(pad, item.key);
        if (button.pressed) return true;
    }
    return false;
}

MH4UControllerMenuTarget *menuTarget;

} // namespace
} // namespace ControllerConfig

using namespace ControllerConfig;

@implementation MH4UControllerMenuTarget
- (void)showController:(id)sender {
    (void)sender;
    settingsIsOpen = true;
    if (settingsCallback) settingsCallback(true);
    releaseGate = true;
    currentTouchCursor.pressed = false;
    touchDelta.tracking = false;
    @try {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Controller Mapping";
        GCController *controller = GCController.controllers.firstObject;
        alert.informativeText = controller
            ? [NSString stringWithFormat:@"Connected: %@\nSlide on the touchpad to move the lower-screen cursor; press R3 to click. A physical control used for the lower-screen toggle is suppressed from gameplay.", controller.vendorName ?: @"Game Controller"]
            : @"No controller connected. Settings will apply when one connects.";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];

        constexpr CGFloat labelWidth = 105, popupWidth = 155, rowHeight = 28;
        const NSInteger extraRows = 3;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, rowHeight * (std::size(actions) + extraRows))];
        NSMutableArray<NSPopUpButton *> *popups = [NSMutableArray array];
        NSDictionary *mappings = storedMappings();
        NSInteger row = std::size(actions) + extraRows - 1;
        auto addRow = [&](NSString *label, NSArray<NSString *> *labels, NSString *selected) {
            CGFloat y = row-- * rowHeight;
            NSTextField *text = [NSTextField labelWithString:label];
            text.frame = NSMakeRect(0, y + 4, labelWidth, 20);
            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(labelWidth, y, popupWidth, 25) pullsDown:NO];
            [popup addItemsWithTitles:labels];
            [popup selectItemWithTitle:selected];
            [view addSubview:text]; [view addSubview:popup]; [popups addObject:popup];
        };
        NSMutableArray<NSString *> *buttonLabels = [NSMutableArray array];
        for (const auto &item : physical) [buttonLabels addObject:str(item.label)];
        for (const auto &action : actions) {
            const char *selectedKey = mappingFor(action, mappings);
            NSString *selected = @"None";
            for (const auto &item : physical) if (!strcmp(item.key, selectedKey)) selected = str(item.label);
            addRow(str(action.name), buttonLabels, selected);
        }
        const Physical sticks[] = {{"left", "Left Stick"}, {"right", "Right Stick"}};
        auto selectedStick = [&](NSString *key, const char *fallback) {
            const char *choice = validatedChoice(key, fallback, sticks, 2);
            return !strcmp(choice, "left") ? @"Left Stick" : @"Right Stick";
        };
        addRow(@"Circle Pad", @[@"Left Stick", @"Right Stick"], selectedStick(kCircleStick, "left"));
        addRow(@"C-Stick", @[@"Left Stick", @"Right Stick"], selectedStick(kCStick, "right"));
        const char *host = validatedChoice(kHostToggle, "touchpad", physical, std::size(physical));
        bool reservesR3 = readTouch(controller, controller.extendedGamepad).available;
        if (reservesR3 && !strcmp(host, "r3")) host = "touchpad";
        NSString *hostLabel = @"Touchpad Click";
        for (const auto &item : physical) if (!strcmp(item.key, host)) hostLabel = str(item.label);
        NSMutableArray<NSString *> *hostLabels = [buttonLabels mutableCopy];
        if (reservesR3) [hostLabels removeObject:@"R3"];
        addRow(@"Toggle Lower", hostLabels, hostLabel);
        alert.accessoryView = view;

        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSMutableDictionary *saved = [NSMutableDictionary dictionary];
            NSUInteger index = 0;
            for (const auto &action : actions) {
                NSString *label = popups[index++].titleOfSelectedItem;
                for (const auto &item : physical) if ([label isEqualToString:str(item.label)]) saved[str(action.name)] = str(item.key);
            }
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            [defaults setObject:saved forKey:kMappings];
            [defaults setObject:popups[index++].indexOfSelectedItem == 0 ? @"left" : @"right" forKey:kCircleStick];
            [defaults setObject:popups[index++].indexOfSelectedItem == 0 ? @"left" : @"right" forKey:kCStick];
            NSString *label = popups[index].titleOfSelectedItem;
            for (const auto &item : physical) if ([label isEqualToString:str(item.label)]) [defaults setObject:str(item.key) forKey:kHostToggle];
        }
    } @finally {
        settingsIsOpen = false;
        if (settingsCallback) settingsCallback(false);
        releaseGate = true;
        lastHostPressed = false;
        touchDelta.tracking = false;
        [ownerWindow makeKeyAndOrderFront:nil];
    }
}

- (void)toggleFullscreen:(id)sender {
    (void)sender;
    bool value = !fullscreenPreferred();
    [NSUserDefaults.standardUserDefaults setBool:value forKey:kFullscreen];
    self.fullscreenItem.state = value ? NSControlStateValueOn : NSControlStateValueOff;
    if (fullscreenCallback) fullscreenCallback(value);
}

- (void)toggleLowerScreen:(id)sender {
    (void)sender;
    if (toggleLowerCallback) toggleLowerCallback();
}
@end

namespace ControllerConfig {
namespace {

} // namespace

void installMenu(NSMenu *mainMenu, NSWindow *gameWindow, void (*toggleLower)(),
                 void (*setFullscreen)(bool), void (*settingsChanged)(bool)) {
    ownerWindow = gameWindow;
    toggleLowerCallback = toggleLower;
    fullscreenCallback = setFullscreen;
    settingsCallback = settingsChanged;
    menuTarget = [MH4UControllerMenuTarget new];

    NSMenuItem *settingsRoot = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    NSMenu *settings = [[NSMenu alloc] initWithTitle:@"Settings"];
    NSMenuItem *controller = [[NSMenuItem alloc] initWithTitle:@"Controller…" action:@selector(showController:) keyEquivalent:@","];
    controller.target = menuTarget;
    [settings addItem:controller];
    NSMenuItem *lower = [[NSMenuItem alloc] initWithTitle:@"Show Lower Screen" action:@selector(toggleLowerScreen:) keyEquivalent:@"b"];
    lower.target = menuTarget;
    lower.state = lowerScreenVisible() ? NSControlStateValueOn : NSControlStateValueOff;
    menuTarget.lowerItem = lower;
    [settings addItem:lower];
    NSMenuItem *fullscreen = [[NSMenuItem alloc] initWithTitle:@"Start in Full Screen" action:@selector(toggleFullscreen:) keyEquivalent:@""];
    fullscreen.target = menuTarget;
    fullscreen.state = fullscreenPreferred() ? NSControlStateValueOn : NSControlStateValueOff;
    menuTarget.fullscreenItem = fullscreen;
    [settings addItem:fullscreen];
    settingsRoot.submenu = settings;
    [mainMenu addItem:settingsRoot];
}

void poll(uint16_t &buttons, int16_t axes[2][2], bool enabled) {
    GCController *controller = GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (controller != lastController) {
        enableDualSenseEnhancedReports(pad);
        releaseGate = true;
        lastHostPressed = false;
        lastController = controller;
        currentTouchCursor.available = false;
        currentTouchCursor.pressed = false;
        touchDelta.tracking = false;
    }
    if (!enabled || settingsIsOpen || !pad) {
        hostEdge(false, false, false, releaseGate, lastHostPressed);
        currentTouchCursor.available = false;
        currentTouchCursor.pressed = false;
        touchDelta.tracking = false;
        return;
    }
    TouchSample touch = readTouch(controller, pad);
    NSDictionary *mappings = storedMappings();
    const char *hostKey = validatedChoice(kHostToggle, "touchpad", physical, std::size(physical));
    if (touch.available && !strcmp(hostKey, "r3")) hostKey = "touchpad";
    GCControllerButtonInput *hostButton = buttonFor(pad, hostKey);
    if (!hostButton && !touch.available && !strcmp(hostKey, "touchpad"))
        hostButton = pad.rightThumbstickButton;
    bool hostPressed = hostButton.pressed;
    bool toggle = hostEdge(true, anyPressed(pad), hostPressed, releaseGate, lastHostPressed);
    bool lowerVisible = lowerScreenVisible();
    bool cursorAvailable = touch.available && lowerVisible && !releaseGate;
    currentTouchCursor = cursorSample(currentTouchCursor, touchDelta, cursorAvailable,
                                      cursorAvailable && touch.touching, touch.x, touch.y,
                                      cursorAvailable,
                                      pad.rightThumbstickButton.pressed);
    if (releaseGate) return;
    if (toggle && toggleLowerCallback) toggleLowerCallback();
    for (const auto &action : actions) {
        const char *key = mappingFor(action, mappings);
        GCControllerButtonInput *input = buttonFor(pad, key);
        bool reservedR3 = touch.available && lowerVisible && input == pad.rightThumbstickButton;
        if (gameplayPress(input.pressed, input == hostButton || reservedR3)) buttons |= uint16_t(1u << action.retroId);
    }
    const Physical sticks[] = {{"left", "Left Stick"}, {"right", "Right Stick"}};
    const char *circle = validatedChoice(kCircleStick, "left", sticks, 2);
    const char *cstick = validatedChoice(kCStick, "right", sticks, 2);
    auto setStick = [&](int slot, const char *choice) {
        GCControllerDirectionPad *stick = !strcmp(choice, "left") ? pad.leftThumbstick : pad.rightThumbstick;
        axes[slot][0] = scaled(stick.xAxis.value);
        axes[slot][1] = scaled(-stick.yAxis.value);
    };
    setStick(0, circle); setStick(1, cstick);
}

bool fullscreenPreferred() {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kFullscreen] ? [defaults boolForKey:kFullscreen] : true;
}
void setFullscreenPreferred(bool preferred) {
    [NSUserDefaults.standardUserDefaults setBool:preferred forKey:kFullscreen];
    menuTarget.fullscreenItem.state = preferred ? NSControlStateValueOn : NSControlStateValueOff;
}
bool lowerScreenVisible() {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kLowerVisible] ? [defaults boolForKey:kLowerVisible] : false;
}
void setLowerScreenVisible(bool visible) {
    [NSUserDefaults.standardUserDefaults setBool:visible forKey:kLowerVisible];
    menuTarget.lowerItem.state = visible ? NSControlStateValueOn : NSControlStateValueOff;
    currentTouchCursor.pressed = false;
    touchDelta.tracking = false;
    releaseGate = true;
    lastHostPressed = false;
}
bool settingsOpen() { return settingsIsOpen; }
TouchCursor touchCursor() { return currentTouchCursor; }

int selfTest() {
    NSDictionary *bad = @{ @"A": @42, @"B": @"invalid", @"X": @"square" };
    if (strcmp(mappingFor(actions[0], bad), "circle")) return 1;
    if (strcmp(mappingFor(actions[1], bad), "cross")) return 2;
    if (strcmp(mappingFor(actions[2], bad), "square")) return 3;
    bool gate = false, last = false;
    if (!hostEdge(true, false, true, gate, last)) return 4;
    if (hostEdge(true, false, true, gate, last)) return 5;
    if (hostEdge(false, false, false, gate, last) || !gate) return 6;
    if (hostEdge(true, true, true, gate, last) || !gate) return 7;
    if (hostEdge(true, false, false, gate, last) || gate) return 8;
    if (!hostEdge(true, true, true, gate, last)) return 9;
    if (gameplayPress(true, true) || !gameplayPress(true, false)) return 10;
    TouchCursor cursor;
    TouchDeltaState delta;
    auto sample = [&](bool available, bool touching, float x, float y, bool r3 = false) {
        cursor = cursorSample(cursor, delta, available, touching, x, y, available, r3);
    };
    auto swipe = [&](float x0, float y0, float x1, float y1) {
        sample(true, true, x0, y0);
        sample(true, true, x1, y1);
        sample(true, false, 0.f, 0.f);
    };
    sample(true, true, -.9f, .8f, true);
    if (!cursor.available || !cursor.pressed || cursor.x != .5f || cursor.y != .5f) return 11;
    sample(true, true, -.4f, .8f, true);
    if (!cursor.pressed || cursor.x <= .5f || cursor.y != .5f) return 12;
    float heldX = cursor.x, heldY = cursor.y;
    sample(true, false, 0.f, 0.f, true);
    if (!cursor.pressed || cursor.x != heldX || cursor.y != heldY || delta.tracking) return 13;
    sample(true, true, .9f, -.9f, true);
    if (!cursor.pressed || cursor.x != heldX || cursor.y != heldY) return 14;
    sample(true, false, 0.f, 0.f);
    swipe(-.5f, 0.f, .5f, 0.f);
    swipe(-.5f, 0.f, .5f, 0.f);
    if (cursor.x != 1.f) return 15;
    swipe(.5f, 0.f, -.5f, 0.f);
    swipe(.5f, 0.f, -.5f, 0.f);
    if (cursor.x != 0.f) return 16;
    swipe(0.f, -.5f, 0.f, .5f);
    swipe(0.f, -.5f, 0.f, .5f);
    if (cursor.y != 0.f) return 17;
    swipe(0.f, .5f, 0.f, -.5f);
    swipe(0.f, .5f, 0.f, -.5f);
    if (cursor.y != 1.f) return 18;
    sample(true, true, 0.f, 0.f, true);
    sample(true, true, .25f, .25f, true);
    if (!cursor.pressed || cursor.x == 0.f || cursor.y == 1.f) return 19;
    heldX = cursor.x; heldY = cursor.y;
    sample(false, false, 0.f, 0.f, true);
    if (cursor.available || cursor.pressed || cursor.x != heldX || cursor.y != heldY || delta.tracking) return 20;
    sample(true, true, -1.f, 1.f);
    if (cursor.x != heldX || cursor.y != heldY) return 21;
    return 0;
}

} // namespace ControllerConfig
