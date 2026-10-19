#pragma once

// On-screen hotkey buttons for the iOS build (see Source/iOSHotkeyOverlay.mm).
//
// The overlay is a UIKit layer above the SDL view; its buttons feed key presses into the engine's
// keyboard through gxHotkeySendKey() or call the small helpers below. The touch handler in
// SDL3GameEngine.cpp tells the overlay when a tap finished (so one-shot modifiers like "Add" release).

#include <TargetConditionals.h>

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

struct SDL_Window;

// Implemented in iOSHotkeyOverlay.mm
void gxHotkeyOverlayInit(SDL_Window *window);
void gxHotkeyOverlaySetVisible(bool visible);
// Top-left of the money / power bars in window points (negative = unknown); the quick strip sits above it.
void gxHotkeyOverlaySetQuickAnchor(float left, float top);
void gxHotkeyNotifyTapDone();

// Implemented in SDL3GameEngine.cpp
void gxHotkeySendKey(int scancode, bool down);
void gxHotkeyCancel();      // cancel a pending command / placement, otherwise deselect
void gxHotkeyResetView();   // camera back to the normal direction, tilt and zoom
void gxHotkeySelectArmy();  // all ground combat units (soldiers, tanks), not inside buildings
void gxHotkeySelectAir();   // all combat aircraft

#endif
