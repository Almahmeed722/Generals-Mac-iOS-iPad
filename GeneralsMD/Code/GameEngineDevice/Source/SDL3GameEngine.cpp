/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
** SDL3GameEngine.cpp
**
** Linux implementation of GameEngine using SDL3 for windowing/input.
**
** TheSuperHackers @feature CnC_Generals_Linux 07/02/2026
** Provides SDL3-based input and window management for Linux builds.
** Based on fighter19 reference implementation.
*/

#ifndef _WIN32

#include "SDL3GameEngine.h"
#include "OpenALAudioManager.h"
#include "SDL3Device/GameClient/SDL3Mouse.h"
#include "SDL3Device/GameClient/SDL3Keyboard.h"
#include "GameClient/Mouse.h"
#include "GameClient/Keyboard.h"
#include "GameClient/GameWindow.h"
#include "GameClient/GameWindowManager.h"
#include "GameClient/Gadget.h"
#include "W3DDevice/GameLogic/W3DGameLogic.h"
#include "W3DDevice/GameClient/W3DGameClient.h"
#include "W3DDevice/Common/W3DModuleFactory.h"
#include "W3DDevice/Common/W3DThingFactory.h"
#include "W3DDevice/Common/W3DFunctionLexicon.h"
#include "W3DDevice/Common/W3DRadar.h"
#include "W3DDevice/GameClient/W3DParticleSys.h"
#include "W3DDevice/GameClient/W3DWebBrowser.h"
#include "StdDevice/Common/StdLocalFileSystem.h"
#include "StdDevice/Common/StdBIGFileSystem.h"
#include "Common/GlobalData.h"
#include "Common/FramePacer.h"
#include "GameClient/View.h"
#include "GameClient/Display.h"
#include "GameClient/InGameUI.h"
#include "GameNetwork/NetworkInterface.h"
#include "GameClient/Shell.h"
#include "Common/Radar.h"
#include "Common/NameKeyGenerator.h"
#include "GameLogic/GameLogic.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include "iOSHotkeys.h"
#include <cmath>
#endif

// Extern globals for input devices (set by GameClient)
extern Mouse *TheMouse;
extern Keyboard *TheKeyboard;
extern GameWindowManager *TheWindowManager;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <atomic>

// ---------------------------------------------------------------------------
// iOS app lifecycle
//
// iOS suspends the process when the app leaves the foreground. Any GPU work
// submitted around suspension stalls on drawable acquisition (MoltenVK waits
// out a timeout per present), which surfaces as multi-second input hangs right
// after resuming. SDL warns that lifecycle events can arrive outside the
// normal poll cycle, so they are captured in an event watcher that fires
// immediately on the delivering thread; the engine update loop checks the
// flag and skips simulation + rendering while backgrounded.
// ---------------------------------------------------------------------------
// Two independent reasons to halt the render/sim loop on iOS:
//  - BACKGROUNDED (home / switched away): the process is about to be suspended.
//  - INACTIVE (multitasking switcher open, Control Center, a notification
//    banner): iOS snapshots the window and owns the CAMetalLayer drawable during
//    this window — and crucially, opening the app switcher fires resign-active
//    WITHOUT a full background transition.
// Acquiring a Metal drawable during EITHER state fights iOS for the layer; across
// repeated suspend/switcher cycles MoltenVK is driven into an unrecoverable
// surface state and the app crashes (the reported "crashes after backgrounding /
// multitasking a few times"). Pause whenever either is set.
static std::atomic<bool> s_appBackgrounded{false};
static std::atomic<bool> s_appInactive{false};

static inline bool iosShouldPauseRendering()
{
	return s_appBackgrounded.load() || s_appInactive.load();
}

static bool SDLCALL iosLifecycleWatcher(void *userdata, SDL_Event *event)
{
	switch (event->type) {
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
			// Ask iOS for extra running time (about 30 s) so a multiplayer game survives a short call or app switch.
			gxBackgroundTaskBegin();
			s_appBackgrounded.store(true);
			break;
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			s_appBackgrounded.store(true);
			break;
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			gxBackgroundTaskEnd();
			s_appBackgrounded.store(false);
			break;
		// Resign/become active. On iOS, SDL maps applicationWillResignActive ->
		// window focus lost and applicationDidBecomeActive -> window focus gained.
		// Stay paused until fully active again (focus regained), which arrives
		// after DID_ENTER_FOREGROUND.
		case SDL_EVENT_WINDOW_FOCUS_LOST:
			s_appInactive.store(true);
			break;
		case SDL_EVENT_WINDOW_FOCUS_GAINED:
			s_appInactive.store(false);
			break;
		default:
			break;
	}
	return true;
}

// ---------------------------------------------------------------------------
// iOS touch -> mouse / camera gesture translation
//
// SDL's automatic touch-mouse synthesis is disabled on iOS (SDL3Main.cpp sets
// SDL_HINT_TOUCH_MOUSE_EVENTS=0); every mouse event the game sees on iOS is
// synthesized here, through the same SDL3Mouse::addSDLEvent path real mice use.
//
// Gestures:
//   1 finger tap                   -> left click (select / command); two quick taps -> double click
//                                     (selects every unit of the same type that is on screen)
//   1 finger swipe                 -> the map follows the finger (always the camera, never a selection
//                                     box or an order); a quick flick keeps sliding for a moment
//   1 finger held ~0.6 s           -> right click (deselect)
//   building selected: hold 2 s    -> left click = set the building's rally / waypoint there
//                                     (a quick tap on empty ground does nothing, so it can't change by accident)
//   hold 1 finger, 2nd finger drags-> selection box; 2nd finger taps -> add that unit to the selection
//   2 fingers together             -> move the map; spread / pinch -> zoom; twist -> rotate the camera
//   2 finger quick tap             -> cancel (right click)
//   finger on the minimap          -> the camera jumps to and follows the finger
//   aiming a special power / placing a building -> the cursor follows the finger, click on release;
//                                     holding near the screen edge scrolls the camera
// ---------------------------------------------------------------------------
namespace {

struct TouchState {
	enum Phase {
		IDLE,        // no fingers tracked
		PENDING,     // finger1 down, gesture identity not yet known, nothing sent
		GRABPAN,     // one-finger swipe: the map follows the finger
		PAN,         // two-finger camera gesture: move / zoom / rotate (applied once per frame)
		HOLDSELECT,  // finger1 held still, finger2 draws a selection box or taps to add a unit
		MINIMAP,     // finger on the minimap: the camera follows it
		TARGETING,   // aiming a special power / placing a building: cursor follows the finger
		UIDRAG,      // finger on a menu / control-bar window: a drag stays a normal mouse drag (sliders, lists)
		PLACE_DRAG,  // placing a building: the position is fixed (button held), dragging turns the building, release builds
		LONGPRESSED  // a long press already fired, swallow the rest of the touch
	};

