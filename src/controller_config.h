#pragma once

#include <cstdint>

@class NSMenu;
@class NSWindow;

namespace ControllerConfig {

void installMenu(NSMenu *mainMenu, NSWindow *gameWindow,
                 void (*toggleLower)(), void (*setFullscreen)(bool));
void poll(uint16_t &buttons, int16_t axes[2][2], bool enabled);
bool fullscreenPreferred();
void setFullscreenPreferred(bool preferred);
bool lowerScreenVisible();
void setLowerScreenVisible(bool visible);
bool settingsOpen();
int selfTest();

} // namespace ControllerConfig
