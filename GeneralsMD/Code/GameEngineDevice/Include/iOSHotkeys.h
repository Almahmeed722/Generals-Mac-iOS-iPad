#pragma once

// On-screen hotkey bar for the iOS build (see Source/iOSHotkeyOverlay.mm).
//
// The overlay is a UIKit layer above the SDL view; its buttons feed key presses into the engine's
// keyboard through gxHotkeySendKey(). The touch handler in SDL3GameEngine.cpp tells the overlay
// when a tap finished (so one-shot modifiers like "Add" release) and reads the "Move map" toggle.

#include <TargetConditionals.h>

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

struct SDL_Window;

// Implemented in iOSHotkeyOverlay.mm
void gxHotkeyOverlayInit(SDL_Window *window);
void gxHotkeyOverlaySetVisible(bool visible);
void gxHotkeyNotifyTapDone();

// Implemented in SDL3GameEngine.cpp
void gxHotkeySendKey(int scancode, bool down);
void gxHotkeySetMoveMode(bool on);
void gxHotkeyRightClick();

#endif