	Phase phase = IDLE;
	SDL_FingerID finger1 = 0;
	SDL_FingerID finger2 = 0;
	float downX = 0.0f, downY = 0.0f;   // finger1 down position (window points)
	float lastX = 0.0f, lastY = 0.0f;   // finger1 latest position
	float pinchDist = 0.0f;             // finger distance at last wheel step
	Uint64 downTicks = 0;
	float f1x = 0.0f, f1y = 0.0f, f2x = 0.0f, f2y = 0.0f; // normalized per finger
	bool battlefield = false;           // this touch started on the battlefield of a running match (not on a menu / UI window)
	// hold-select
	float selDownX = 0.0f, selDownY = 0.0f, selLastX = 0.0f, selLastY = 0.0f;
	bool selActive = false;
	Uint64 lastMoveTicks = 0;           // last time the finger moved noticeably while aiming (to detect it resting)
	float lastMoveX = 0.0f, lastMoveY = 0.0f;
	// two-finger tap detection
	Uint64 panStartTicks = 0;
	float panTravel = 0.0f;
};

TouchState s_touch;

const Uint64 LONG_PRESS_MS = 600;
const Uint64 RALLY_HOLD_MS = 2000;     // hold this long to give a building a rally / waypoint
const Uint64 HOLD_SELECT_MS = 220;     // finger1 must have been still this long before finger2 means "select"
const Uint64 DOUBLE_TAP_MS = 350;
const Uint64 PLACE_ANCHOR_MS = 400;    // placing a building: a finger resting this long fixes the position; dragging then turns it
const float DOUBLE_TAP_DIST_PX = 48.0f;
const float PINCH_STEP_RATIO = 0.05f;  // 5% distance change per wheel tick
const float TAP_DEAD_ZONE_PX = 14.0f;  // jitter below this keeps a tap a tap (a thumb moves ~10pt while tapping)
const float RESTED_SWIPE_PX = 44.0f;   // a finger resting >0.25 s needs this much movement to count as a swipe
const float GESTURE_DEADBAND_PX = 1.5f; // per-frame movement below this is finger noise
const float ROTATE_GAIN = 1.6f;        // camera turns this many times faster than the fingers twist
const float COAST_DECAY = 0.92f;       // camera keeps sliding after a quick flick, slowing by 8% per frame
const float COAST_START_MIN = 3.0f;    // world units per frame needed to start sliding
const float COAST_STOP_MIN = 0.4f;
const Uint64 TWO_FINGER_TAP_MS = 350;
const float TWO_FINGER_TAP_TRAVEL_PX = 24.0f;

// Short log of what the touch handler decides (generals-stderr.log): enough to see why a gesture did or did not fire.
int s_touchLogBudget = 800;
#define GXTOUCH_LOG(...) do { if (s_touchLogBudget > 0) { --s_touchLogBudget; fprintf(stderr, "[GX-TOUCH] " __VA_ARGS__); } } while (0)

struct CamState {
	bool hasPrev = false;
	float prevCx = 0.0f, prevCy = 0.0f, prevDist = 0.0f, prevAng = 0.0f;
	float velX = 0.0f, velY = 0.0f;      // recent camera velocity in world units per frame
	bool coasting = false;
	float rotAccum = 0.0f;               // rotation still to be applied, eased in over a few frames
};
CamState s_cam;

// A click is delivered over three frames (cursor already moved at touch-down, button down on the
// next frame, button up on the one after) so the game's hover/placement logic sees the cursor
// before the click, the way it does for a real mouse.
struct PendingTap {
	int stage = -1;                      // -1 none; 2 = wait a frame, 1 = send button down, 0 = send button up
	float x = 0.0f, y = 0.0f;
	Uint8 button = SDL_BUTTON_LEFT;
	bool shift = false;                  // hold Shift for this click (add to the selection)
	bool wasPlacing = false;             // the click happened while a building was being placed
};
PendingTap s_tap;
bool s_logObjectUnderOnce = false;
bool s_pointMode = false;                // "Point" button: the next tap on empty ground sets the building's gathering point
int s_postPlaceFrames = 0;               // frames left to watch for a finished building placement
int s_shiftReleaseFrames = 0;            // frames until the helper Shift key is released
Uint64 s_lastTapTicks = 0;               // for double-tap detection
float s_lastTapX = 0.0f, s_lastTapY = 0.0f;

void sendSyntheticMouse(SDL3Mouse *mouse, SDL_Window *window, Uint32 type,
                        float x, float y, Uint8 button = 0, float wheelY = 0.0f, int clicks = 1)
{
	// The windowID must be valid: SDL3Mouse::scaleMouseCoordinates() looks the
	// window up by id to map window points into the game's internal resolution,
	// and silently skips scaling when the lookup fails.
	const SDL_WindowID windowID = SDL_GetWindowID(window);

	SDL_Event ev;
	SDL_zero(ev);
	ev.type = type;
	switch (type) {
		case SDL_EVENT_MOUSE_MOTION:
			ev.motion.windowID = windowID;
			ev.motion.x = x;
			ev.motion.y = y;
			break;
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			ev.button.windowID = windowID;
			ev.button.button = button;
			ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
			ev.button.clicks = (Uint8)clicks; // 2 = the engine treats it as a double click
			ev.button.x = x;
			ev.button.y = y;
			break;
		case SDL_EVENT_MOUSE_WHEEL:
			ev.wheel.windowID = windowID;
			ev.wheel.x = 0.0f;
			ev.wheel.y = wheelY;
			ev.wheel.mouse_x = x;
			ev.wheel.mouse_y = y;
			break;
	}
	mouse->addSDLEvent(&ev);
}

void queueClick(Uint8 button, float x, float y, bool shift)
{
	s_tap.stage = 2;
	s_tap.x = x;
	s_tap.y = y;
	s_tap.button = button;
	s_tap.shift = shift;
	if (shift) {
		gxHotkeySendKey(SDL_SCANCODE_LSHIFT, true);
	}
}

void beginPan(int winW, int winH)
{
	const float dx = (s_touch.f1x - s_touch.f2x) * (float)winW;
	const float dy = (s_touch.f1y - s_touch.f2y) * (float)winH;
	s_touch.pinchDist = SDL_sqrtf(dx * dx + dy * dy);
	// No mouse button is held: the gesture is applied directly to the camera once per frame.
	s_cam.hasPrev = false;
	s_cam.coasting = false;
	s_cam.velX = s_cam.velY = 0.0f;
	s_touch.panStartTicks = SDL_GetTicks();
	s_touch.panTravel = 0.0f;
	s_touch.phase = TouchState::PAN;
}

// Move the camera so the ground point that was under screen position (x0,y0) ends up under
// (x1,y1): the map follows the finger. Coordinates are window points.
void panCameraByScreen(float x0, float y0, float x1, float y1, int winW, int winH)
{
	if (!TheTacticalView || !TheDisplay || winW <= 0 || winH <= 0) {
		return;
	}
	const float sx = (float)TheDisplay->getWidth() / (float)winW;
	const float sy = (float)TheDisplay->getHeight() / (float)winH;
	ICoord2D a, b;
	a.x = (Int)(x0 * sx);
	a.y = (Int)(y0 * sy);
	b.x = (Int)(x1 * sx);
	b.y = (Int)(y1 * sy);
	Coord3D wa, wb;
	wa.x = wa.y = wa.z = 0.0f;
	wb.x = wb.y = wb.z = 0.0f;
	TheTacticalView->screenToTerrain(&a, &wa);
	TheTacticalView->screenToTerrain(&b, &wb);
	Real dx = wa.x - wb.x;
	Real dy = wa.y - wb.y;
	const Real limit = 600.0f; // a missed ray must never fling the camera across the map
	if (dx > limit) dx = limit; else if (dx < -limit) dx = -limit;
	if (dy > limit) dy = limit; else if (dy < -limit) dy = -limit;
	if (dx == 0.0f && dy == 0.0f) {
		s_cam.velX *= 0.5f; // a finger that stopped before lifting must not start a slide
		s_cam.velY *= 0.5f;
		return;
	}
	Coord3D np = TheTacticalView->getPosition();
	np.x += dx;
	np.y += dy;
	TheTacticalView->userLookAt(&np);
	s_cam.velX = 0.5f * s_cam.velX + 0.5f * (float)dx;
	s_cam.velY = 0.5f * s_cam.velY + 0.5f * (float)dy;
}

// Start the post-flick slide, if the last movement was quick enough.
void startCoast()
{
	const float speed = SDL_sqrtf(s_cam.velX * s_cam.velX + s_cam.velY * s_cam.velY);
	s_cam.coasting = (speed >= COAST_START_MIN);
	s_cam.hasPrev = false;
}

// True while the game waits for a target (spy drone / special power / attack-move target) or a
// building placement: then a held finger must aim, not move the map.
bool gxInTargetingMode()
{
	if (!TheInGameUI) {
		return false;
	}
	return TheInGameUI->getGUICommand() != nullptr || TheInGameUI->getPendingPlaceType() != nullptr;
}

// True while the player is placing a building (not a special power): then a resting finger fixes the
// position and dragging turns the building, exactly like press-and-drag with a mouse.
bool gxPlacingBuilding()
{
	return TheInGameUI != nullptr && TheInGameUI->getPendingPlaceType() != nullptr;
}

// Convert window points to the game's internal screen pixels.
ICoord2D gxToScreen(float px, float py, int winW, int winH)
{
	ICoord2D s;
	s.x = 0;
	s.y = 0;
	if (TheDisplay && winW > 0 && winH > 0) {
		s.x = (Int)(px * (float)TheDisplay->getWidth() / (float)winW);
		s.y = (Int)(py * (float)TheDisplay->getHeight() / (float)winH);
	}
	return s;
}

// Did this touch land on the battlefield of a running match (and not on a menu, the control bar, a dialog...)?
// Only there does a one-finger swipe move the camera; on UI windows a drag stays a normal mouse drag.
bool gxTouchOnBattlefield(float px, float py, int winW, int winH)
{
	if (!TheGameLogic || !TheGameLogic->isInGame() || !GameLogic::isInInteractiveGame(TheGameLogic->getGameMode())) {
		return false;
	}
	if (TheShell && TheShell->isShellActive()) {
		return false;
	}
	if (!TheWindowManager) {
		return false;
	}
	const ICoord2D s = gxToScreen(px, py, winW, winH);
	GameWindow *window = TheWindowManager->getWindowUnderCursor(s.x, s.y);
	while (window) {
		// an opaque window (or opaque parent) under the finger means UI, not the battlefield
		if (!BitIsSet(window->winGetStatus(), WIN_STATUS_SEE_THRU)) {
			return false;
		}
		window = window->winGetParent();
	}
	return true;
}

// True when something is selected and ALL of it is buildings (then a tap on empty ground would set
// the building's rally point, which should only happen on a deliberate long hold).
bool gxOnlyBuildingsSelected()
{
	if (!TheInGameUI) {
		return false;
	}
	const DrawableList *list = TheInGameUI->getAllSelectedDrawables();
	if (!list || list->empty()) {
		return false;
	}
	for (DrawableListCIt it = list->begin(); it != list->end(); ++it) {
		Drawable *draw = *it;
		const Object *obj = draw ? draw->getObject() : nullptr;
		if (!obj || !obj->isKindOf(KINDOF_STRUCTURE)) {
			return false;
		}
	}
	return true;
}

// Is there a selectable unit or building under this window point?
bool gxObjectUnder(float px, float py, int winW, int winH)
{
	if (!TheTacticalView) {
		return false;
	}
	const ICoord2D s = gxToScreen(px, py, winW, winH);
	return TheTacticalView->pickDrawable(&s, FALSE, PICK_TYPE_SELECTABLE) != nullptr;
}

// The ground point under a finger that is on the minimap, or false when it is elsewhere.
bool gxRadarWorldPointAt(float px, float py, int winW, int winH, Coord3D *world)
{
	if (!TheRadar || !TheWindowManager || !TheDisplay || winW <= 0 || winH <= 0) {
		return false;
	}
	GameWindow *radarWin = TheWindowManager->winGetWindowFromId(nullptr, NAMEKEY("ControlBar.wnd:LeftHUD"));
	if (!radarWin || radarWin->winIsHidden()) {
		return false;
	}
	ICoord2D pos, size;
	radarWin->winGetScreenPosition(&pos.x, &pos.y);
	radarWin->winGetSize(&size.x, &size.y);
	const ICoord2D s = gxToScreen(px, py, winW, winH);
	ICoord2D local;
	local.x = s.x - pos.x;
	local.y = s.y - pos.y;
	if (local.x < 0 || local.y < 0 || local.x >= size.x || local.y >= size.y) {
		return false;
	}
	ICoord2D radar;
	if (!TheRadar->localPixelToRadar(&local, &radar)) {
		return false;
	}
	return TheRadar->radarToWorld(&radar, world) ? true : false;
}

// While a finger holds a target or a selection box near the screen edge, scroll the camera that way
// (faster the closer to the edge) so a target can be moved to a place that is not on screen yet.
void autoScrollAtEdges(float fx, float fy, int winW, int winH)
{
	if (winW <= 0 || winH <= 0) {
		return;
	}
	const float margin = 0.12f * (float)(winH < winW ? winH : winW);
	const float px = fx * (float)winW;
	const float py = fy * (float)winH;
	float dirx = 0.0f, diry = 0.0f;
	if (px < margin) dirx = -(1.0f - px / margin);
	else if (px > (float)winW - margin) dirx = 1.0f - ((float)winW - px) / margin;
	if (py < margin) diry = -(1.0f - py / margin);
	else if (py > (float)winH - margin) diry = 1.0f - ((float)winH - py) / margin;
	if (dirx == 0.0f && diry == 0.0f) {
		return;
	}
	const float speed = 14.0f; // window points per frame right at the edge
	const float cx = 0.5f * (float)winW;
	const float cy = 0.5f * (float)winH;
	panCameraByScreen(cx, cy, cx - dirx * speed, cy - diry * speed, winW, winH);
}

// Deliver a click that is still waiting for its button events (a new touch starts, so finish it first).
void flushPendingTap(SDL3Mouse *mouse, SDL_Window *window)
{
	if (s_tap.stage < 0) {
		return;
	}
	if (s_tap.stage >= 1) {
		sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN, s_tap.x, s_tap.y, s_tap.button);
	}
	sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, s_tap.x, s_tap.y, s_tap.button);
	s_tap.stage = -1;
	if (s_tap.shift) {
		s_shiftReleaseFrames = 3;
		s_tap.shift = false;
	}
	gxHotkeyNotifyTapDone();
}

