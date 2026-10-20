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
// Left, top and width of the minimap in window points (negative left = unknown); the quick strip sits centred above it.
void gxHotkeyOverlaySetQuickAnchor(float left, float top, float width);
void gxHotkeyNotifyTapDone();
// The engine used the "Point" mode for one tap: switch the button's light off.
void gxHotkeyPointModeConsumed();
// A finger touched the control bar / a menu: let go of a latched "Queue path" (Alt) so it is not left held down.
void gxHotkeyReleaseQueuePath();
// Replay playback: show the speed buttons (1x 2x 4x 8x) only while a replay is running.
void gxHotkeyOverlaySetReplay(bool replay);
// Extra running time from iOS while the app is in the background (keeps a multiplayer game connected for a short while).
void gxBackgroundTaskBegin();
void gxBackgroundTaskEnd();

// Implemented in SDL3GameEngine.cpp
void gxHotkeySendKey(int scancode, bool down);
void gxHotkeyCancel();      // cancel a pending command / placement, otherwise deselect
void gxHotkeySetPointMode(bool on); // "Point": the next tap on empty ground sets where the selected building's new units gather
void gxHotkeyResetView();   // camera back to the normal direction, tilt and zoom
void gxHotkeySelectArmy();  // all ground combat units (soldiers, tanks), not inside buildings
void gxHotkeySelectAir();
void gxHotkeySetReplaySpeed(int speed); // replay playback speed: 1, 2, 4 or 8 times normal   // all combat aircraft

#endif
