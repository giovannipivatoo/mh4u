#pragma once

#include <cstdint>

@class NSMenu;
@class NSWindow;

namespace ControllerConfig {

struct TouchCursor {
    bool available = false;
    bool pressed = false;
    float x = .5f;
    float y = .5f;
};

void installMenu(NSMenu *mainMenu, NSWindow *gameWindow,
                 void (*toggleLower)(), void (*setFullscreen)(bool),
                 void (*settingsChanged)(bool) = nullptr);
void poll(uint16_t &buttons, int16_t axes[2][2], bool enabled);
TouchCursor touchCursor();
bool fullscreenPreferred();
void setFullscreenPreferred(bool preferred);
bool lowerScreenVisible();
void setLowerScreenVisible(bool visible);
bool settingsOpen();
int selfTest();

} // namespace ControllerConfig