// Fix the building at the finger's position (the cursor is already there): the left button goes down now
// and stays down while the finger drags to turn the building; lifting the finger places it.
void startPlacementDrag(SDL3Mouse *mouse, SDL_Window *window, float x, float y)
{
	sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, x, y);
	sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, SDL_BUTTON_LEFT);
	s_touch.phase = TouchState::PLACE_DRAG;
	GXTOUCH_LOG("building position fixed at %.0f,%.0f: drag to turn it, lift to build\n", x, y);
}

void handleTouchEvent(SDL3Mouse *mouse, SDL_Window *window, const SDL_Event &event)
{
	int winW = 0, winH = 0;
	SDL_GetWindowSize(window, &winW, &winH);
	const float px = event.tfinger.x * (float)winW;
	const float py = event.tfinger.y * (float)winH;

	switch (event.type) {
	case SDL_EVENT_FINGER_DOWN:
		s_cam.coasting = false; // a new touch stops a sliding camera
		flushPendingTap(mouse, window);
		if (s_touch.phase == TouchState::IDLE) {
			// Defer all BUTTON output: a finger landing could become a tap, a swipe, a long-press,
			// or the first finger of a two-finger gesture. A premature click is a real click to the
			// game (e.g. it sets a rally point when a production building is selected).
			s_touch.finger1 = event.tfinger.fingerID;
			s_touch.finger2 = 0;
			s_touch.phase = TouchState::PENDING;
			s_touch.downX = s_touch.lastX = px;
			s_touch.downY = s_touch.lastY = py;
			s_touch.f1x = event.tfinger.x;
			s_touch.f1y = event.tfinger.y;
			s_touch.downTicks = SDL_GetTicks();
			s_touch.selActive = false;
			s_logObjectUnderOnce = false;
			// Move the cursor to the touch point NOW (motion clicks nothing, so the deferred-tap
			// protection is intact). This lets the GUI process hover over the next frame(s) before
			// the tap commits: hover-driven widgets (e.g. the Generals Challenge general buttons)
			// ignore a click unless a prior mouse-enter hilited them.
			sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
			s_touch.battlefield = gxTouchOnBattlefield(px, py, winW, winH);
			// A finger that lands on the minimap makes the camera jump to and follow it.
			Coord3D radarWorld;
			if (!gxInTargetingMode() && TheTacticalView && gxRadarWorldPointAt(px, py, winW, winH, &radarWorld)) {
				TheTacticalView->userLookAt(&radarWorld);
				s_touch.phase = TouchState::MINIMAP;
			}
		}
		else if (s_touch.phase == TouchState::PENDING && s_touch.battlefield) {
			s_touch.finger2 = event.tfinger.fingerID;
			s_touch.f2x = event.tfinger.x;
			s_touch.f2y = event.tfinger.y;
			const bool heldStill = (SDL_GetTicks() - s_touch.downTicks) >= HOLD_SELECT_MS;
			if (gxInTargetingMode()) {
				// A second finger while aiming cancels (same as a right click).
				queueClick(SDL_BUTTON_RIGHT, 0.5f * (float)winW, 0.5f * (float)winH, false);
				s_touch.phase = TouchState::LONGPRESSED;
			}
			else if (heldStill) {
				// Finger 1 has been resting on the screen: finger 2 selects.
				s_touch.selDownX = s_touch.selLastX = px;
				s_touch.selDownY = s_touch.selLastY = py;
				s_touch.selActive = false;
				s_touch.phase = TouchState::HOLDSELECT;
			}
			else {
				beginPan(winW, winH);
			}
		}
		else if (s_touch.phase == TouchState::GRABPAN) {
			// Second finger during a one-finger swipe: two-finger camera gesture.
			s_touch.finger2 = event.tfinger.fingerID;
			s_touch.f2x = event.tfinger.x;
			s_touch.f2y = event.tfinger.y;
			beginPan(winW, winH);
		}
		else if (s_touch.phase == TouchState::TARGETING) {
			// Second finger while aiming a power / placing a building: cancel.
			queueClick(SDL_BUTTON_RIGHT, 0.5f * (float)winW, 0.5f * (float)winH, false);
			s_touch.finger2 = event.tfinger.fingerID;
			s_touch.phase = TouchState::LONGPRESSED;
		}
		else if (s_touch.phase == TouchState::HOLDSELECT && s_touch.finger2 == 0) {
			// Another selection with the second finger while finger 1 keeps resting.
			s_touch.finger2 = event.tfinger.fingerID;
			s_touch.selDownX = s_touch.selLastX = px;
			s_touch.selDownY = s_touch.selLastY = py;
			s_touch.selActive = false;
		}
		// MINIMAP / LONGPRESSED / PAN with extra fingers: ignored
		break;

	case SDL_EVENT_FINGER_MOTION:
		if (event.tfinger.fingerID == s_touch.finger1) {
			s_touch.f1x = event.tfinger.x;
			s_touch.f1y = event.tfinger.y;
			s_touch.lastX = px;
			s_touch.lastY = py;
		} else if (s_touch.finger2 != 0 && event.tfinger.fingerID == s_touch.finger2 &&
		           (s_touch.phase == TouchState::PAN || s_touch.phase == TouchState::HOLDSELECT)) {
			s_touch.f2x = event.tfinger.x;
			s_touch.f2y = event.tfinger.y;
		} else {
			break;
		}

		if (s_touch.phase == TouchState::PENDING && event.tfinger.fingerID == s_touch.finger1) {
			const float moved = SDL_fabsf(px - s_touch.downX) + SDL_fabsf(py - s_touch.downY);
			if (gxInTargetingMode()) {
				// A special power / building placement is waiting for a target: the cursor (and the white
				// targeting circle or ghost building) follows the finger from the first movement; the
				// click happens when the finger lifts.
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
				s_touch.phase = TouchState::TARGETING;
				s_touch.lastMoveTicks = SDL_GetTicks();
				s_touch.lastMoveX = px;
				s_touch.lastMoveY = py;
			}
			else if (s_touch.battlefield &&
			         moved >= ((SDL_GetTicks() - s_touch.downTicks) < 250 ? TAP_DEAD_ZONE_PX : RESTED_SWIPE_PX)) {
				// A swipe: the map follows the finger (applied once per frame in updateTouchLongPress).
				// A finger that has been resting a while (e.g. holding for a rally point) drifts a few
				// millimetres, so after 0.25 s only a clearly larger movement counts as a swipe.
				const bool rested = (SDL_GetTicks() - s_touch.downTicks) >= 250;
				s_cam.hasPrev = true;
				s_cam.prevCx = rested ? px : s_touch.downX;
				s_cam.prevCy = rested ? py : s_touch.downY;
				s_cam.velX = s_cam.velY = 0.0f;
				s_cam.coasting = false;
				s_touch.phase = TouchState::GRABPAN;
				GXTOUCH_LOG("swipe starts (moved %.0f pt after %u ms)\n", moved, (unsigned)(SDL_GetTicks() - s_touch.downTicks));
			}
			else if (moved >= TAP_DEAD_ZONE_PX) {
				// A menu / control bar / dialog: keep the normal mouse drag (sliders, scroll bars, lists).
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
				                   s_touch.downX, s_touch.downY, SDL_BUTTON_LEFT);
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
				s_touch.phase = TouchState::UIDRAG;
			}
		}
		else if ((s_touch.phase == TouchState::TARGETING || s_touch.phase == TouchState::UIDRAG ||
		          s_touch.phase == TouchState::PLACE_DRAG) &&
		         event.tfinger.fingerID == s_touch.finger1) {
			sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
			if (s_touch.phase == TouchState::TARGETING &&
			    SDL_fabsf(px - s_touch.lastMoveX) + SDL_fabsf(py - s_touch.lastMoveY) >= 4.0f) {
				s_touch.lastMoveTicks = SDL_GetTicks();
				s_touch.lastMoveX = px;
				s_touch.lastMoveY = py;
			}
		}
		else if (s_touch.phase == TouchState::HOLDSELECT && event.tfinger.fingerID == s_touch.finger2) {
			s_touch.selLastX = px;
			s_touch.selLastY = py;
			if (!s_touch.selActive) {
				const float moved = SDL_fabsf(px - s_touch.selDownX) + SDL_fabsf(py - s_touch.selDownY);
				if (moved >= TAP_DEAD_ZONE_PX) {
					// Start the selection box where finger 2 first landed.
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.selDownX, s_touch.selDownY);
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
					                   s_touch.selDownX, s_touch.selDownY, SDL_BUTTON_LEFT);
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
					s_touch.selActive = true;
				}
			} else {
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
			}
		}
		// PAN / GRABPAN / MINIMAP: finger positions are stored above; the camera is moved once per
		// frame in updateTouchLongPress() so every move is measured against an up-to-date camera.
		break;

	case SDL_EVENT_FINGER_UP:
	case SDL_EVENT_FINGER_CANCELED:
		if (s_touch.phase == TouchState::HOLDSELECT) {
			if (s_touch.finger2 != 0 && event.tfinger.fingerID == s_touch.finger2) {
				if (s_touch.selActive) {
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
					                   s_touch.selLastX, s_touch.selLastY, SDL_BUTTON_LEFT);
					gxHotkeyNotifyTapDone();
				}
				else if (event.type != SDL_EVENT_FINGER_CANCELED) {
					// A tap with the second finger adds that unit to the selection (Shift + click).
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.selDownX, s_touch.selDownY);
					queueClick(SDL_BUTTON_LEFT, s_touch.selDownX, s_touch.selDownY, true);
				}
				s_touch.selActive = false;
				s_touch.finger2 = 0; // finger 1 keeps resting: it can select again
			}
			else if (event.tfinger.fingerID == s_touch.finger1) {
				if (s_touch.selActive) {
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
					                   s_touch.selLastX, s_touch.selLastY, SDL_BUTTON_LEFT);
					gxHotkeyNotifyTapDone();
				}
				s_touch.selActive = false;
				s_touch.finger2 = 0;
				s_touch.phase = TouchState::IDLE;
			}
			break;
		}
		if (event.tfinger.fingerID != s_touch.finger1 &&
		    !(s_touch.phase == TouchState::PAN && event.tfinger.fingerID == s_touch.finger2)) {
			break;
		}
		switch (s_touch.phase) {
			case TouchState::PENDING:
				// A CANCELED touch (incoming call, notification shade, palm rejection) must not become a
				// committed tap: that would be a phantom select/command/rally-point click.
				if (event.type == SDL_EVENT_FINGER_CANCELED) {
					break;
				}
				// With only buildings selected, a quick tap on empty ground clears the selection (the same as
				// the Cancel button) instead of silently moving the building's rally point. A 2 second hold
				// sets the rally point / waypoint on purpose.
				if (s_touch.battlefield && gxOnlyBuildingsSelected() && !gxObjectUnder(s_touch.downX, s_touch.downY, winW, winH)) {
					if (s_pointMode) {
						// "Point" was switched on: this tap sets where the building's new units gather.
						s_pointMode = false;
						gxHotkeyPointModeConsumed();
						sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
						queueClick(SDL_BUTTON_LEFT, s_touch.downX, s_touch.downY, false);
						GXTOUCH_LOG("point set at %.0f,%.0f\n", s_touch.downX, s_touch.downY);
						break;
					}
					if (TheInGameUI) {
						TheInGameUI->deselectAllDrawables();
					}
					GXTOUCH_LOG("tap on empty ground with only buildings selected: deselected\n");
					break;
				}
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
				queueClick(SDL_BUTTON_LEFT, s_touch.downX, s_touch.downY, false);
				GXTOUCH_LOG("tap click queued at %.0f,%.0f (battlefield=%d)\n", s_touch.downX, s_touch.downY, (int)s_touch.battlefield);
				break;
			case TouchState::PLACE_DRAG:
				// The building is placed (facing the dragged direction) when the left button is released.
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, px, py, SDL_BUTTON_LEFT);
				s_postPlaceFrames = 12; // afterwards the builder is deselected, once the placement went through
				gxHotkeyNotifyTapDone();
				GXTOUCH_LOG("building released at %.0f,%.0f\n", px, py);
				break;
			case TouchState::TARGETING:
				// Aiming ends where the finger lifts: put the cursor there, then click.
				if (event.type != SDL_EVENT_FINGER_CANCELED) {
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
					queueClick(SDL_BUTTON_LEFT, px, py, false);
				}
				break;
			case TouchState::PAN:
				if (event.type != SDL_EVENT_FINGER_CANCELED &&
				    (SDL_GetTicks() - s_touch.panStartTicks) <= TWO_FINGER_TAP_MS &&
				    s_touch.panTravel < TWO_FINGER_TAP_TRAVEL_PX) {
					// A quick two-finger tap cancels (a right click at mid-screen: it cancels a pending
					// command or building placement and otherwise deselects).
					queueClick(SDL_BUTTON_RIGHT, 0.5f * (float)winW, 0.5f * (float)winH, false);
					s_cam.coasting = false;
				} else {
					startCoast();
				}
				break;
			case TouchState::GRABPAN:
				// Let a quick flick keep sliding the camera for a moment.
				startCoast();
				break;
			case TouchState::UIDRAG: {
				// A drag that barely left the press point is a plain click.
				const float moved = SDL_fabsf(px - s_touch.downX) + SDL_fabsf(py - s_touch.downY);
				if (moved < 22.0f) {
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, s_touch.downX, s_touch.downY, SDL_BUTTON_LEFT);
				} else {
					sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, px, py, SDL_BUTTON_LEFT);
				}
				break;
			}
			default:
				break;
		}
		s_touch.finger2 = 0;
		s_touch.phase = TouchState::IDLE;
		break;
	}
}

// Called once per engine frame (not just per touch event): a perfectly
// stationary finger produces no SDL events, so the timers and camera gestures
// must be polled from the frame loop.
void updateTouchLongPress(SDL3Mouse *mouse, SDL_Window *window)
{
	// --- 1. staged click: button down one frame after the cursor arrived, button up one frame later
	if (s_tap.stage == 0) {
		sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, s_tap.x, s_tap.y, s_tap.button);
		s_tap.stage = -1;
		gxHotkeyNotifyTapDone();
		if (s_tap.shift) {
			s_shiftReleaseFrames = 3;
			s_tap.shift = false;
		}
		if (s_tap.wasPlacing) {
			s_postPlaceFrames = 12; // watch the next frames: did the building order go through?
		}
	}
	else if (s_tap.stage == 1) {
		s_tap.wasPlacing = (s_tap.button == SDL_BUTTON_LEFT && TheInGameUI != nullptr &&
		                    TheInGameUI->getPendingPlaceType() != nullptr);
		// Two quick taps close together are a double click (selects every unit of that type on screen).
		int clicks = 1;
		int tapWinW = 0, tapWinH = 0;
		SDL_GetWindowSize(window, &tapWinW, &tapWinH);
		// Only on the battlefield: on menu / control-bar buttons a fast second tap stays a normal click.
		if (s_tap.button == SDL_BUTTON_LEFT && gxTouchOnBattlefield(s_tap.x, s_tap.y, tapWinW, tapWinH)) {
			const Uint64 now = SDL_GetTicks();
			const float ddx = s_tap.x - s_lastTapX, ddy = s_tap.y - s_lastTapY;
			if (s_lastTapTicks != 0 && (now - s_lastTapTicks) <= DOUBLE_TAP_MS &&
			    SDL_sqrtf(ddx * ddx + ddy * ddy) <= DOUBLE_TAP_DIST_PX) {
				clicks = 2;
				s_lastTapTicks = 0;
			} else {
				s_lastTapTicks = now;
				s_lastTapX = s_tap.x;
				s_lastTapY = s_tap.y;
			}
		}
		sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN, s_tap.x, s_tap.y, s_tap.button, 0.0f, clicks);
		s_tap.stage = 0;
	}
	else if (s_tap.stage == 2) {
		s_tap.stage = 1;
	}
	if (s_shiftReleaseFrames > 0 && --s_shiftReleaseFrames == 0) {
		gxHotkeySendKey(SDL_SCANCODE_LSHIFT, false);
	}

	// After a building was placed the dozer should not stay selected: the next tap would send him
	// walking. Placement is over once the game no longer has a pending building type; if the spot
	// was invalid the placement stays active and nothing is deselected.
	if (s_postPlaceFrames > 0) {
		--s_postPlaceFrames;
		if (TheInGameUI && TheInGameUI->getPendingPlaceType() == nullptr) {
			TheInGameUI->deselectAllDrawables();
			s_postPlaceFrames = 0;
		}
	}

	// --- 2. camera gestures, applied once per frame against the current camera
	int winW = 0, winH = 0;
	SDL_GetWindowSize(window, &winW, &winH);
	if (winW > 0 && winH > 0) {
		switch (s_touch.phase) {
		case TouchState::GRABPAN: {
			const float cx = s_touch.f1x * (float)winW;
			const float cy = s_touch.f1y * (float)winH;
			if (s_cam.hasPrev) {
				panCameraByScreen(s_cam.prevCx, s_cam.prevCy, cx, cy, winW, winH);
			}
			s_cam.prevCx = cx;
			s_cam.prevCy = cy;
			s_cam.hasPrev = true;
			break;
		}
		case TouchState::PAN: {
			const float x1 = s_touch.f1x * (float)winW, y1 = s_touch.f1y * (float)winH;
			const float x2 = s_touch.f2x * (float)winW, y2 = s_touch.f2y * (float)winH;
			const float cx = 0.5f * (x1 + x2), cy = 0.5f * (y1 + y2);
			const float ddx = x2 - x1, ddy = y2 - y1;
			const float dist = SDL_sqrtf(ddx * ddx + ddy * ddy);
			const float ang = SDL_atan2f(ddy, ddx);
			if (!s_cam.hasPrev || dist < 1.0f) {
				s_cam.prevCx = cx; s_cam.prevCy = cy; s_cam.prevDist = dist; s_cam.prevAng = ang;
				s_cam.hasPrev = (dist >= 1.0f);
				break;
			}
			// The fingers' centre moving = move the map; spreading / pinching = zoom; twisting = rotate.
			// Zoom and rotate can happen together; the map only moves along when that movement is not
			// just the side effect of a pinch or twist (so zooming keeps the camera still).
			const float dPan = SDL_sqrtf((cx - s_cam.prevCx) * (cx - s_cam.prevCx) + (cy - s_cam.prevCy) * (cy - s_cam.prevCy));
			const float dZoom = SDL_fabsf(dist - s_cam.prevDist);
			float dAng = ang - s_cam.prevAng;
			const float PI_F = 3.14159265f;
			while (dAng > PI_F) dAng -= 2.0f * PI_F;
			while (dAng < -PI_F) dAng += 2.0f * PI_F;
			const float dRot = SDL_fabsf(dAng) * dist * 0.5f; // arc length travelled by each finger
			s_touch.panTravel += dPan + dZoom + dRot;
			const float other = (dZoom > dRot) ? dZoom : dRot;
			if (dPan > GESTURE_DEADBAND_PX && dPan >= 0.7f * other) {
				panCameraByScreen(s_cam.prevCx, s_cam.prevCy, cx, cy, winW, winH);
			}
			if (dZoom > GESTURE_DEADBAND_PX && s_touch.pinchDist > 1.0f) {
				const float mx = 0.5f * (float)winW, my = 0.5f * (float)winH;
				for (int tick = 0; tick < 4; ++tick) {
					const float ratio = dist / s_touch.pinchDist;
					if (ratio > 1.0f + PINCH_STEP_RATIO || ratio < 1.0f - PINCH_STEP_RATIO) {
						const bool zoomIn = ratio > 1.0f;
						// Park the cursor mid-screen first so the zoom never triggers edge scrolling.
						sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, mx, my);
						sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_WHEEL, mx, my, 0, zoomIn ? 1.0f : -1.0f);
						s_touch.pinchDist *= zoomIn ? (1.0f + PINCH_STEP_RATIO) : (1.0f - PINCH_STEP_RATIO);
					} else {
						break;
					}
				}
			}
			if (dRot > GESTURE_DEADBAND_PX) {
				s_cam.rotAccum += ROTATE_GAIN * dAng; // eased in below
			}
			s_cam.prevCx = cx; s_cam.prevCy = cy; s_cam.prevDist = dist; s_cam.prevAng = ang;
			break;
		}
		case TouchState::MINIMAP: {
			// The camera sits where the finger is on the minimap.
			Coord3D radarWorld;
			if (TheTacticalView && gxRadarWorldPointAt(s_touch.f1x * (float)winW, s_touch.f1y * (float)winH,
			                                           winW, winH, &radarWorld)) {
				TheTacticalView->userLookAt(&radarWorld);
			}
			break;
		}
		case TouchState::TARGETING:
			if (gxPlacingBuilding() && (SDL_GetTicks() - s_touch.lastMoveTicks) >= PLACE_ANCHOR_MS) {
				startPlacementDrag(mouse, window, s_touch.lastX, s_touch.lastY);
			} else {
				// A held target near the edge pulls the camera along.
				autoScrollAtEdges(s_touch.f1x, s_touch.f1y, winW, winH);
			}
			break;
		case TouchState::HOLDSELECT:
			if (s_touch.selActive) {
				autoScrollAtEdges(s_touch.f2x, s_touch.f2y, winW, winH);
			}
			break;
		case TouchState::PENDING:
			if (gxPlacingBuilding() && (SDL_GetTicks() - s_touch.downTicks) >= PLACE_ANCHOR_MS) {
				// A finger resting on the spot where the building should go: fix it there, then turn it.
				startPlacementDrag(mouse, window, s_touch.downX, s_touch.downY);
			}
			else if (gxInTargetingMode()) {
				autoScrollAtEdges(s_touch.f1x, s_touch.f1y, winW, winH);
			}
			break;
		default:
			break;
		}

		// --- 3. quick flick: the camera keeps sliding and slows down
		if (s_touch.phase == TouchState::IDLE && s_cam.coasting && TheTacticalView) {
			Coord3D np = TheTacticalView->getPosition();
			np.x += s_cam.velX;
			np.y += s_cam.velY;
			TheTacticalView->userLookAt(&np);
			s_cam.velX *= COAST_DECAY;
			s_cam.velY *= COAST_DECAY;
			if (SDL_sqrtf(s_cam.velX * s_cam.velX + s_cam.velY * s_cam.velY) < COAST_STOP_MIN) {
				s_cam.coasting = false;
			}
		}

		// --- 3b. camera rotation eases in (and keeps easing out after the fingers lift) instead of jumping
		if (TheTacticalView && SDL_fabsf(s_cam.rotAccum) > 0.0003f) {
			const float step = s_cam.rotAccum * 0.5f;
			TheTacticalView->userSetAngle(TheTacticalView->getAngle() + step);
			s_cam.rotAccum -= step;
		} else {
			s_cam.rotAccum = 0.0f;
		}
	}

	// --- 4. holds: right click (deselect) after 0.6 s, or -- with only buildings selected -- a left click
	//     (rally / waypoint) after 2 s. Never while aiming a target, where a click would be wrong.
	if (s_touch.phase == TouchState::PENDING && !gxInTargetingMode()) {
		const Uint64 held = SDL_GetTicks() - s_touch.downTicks;
		const bool buildingsOnly = s_touch.battlefield && gxOnlyBuildingsSelected();
		if (buildingsOnly) {
			if (held >= RALLY_HOLD_MS && !gxObjectUnder(s_touch.downX, s_touch.downY, winW, winH)) {
				sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
				queueClick(SDL_BUTTON_LEFT, s_touch.downX, s_touch.downY, false);
				s_touch.phase = TouchState::LONGPRESSED;
				GXTOUCH_LOG("rally/waypoint hold fired at %.0f,%.0f after %u ms\n", s_touch.downX, s_touch.downY, (unsigned)held);
			}
			else if (held >= RALLY_HOLD_MS && !s_logObjectUnderOnce) {
				s_logObjectUnderOnce = true;
				GXTOUCH_LOG("rally hold NOT fired: an object is under the finger\n");
			}
		}
		else if (held >= LONG_PRESS_MS && s_touch.battlefield) {
			// No LMB was sent yet (deferred), so this is a pure right-click.
			sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, s_touch.downX, s_touch.downY);
			sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
			                   s_touch.downX, s_touch.downY, SDL_BUTTON_RIGHT);
			sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
			                   s_touch.downX, s_touch.downY, SDL_BUTTON_RIGHT);
			s_touch.phase = TouchState::LONGPRESSED;
			GXTOUCH_LOG("right-click hold fired (%u ms)\n", (unsigned)held);
		}
	}
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// Bridge for the on-screen hotkey bar (iOSHotkeyOverlay.mm)
// ---------------------------------------------------------------------------
extern SDL_Window* TheSDL3Window;

void gxHotkeySendKey(int scancode, bool down)
{
	SDL3Keyboard* keyboard = TheKeyboard ? dynamic_cast<SDL3Keyboard*>(TheKeyboard) : nullptr;
	if (!keyboard) {
		return;
	}
	SDL_Event ev;
	SDL_zero(ev);
	ev.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
	ev.key.scancode = (SDL_Scancode)scancode;
	ev.key.down = down;
	ev.key.repeat = false;
	keyboard->addSDLEvent(&ev);
}

// Cancel: a right click at mid-screen cancels a pending command or building placement, and otherwise
// deselects (the game's default mouse scheme). Sent as a proper staged click.
void gxHotkeySetPointMode(bool on)
{
	s_pointMode = on;
}

void gxHotkeyCancel()
{
	if (!TheSDL3Window) {
		return;
	}
	int winW = 0, winH = 0;
	SDL_GetWindowSize(TheSDL3Window, &winW, &winH);
	queueClick(SDL_BUTTON_RIGHT, 0.5f * (float)winW, 0.5f * (float)winH, false);
}

// Put the camera back to the game's normal direction, tilt and zoom.
void gxHotkeyResetView()
{
	if (!TheTacticalView) {
		return;
	}
	s_cam.rotAccum = 0.0f;
	TheTacticalView->userSetAngleToDefault();
	TheTacticalView->userSetPitchToDefault();
	TheTacticalView->userSetZoomToDefault();
}

// Select every ground combat unit (soldiers and vehicles) on the map; not buildings, aircraft,
// dozers/workers, harvesters or units that are inside a building or transport.
void gxHotkeySelectArmy()
{
	if (!TheInGameUI) {
		return;
	}
	KindOfMaskType clear;
	clear.set(KINDOF_DOZER);
	clear.set(KINDOF_HARVESTER);
	clear.set(KINDOF_IGNORES_SELECT_ALL);
	clear.set(KINDOF_AIRCRAFT);
	clear.set(KINDOF_STRUCTURE);
	TheInGameUI->deselectAllDrawables();
	KindOfMaskType infantry;
	infantry.set(KINDOF_INFANTRY);
	TheInGameUI->selectAllUnitsByTypeAcrossMap(infantry, clear);
	KindOfMaskType vehicles;
	vehicles.set(KINDOF_VEHICLE);
	TheInGameUI->selectAllUnitsByTypeAcrossMap(vehicles, clear);
}

// Select all combat aircraft on the map (the game's own "select all aircraft" rule).
void gxHotkeySelectAir()
{
	if (!TheInGameUI) {
		return;
	}
	KindOfMaskType clear;
	clear.set(KINDOF_DOZER);
	clear.set(KINDOF_HARVESTER);
	clear.set(KINDOF_IGNORES_SELECT_ALL);
	TheInGameUI->deselectAllDrawables();
	KindOfMaskType aircraft;
	aircraft.set(KINDOF_AIRCRAFT);
	TheInGameUI->selectAllUnitsByTypeAcrossMap(aircraft, clear);
}
#endif // TARGET_OS_IPHONE

namespace {

Bool DecodeNextUtf8Codepoint(const char* text, size_t length, size_t& offset, UnsignedInt& outCodepoint)
{
	outCodepoint = 0;
	if (!text || offset >= length) {
		return false;
	}

	const unsigned char first = static_cast<unsigned char>(text[offset]);
	if (first == 0) {
		return false;
	}

	if (first < 0x80) {
		outCodepoint = first;
		offset += 1;
		return true;
	}

	if ((first & 0xE0) == 0xC0 && offset + 1 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		if ((second & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x1F) << 6) | (second & 0x3F);
			offset += 2;
			return true;
		}
	}

	if ((first & 0xF0) == 0xE0 && offset + 2 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		const unsigned char third = static_cast<unsigned char>(text[offset + 2]);
		if ((second & 0xC0) == 0x80 && (third & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x0F) << 12) | ((second & 0x3F) << 6) | (third & 0x3F);
			offset += 3;
			return true;
		}
	}

	if ((first & 0xF8) == 0xF0 && offset + 3 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		const unsigned char third = static_cast<unsigned char>(text[offset + 2]);
		const unsigned char fourth = static_cast<unsigned char>(text[offset + 3]);
		if ((second & 0xC0) == 0x80 && (third & 0xC0) == 0x80 && (fourth & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x07) << 18) | ((second & 0x3F) << 12) | ((third & 0x3F) << 6) | (fourth & 0x3F);
			offset += 4;
			return true;
		}
	}

	// Invalid UTF-8 sequence: skip one byte and keep processing.
	offset += 1;
	return false;
}

}

/**
 * Constructor: Initialize SDL3 game engine state
 */
SDL3GameEngine::SDL3GameEngine()
	: GameEngine(),
	  m_SDLWindow(nullptr),
	  m_IsInitialized(false),
	  m_IsActive(false),
	  m_IsTextInputActive(false),
	  m_TextInputFocusWindow(nullptr)
{
	fprintf(stderr, "DEBUG: SDL3GameEngine::SDL3GameEngine() created\n");
}

/**
 * Destructor: Cleanup SDL3 resources
 */
SDL3GameEngine::~SDL3GameEngine()
{
	if (m_SDLWindow && m_IsTextInputActive) {
		SDL_StopTextInput(m_SDLWindow);
		m_IsTextInputActive = false;
		m_TextInputFocusWindow = nullptr;
	}

	if (m_IsInitialized) {
		// Window cleanup is done in reset/shutdown
	}
	fprintf(stderr, "DEBUG: SDL3GameEngine::~SDL3GameEngine() destroyed\n");
}

/**
 * From GameEngine: init() - initialize subsystems
 * 
 * GeneralsX @bugfix felipebraz 16/02/2026
 * Simplified to follow fighter19 pattern - SDL3/Vulkan initialized in SDL3Main.cpp
 * before GameEngine is created. This init() only delegates to parent GameEngine::init().
 * ApplicationHWnd and TheSDL3Window are already set by main() before this is called.
 */
void SDL3GameEngine::init(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::init() starting\n");

	if (TheGlobalData && TheGlobalData->m_headless) {
		// GeneralsX @bugfix Copilot 17/05/2026 Allow headless replay path to initialize engine subsystems without an SDL window.
		fprintf(stderr, "INFO: SDL3GameEngine::init() headless mode - skipping SDL window binding\n");
		m_SDLWindow = nullptr;
		m_IsInitialized = true;
		m_IsActive = true;
		GameEngine::init();
		return;
	}

	// Verify window was created by SDL3Main.cpp
	extern SDL_Window* TheSDL3Window;
	extern HWND ApplicationHWnd;
	
	if (!TheSDL3Window || !ApplicationHWnd) {
		fprintf(stderr, "FATAL: SDL3 window not initialized before GameEngine::init()\n");
		fprintf(stderr, "FATAL: TheSDL3Window=%p, ApplicationHWnd=%p\n", TheSDL3Window, ApplicationHWnd);
		return;
	}

	// Store window reference locally
	m_SDLWindow = TheSDL3Window;
	m_IsInitialized = true;
	m_IsActive = true;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Lifecycle events can fire outside the poll cycle on iOS; catch them
	// immediately so rendering halts before the process is suspended.
	SDL_AddEventWatch(iosLifecycleWatcher, nullptr);
#endif

	fprintf(stderr, "INFO: SDL3GameEngine using pre-initialized window\n");

	// Call parent init to initialize game subsystems
	GameEngine::init();
}

/**
 * From GameEngine: reset() - reset system to starting state
 */
void SDL3GameEngine::reset(void)
{
	fprintf(stderr, "DEBUG: SDL3GameEngine::reset()\n");
	if (m_SDLWindow && m_IsTextInputActive) {
		SDL_StopTextInput(m_SDLWindow);
		m_IsTextInputActive = false;
		m_TextInputFocusWindow = nullptr;
	}
	GameEngine::reset();
}

/**
 * From GameEngine: update() - per-frame update
 */
void SDL3GameEngine::update(void)
{
	pollSDL3Events();
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Pause sim + render while backgrounded OR inactive (see iosLifecycleWatcher).
	// Acquiring a Metal drawable in these windows fights iOS for the layer and,
	// across repeated suspend/switcher cycles, crashes MoltenVK. Keep polling so
	// we still catch the resume events; just don't touch the GPU.
	if (iosShouldPauseRendering()) {
		// iOS has the screen (incoming call, banner, notification shade, app switcher): the picture and the
		// simulation wait, but keep the multiplayer connection serviced (the game's own "lite update", the
		// same one used on loading screens) so the other players still hear from us and do not drop us.
		if (TheNetwork) {
			TheNetwork->liteupdate();
		}
		SDL_Delay(50);
		return;
	}

	// Cap drawing at 60 frames per second. The game logic runs at 30 per second, so drawing 120
	// full-resolution frames a second only heats the phone and drains the battery.
	if (TheWritableGlobalData) {
		TheWritableGlobalData->m_useFpsLimit = TRUE;
	}
	if (TheFramePacer) {
		TheFramePacer->enableFramesPerSecondLimit(TRUE);
		TheFramePacer->setFramesPerSecondLimit(60);
	}

	// On-screen hotkey bar: created once, shown only while a match is running.
	{
		static bool s_overlayCreated = false;
		static int s_overlayShown = -1;
		if (!s_overlayCreated && m_SDLWindow) {
			gxHotkeyOverlayInit(m_SDLWindow);
			s_overlayCreated = true;
		}
		// The buttons stay out of the way of the game's own menus (Options / Exit / Return to game).
		bool menuOpen = false;
		if (TheInGameUI && TheInGameUI->isQuitMenuVisible()) {
			menuOpen = true;
		} else if (TheWindowManager) {
			GameWindow *optionsWin = TheWindowManager->winGetWindowFromId(nullptr, NAMEKEY("OptionsMenu.wnd:OptionsMenuParent"));
			menuOpen = (optionsWin != nullptr && !optionsWin->winIsHidden());
		}
		const bool inMatch = TheGameLogic && TheGameLogic->isInGame() &&
			GameLogic::isInInteractiveGame(TheGameLogic->getGameMode()) && !menuOpen;
		if (s_overlayCreated && (int)inMatch != s_overlayShown) {
			gxHotkeyOverlaySetVisible(inMatch);
			s_overlayShown = (int)inMatch;
		}
		// Put the quick buttons right above the minimap (the game's own radar window), centred over it.
		if (s_overlayCreated && inMatch && TheWindowManager && TheDisplay && m_SDLWindow) {
			int winW = 0, winH = 0;
			SDL_GetWindowSize(m_SDLWindow, &winW, &winH);
			float left = -1.0f, top = -1.0f, width = 0.0f;
			GameWindow *radarWin = TheWindowManager->winGetWindowFromId(nullptr, NAMEKEY("ControlBar.wnd:LeftHUD"));
			if (radarWin && !radarWin->winIsHidden() && winW > 0 && TheDisplay->getWidth() > 0) {
				ICoord2D pos, size;
				radarWin->winGetScreenPosition(&pos.x, &pos.y);
				radarWin->winGetSize(&size.x, &size.y);
				left = (float)pos.x * (float)winW / (float)TheDisplay->getWidth();
				top = (float)pos.y * (float)winH / (float)TheDisplay->getHeight();
				width = (float)size.x * (float)winW / (float)TheDisplay->getWidth();
			}
			gxHotkeyOverlaySetQuickAnchor(left, top, width);
		}
	}

	// Allow zooming out further than the PC default (a phone screen is small). Done once; the game's
	// own camera limit is recalculated from this value.
	{
		static bool s_zoomPatched = false;
		if (!s_zoomPatched && TheWritableGlobalData && TheTacticalView && TheGameLogic &&
		    TheGameLogic->isInGame() && GameLogic::isInInteractiveGame(TheGameLogic->getGameMode())) {
			const Real wantedMax = 370.0f; // was 520: too far out shows the black map edge; 370 matches the best screenshot
			if (TheWritableGlobalData->m_maxCameraHeight < wantedMax) {
				TheWritableGlobalData->m_maxCameraHeight = wantedMax;
			}
			TheTacticalView->setCameraHeightAboveGroundLimitsToDefault();
			s_zoomPatched = true;
		}
	}
#endif
	GameEngine::update();
}

/**
 * From GameEngine: execute() - main game loop
 */
void SDL3GameEngine::execute(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::execute() - entering main loop\n");
	GameEngine::execute();
	fprintf(stderr, "INFO: SDL3GameEngine::execute() - exited main loop\n");
}

/**
 * From GameEngine: serviceWindowsOS() - native OS service
 * On Linux, process SDL3 events
 */
void SDL3GameEngine::serviceWindowsOS(void)
{
	pollSDL3Events();
}

/**
 * Check if game has OS focus
 */
Bool SDL3GameEngine::isActive(void)
{
	return m_IsActive;
}

/**
 * Set OS focus status
 */
void SDL3GameEngine::setIsActive(Bool isActive)
{
	m_IsActive = isActive;
}

/**
 * Poll and process SDL3 events
 * Handles keyboard, mouse, window, and quit events
 */
void SDL3GameEngine::pollSDL3Events(void)
{
	if (!m_SDLWindow) {
		return;
	}

	updateTextInputState();

	SDL_Event event;
	while (SDL_PollEvent(&event)) {
		switch (event.type) {
			case SDL_EVENT_QUIT:
				m_quitting = true;
				break;

			case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
				m_quitting = true;
				break;

			case SDL_EVENT_WINDOW_FOCUS_GAINED:
				m_IsActive = true;
				if (TheMouse) {
					TheMouse->regainFocus();
					TheMouse->refreshCursorCapture();
				}
				break;

			case SDL_EVENT_WINDOW_FOCUS_LOST:
				m_IsActive = false;
				if (m_IsTextInputActive) {
					SDL_StopTextInput(m_SDLWindow);
					m_IsTextInputActive = false;
					m_TextInputFocusWindow = nullptr;
				}
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			// App suspension/resume: mirror the desktop focus handling so audio
			// and mouse state pause cleanly (the render gate lives in update()).
			case SDL_EVENT_DID_ENTER_BACKGROUND:
				m_IsActive = false;
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

			case SDL_EVENT_DID_ENTER_FOREGROUND:
				m_IsActive = true;
				if (TheMouse) {
					TheMouse->regainFocus();
					TheMouse->refreshCursorCapture();
				}
				break;
#endif

			case SDL_EVENT_WINDOW_MOUSE_ENTER:
				if (TheMouse) {
					TheMouse->onCursorMovedInside();
				}
				break;

			case SDL_EVENT_WINDOW_MOUSE_LEAVE:
				if (TheMouse) {
					TheMouse->onCursorMovedOutside();
				}
				break;

			case SDL_EVENT_KEY_DOWN:
			case SDL_EVENT_KEY_UP:
				// Fighter19 pattern: direct addSDLEvent() call
				// GeneralsX @refactor felipebraz 16/02/2026 Simplified event routing
				if (TheKeyboard) {
					SDL3Keyboard* keyboard = dynamic_cast<SDL3Keyboard*>(TheKeyboard);
					if (keyboard) {
						keyboard->addSDLEvent(&event);
					}
				}
				break;

			case SDL_EVENT_TEXT_INPUT:
				forwardTextInputEvent(event.text.text);
				break;

			case SDL_EVENT_MOUSE_MOTION:
			case SDL_EVENT_MOUSE_BUTTON_DOWN:
			case SDL_EVENT_MOUSE_BUTTON_UP:
			case SDL_EVENT_MOUSE_WHEEL:
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
				// Belt-and-braces: drop SDL's own touch-synthesized mouse events.
				// The gesture translator owns all touch->mouse conversion; double
				// delivery would produce phantom second clicks.
				if (event.motion.which == SDL_TOUCH_MOUSEID) {
					break;
				}
#endif
				// Fighter19 pattern: direct addSDLEvent() call with raw SDL_Event
				// GeneralsX @refactor felipebraz 16/02/2026 Simplified event routing
				if (TheMouse) {
					SDL3Mouse* mouse = dynamic_cast<SDL3Mouse*>(TheMouse);
					if (mouse) {
						mouse->addSDLEvent(&event);
					}
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			case SDL_EVENT_FINGER_DOWN:
			case SDL_EVENT_FINGER_MOTION:
			case SDL_EVENT_FINGER_UP:
			case SDL_EVENT_FINGER_CANCELED:
				if (TheMouse && m_SDLWindow) {
					SDL3Mouse* mouse = dynamic_cast<SDL3Mouse*>(TheMouse);
					if (mouse) {
						handleTouchEvent(mouse, m_SDLWindow, event);
					}
				}
				break;
#endif

			case SDL_EVENT_WINDOW_RESIZED:
				handleWindowEvent(event.window);
				break;

			default:
				// Ignore other events for now
				break;
		}

		updateTextInputState();
	}

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Poll the long-press timer every frame; a stationary finger emits no events.
	if (TheMouse && m_SDLWindow) {
		SDL3Mouse* touchMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (touchMouse) {
			updateTouchLongPress(touchMouse, m_SDLWindow);
		}
	}
#endif
}

// GeneralsX @bugfix felipebraz 01/04/2026 Enable SDL text input only while an entry gadget owns focus.
void SDL3GameEngine::updateTextInputState(void)
{
	if (!m_SDLWindow || !TheWindowManager) {
		return;
	}

	GameWindow* focusedWindow = TheWindowManager->winGetFocus();
	const Bool wantsTextInput =
		focusedWindow != nullptr && BitIsSet(focusedWindow->winGetStyle(), GWS_ENTRY_FIELD);

	if (wantsTextInput) {
		if (!m_IsTextInputActive) {
			if (SDL_StartTextInput(m_SDLWindow)) {
				m_IsTextInputActive = true;
			}
		}
		m_TextInputFocusWindow = focusedWindow;
	} else {
		if (m_IsTextInputActive) {
			SDL_StopTextInput(m_SDLWindow);
			m_IsTextInputActive = false;
		}
		m_TextInputFocusWindow = nullptr;
	}
}

// GeneralsX @bugfix felipebraz 01/04/2026 Forward SDL UTF-8 text input through existing GWM_IME_CHAR path.
void SDL3GameEngine::forwardTextInputEvent(const char* utf8Text)
{
	if (!utf8Text || !TheWindowManager) {
		return;
	}

	// GeneralsX @bugfix felipebraz 01/04/2026 Use tracked text-input focus window to keep SDL text delivery stable.
	GameWindow* targetWindow = m_TextInputFocusWindow;
	if (!targetWindow || !BitIsSet(targetWindow->winGetStyle(), GWS_ENTRY_FIELD)) {
		return;
	}

	const size_t textLength = strlen(utf8Text);
	size_t offset = 0;
	while (offset < textLength) {
		UnsignedInt codepoint = 0;
		if (!DecodeNextUtf8Codepoint(utf8Text, textLength, offset, codepoint)) {
			continue;
		}

		// GeneralsX @bugfix felipebraz 01/04/2026 Clamp IME char forwarding to BMP and reject UTF-16 surrogate range.
		if (codepoint == 0 || codepoint > 0x10FFFFU) {
			continue;
		}

		if (codepoint >= 0xD800U && codepoint <= 0xDFFFU) {
			continue;
		}

		if (codepoint > 0xFFFFU) {
			continue;
		}

		const WideChar wideCharacter = static_cast<WideChar>(codepoint);
		TheWindowManager->winSendInputMsg(targetWindow, GWM_IME_CHAR, static_cast<WindowMsgData>(wideCharacter), 0);
	}
}

/**
 * Handle keyboard event -dispatch to Keyboard manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleKeyboardEvent(const SDL_KeyboardEvent& event)
{
	// Dispatch to SDL3Keyboard if available
	if (TheKeyboard) {
		SDL3Keyboard* sdlKeyboard = dynamic_cast<SDL3Keyboard*>(TheKeyboard);
		if (sdlKeyboard) {
			sdlKeyboard->addSDL3KeyEvent(event);
		}
	}
}

/**
 * Handle mouse motion event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseMotionEvent(const SDL_MouseMotionEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseMotionEvent(event);
		}
	}
}

/**
 * Handle mouse button event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseButtonEvent(const SDL_MouseButtonEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseButtonEvent(event);
		}
	}
}

/**
 * Handle mouse wheel event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseWheelEvent(const SDL_MouseWheelEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseWheelEvent(event);
		}
	}
}

/**
 * Handle window event (resize, etc.)
 */
void SDL3GameEngine::handleWindowEvent(const SDL_WindowEvent& event)
{
	// TODO: Phase 2 - Handle window resize, notify graphics subsystem
	// fprintf(stderr, "DEBUG: Window event (type=%d)\n", event.type);
}

/**
 * Factory Methods for GameEngine subsystems
 * TheSuperHackers @build felipebraz 13/02/2026
 * Implementations in .cpp to provide complete type definitions and avoid circular includes
 */

LocalFileSystem *SDL3GameEngine::createLocalFileSystem(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createLocalFileSystem() -> StdLocalFileSystem\n");
	return NEW StdLocalFileSystem;
}

ArchiveFileSystem *SDL3GameEngine::createArchiveFileSystem(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createArchiveFileSystem() -> StdBIGFileSystem\n");
	return NEW StdBIGFileSystem;
}

GameLogic *SDL3GameEngine::createGameLogic(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createGameLogic() -> W3DGameLogic\n");
	return NEW W3DGameLogic;
}

GameClient *SDL3GameEngine::createGameClient(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createGameClient() -> W3DGameClient\n");
	return NEW W3DGameClient;
}

ModuleFactory *SDL3GameEngine::createModuleFactory(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createModuleFactory() -> W3DModuleFactory\n");
	return NEW W3DModuleFactory;
}

ThingFactory *SDL3GameEngine::createThingFactory(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createThingFactory() -> W3DThingFactory\n");
	return NEW W3DThingFactory;
}

FunctionLexicon *SDL3GameEngine::createFunctionLexicon(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createFunctionLexicon() -> W3DFunctionLexicon\n");
	return NEW W3DFunctionLexicon;
}

// GeneralsX @bugfix Copilot 15/04/2026 Match upstream GameEngine pure-virtual signature after sync.
Radar *SDL3GameEngine::createRadar(Bool dummy)
{
	// GeneralsX @bugfix fbraz 04/05/2026 Respect headless mode and create dummy radar.
	// Upstream reference: Win32GameEngine headless factory behavior, TheSuperHackers/GeneralsGameCode
	// https://github.com/TheSuperHackers/GeneralsGameCode
	if (dummy) {
		fprintf(stderr, "INFO: SDL3GameEngine::createRadar() -> RadarDummy (headless)\n");
		return NEW RadarDummy;
	}
	fprintf(stderr, "INFO: SDL3GameEngine::createRadar() -> W3DRadar\n");
	return NEW W3DRadar;
}

// GeneralsX @bugfix Copilot 24/03/2026 Match upstream GameEngine pure-virtual signature after sync.
ParticleSystemManager* SDL3GameEngine::createParticleSystemManager(Bool dummy)
{
	// GeneralsX @bugfix fbraz 04/05/2026 Respect headless mode and create dummy particle manager.
	if (dummy) {
		fprintf(stderr, "INFO: SDL3GameEngine::createParticleSystemManager() -> ParticleSystemManagerDummy (headless)\n");
		return NEW ParticleSystemManagerDummy;
	}
	fprintf(stderr, "INFO: SDL3GameEngine::createParticleSystemManager() -> W3DParticleSystemManager\n");
	return NEW W3DParticleSystemManager;
}

WebBrowser *SDL3GameEngine::createWebBrowser(void)
{
	// WebBrowser uses Windows COM (CComObject<W3DWebBrowser>)
	// Not available on Linux - return nullptr
	fprintf(stderr, "WARNING: WebBrowser not available on Linux platform\n");
	return nullptr;
}

/**
 * Factory method: AudioManager
 * Select audio backend based on compile flags
 * GeneralsX @bugfix Copilot 15/04/2026 Match upstream GameEngine pure-virtual signature after sync.
 */
AudioManager *SDL3GameEngine::createAudioManager(Bool dummy)
{
	(void)dummy;
	fprintf(stderr, "INFO: SDL3GameEngine::createAudioManager()\n");

#ifdef SAGE_USE_OPENAL
	fprintf(stderr, "INFO: Creating OpenAL audio backend\n");
	return new OpenALAudioManager();
#else
	fprintf(stderr, "INFO: Audio backend not available (SAGE_USE_OPENAL not defined)\n");
	fprintf(stderr, "WARNING: Falls back to parent implementation or silent mode\n");
	return GameEngine::createAudioManager();  // Call parent (may return stub)
#endif
}

#endif // !_WIN32

