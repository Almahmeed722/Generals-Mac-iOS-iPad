// On-screen hotkey buttons for the iOS build.
//
// A transparent UIKit layer sits above the SDL game view. Touches that miss every button fall
// straight through to the game. Three groups of buttons:
//   - a quick strip just above the money / power bars (Cancel, Guard, Reset view),
//   - a strip along the top for control groups (Save + 1..9) that can be folded away,
//   - a side bar (open it with the arrow on the right edge) with the other orders.
// Most buttons send the same key presses a keyboard would (the engine already reads SDL keyboard
// events); a few call small helpers in the engine (select army, select air force, cancel, reset view).
//
// Button frame artwork is optional: if HotkeyUI/frame.png is bundled with the app it is used,
// otherwise a plain cyan-outlined button is drawn.

#include "iOSHotkeys.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <cstdio>

namespace {

enum KeyKind {
	KIND_KEY,       // press = key down, release = key up
	KIND_ONESHOT,   // latch: key held until the next map tap finishes (Add = Shift, Force fire = Ctrl)
	KIND_TOGGLE,    // latch: key held until tapped again (Waypoint = Alt)
	KIND_SETGROUP,  // next number button creates a control group instead of selecting it
	KIND_NUMBER,    // group number 1-9
	KIND_ACTION     // calls an engine helper
};

enum Action { ACT_ARMY = 1, ACT_AIR = 2, ACT_RESET_VIEW = 3, ACT_CANCEL = 4 };
enum Place { PLACE_SIDE = 0, PLACE_QUICK = 1, PLACE_GROUPS = 2 };

struct KeyDef {
	const char *label;
	const char *symbol; // SF Symbol name
	KeyKind kind;
	int code;           // SDL scancode, or an Action
	Place place;
};

const KeyDef kKeys[] = {
	// quick strip (above the money / power bars)
	{ "Cancel",     "xmark.circle.fill",                    KIND_ACTION,  ACT_CANCEL,     PLACE_QUICK },
	{ "Guard",      "hand.raised.fill",                     KIND_KEY,     SDL_SCANCODE_G, PLACE_QUICK },
	{ "Reset view", "arrow.triangle.2.circlepath",          KIND_ACTION,  ACT_RESET_VIEW, PLACE_QUICK },

	// control groups (top strip)
	{ "Save",       "square.and.arrow.down.fill",           KIND_SETGROUP,0,              PLACE_GROUPS },
	{ "1", "", KIND_NUMBER, SDL_SCANCODE_1, PLACE_GROUPS },
	{ "2", "", KIND_NUMBER, SDL_SCANCODE_2, PLACE_GROUPS },
	{ "3", "", KIND_NUMBER, SDL_SCANCODE_3, PLACE_GROUPS },
	{ "4", "", KIND_NUMBER, SDL_SCANCODE_4, PLACE_GROUPS },
	{ "5", "", KIND_NUMBER, SDL_SCANCODE_5, PLACE_GROUPS },
	{ "6", "", KIND_NUMBER, SDL_SCANCODE_6, PLACE_GROUPS },
	{ "7", "", KIND_NUMBER, SDL_SCANCODE_7, PLACE_GROUPS },
	{ "8", "", KIND_NUMBER, SDL_SCANCODE_8, PLACE_GROUPS },
	{ "9", "", KIND_NUMBER, SDL_SCANCODE_9, PLACE_GROUPS },

	// side bar
	{ "Army",       "shield.fill",                          KIND_ACTION,  ACT_ARMY,       PLACE_SIDE },
	{ "Air force",  "airplane",                             KIND_ACTION,  ACT_AIR,        PLACE_SIDE },
	{ "Same type",  "square.on.square",                     KIND_KEY,     SDL_SCANCODE_E, PLACE_SIDE },
	{ "Base",       "house.fill",                           KIND_KEY,     SDL_SCANCODE_H, PLACE_SIDE },
	{ "Alert",      "exclamationmark.triangle.fill",        KIND_KEY,     SDL_SCANCODE_SPACE, PLACE_SIDE },
	{ "Stop",       "stop.fill",                            KIND_KEY,     SDL_SCANCODE_S, PLACE_SIDE },
	{ "Scatter",    "arrow.up.left.and.arrow.down.right",   KIND_KEY,     SDL_SCANCODE_X, PLACE_SIDE },
	{ "Attack move","scope",                                KIND_KEY,     SDL_SCANCODE_A, PLACE_SIDE },
	{ "Add",        "plus.circle.fill",                     KIND_ONESHOT, SDL_SCANCODE_LSHIFT, PLACE_SIDE },
	{ "Force fire", "flame.fill",                           KIND_ONESHOT, SDL_SCANCODE_LCTRL,  PLACE_SIDE },
	{ "Waypoint",   "flag.fill",                            KIND_TOGGLE,  SDL_SCANCODE_LALT,   PLACE_SIDE },
	{ "Chat",       "bubble.left.fill",                     KIND_KEY,     SDL_SCANCODE_RETURN, PLACE_SIDE },
	{ "Team chat",  "bubble.left.and.bubble.right.fill",    KIND_KEY,     SDL_SCANCODE_BACKSPACE, PLACE_SIDE },
};
const int kKeyCount = (int)(sizeof(kKeys) / sizeof(kKeys[0]));

UIColor *cyan() { return [UIColor colorWithRed:0.55 green:0.92 blue:1.0 alpha:1.0]; }
UIColor *panel() { return [UIColor colorWithRed:0.03 green:0.07 blue:0.13 alpha:0.84]; }

} // namespace

// ---------------------------------------------------------------------------

@interface GXKeyButton : UIControl
@property (nonatomic) int defIndex;
@property (nonatomic) BOOL latched;
- (instancetype)initWithFrame:(CGRect)frame def:(const KeyDef *)def index:(int)index;
@end

@implementation GXKeyButton {
	UIView *_glow;
	UIImageView *_icon;
	UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame def:(const KeyDef *)def index:(int)index
{
	self = [super initWithFrame:frame];
	if (!self) return nil;
	_defIndex = index;

	NSString *framePath = [[NSBundle mainBundle] pathForResource:@"frame" ofType:@"png" inDirectory:@"HotkeyUI"];
	UIImage *frameImage = framePath ? [UIImage imageWithContentsOfFile:framePath] : nil;
	if (frameImage) {
		UIImageView *bg = [[UIImageView alloc] initWithFrame:self.bounds];
		bg.image = frameImage;
		bg.contentMode = UIViewContentModeScaleToFill;
		bg.userInteractionEnabled = NO;
		bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:bg];
	} else {
		self.backgroundColor = [UIColor colorWithRed:0.07 green:0.12 blue:0.2 alpha:0.92];
		self.layer.cornerRadius = 9.0;
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = cyan().CGColor;
	}

	_glow = [[UIView alloc] initWithFrame:CGRectInset(self.bounds, 4, 4)];
	_glow.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.35];
	_glow.layer.cornerRadius = 7.0;
	_glow.userInteractionEnabled = NO;
	_glow.hidden = YES;
	_glow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self addSubview:_glow];

	const CGFloat w = frame.size.width, h = frame.size.height;
	const BOOL numberOnly = (def->kind == KIND_NUMBER);
	UIImage *symbol = nil;
	if (def->symbol[0] != 0) {
		UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:h * 0.36 weight:UIImageSymbolWeightSemibold];
		symbol = [UIImage systemImageNamed:[NSString stringWithUTF8String:def->symbol] withConfiguration:cfg];
	}
	if (!numberOnly) {
		_icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, h * 0.14, w, h * 0.46)];
		_icon.contentMode = UIViewContentModeScaleAspectFit;
		_icon.tintColor = cyan();
		_icon.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		_icon.userInteractionEnabled = NO;
		[self addSubview:_icon];
	}

	// Number buttons show only a big number; the others a small name under the icon.
	_label = [[UILabel alloc] initWithFrame:numberOnly ? CGRectInset(self.bounds, 2, 2) : CGRectMake(2, h * 0.62, w - 4, h * 0.26)];
	_label.text = [NSString stringWithUTF8String:def->label];
	_label.textAlignment = NSTextAlignmentCenter;
	_label.textColor = numberOnly ? cyan() : [UIColor colorWithWhite:0.96 alpha:1.0];
	_label.font = [UIFont systemFontOfSize:(numberOnly ? h * 0.5 : h * 0.19) weight:UIFontWeightBold];
	_label.adjustsFontSizeToFitWidth = YES;
	_label.minimumScaleFactor = 0.6;
	_label.userInteractionEnabled = NO;
	[self addSubview:_label];
	return self;
}

- (void)setLatched:(BOOL)on
{
	_latched = on;
	_glow.hidden = !on;
}

- (void)setHighlighted:(BOOL)highlighted
{
	[super setHighlighted:highlighted];
	self.alpha = highlighted ? 0.7 : 1.0;
}

@end

// ---------------------------------------------------------------------------

@interface GXPassThroughView : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end

@implementation GXPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	UIView *hit = [super hitTest:point withEvent:event];
	return (hit == self) ? nil : hit;
}
- (void)layoutSubviews
{
	[super layoutSubviews];
	if (self.onLayout) self.onLayout();
}
@end

// ---------------------------------------------------------------------------

@interface GXHotkeyController : NSObject
+ (instancetype)shared;
- (void)installInWindow:(UIWindow *)window;
- (void)setVisible:(BOOL)visible;
- (void)setQuickAnchorLeft:(CGFloat)left top:(CGFloat)top;
- (void)tapDone;
@end

@implementation GXHotkeyController {
	GXPassThroughView *_root;
	UIView *_bar;          // side bar
	UIScrollView *_scroll;
	UIButton *_tab;        // side bar arrow
	UIView *_quick;        // quick strip above the money / power bars
	UIView *_groups;       // control group strip at the top
	UIButton *_groupTab;   // arrow that folds the group strip
	NSMutableArray<GXKeyButton *> *_buttons;
	BOOL _open;
	BOOL _groupsOpen;
	BOOL _setGroupNext;
	BOOL _installed;
	CGFloat _anchorLeft, _anchorTop;
}

+ (instancetype)shared
{
	static GXHotkeyController *c = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ c = [[GXHotkeyController alloc] init]; });
	return c;
}

- (BOOL)isPad { return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad; }

- (UIView *)containerForPlace:(int)place
{
	switch (place) {
		case PLACE_QUICK: return _quick;
		case PLACE_GROUPS: return _groups;
		default: return _scroll;
	}
}

- (UIButton *)makeArrowTab
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.backgroundColor = panel();
	b.layer.cornerRadius = 10.0;
	b.layer.borderWidth = 0.5;
	b.layer.borderColor = cyan().CGColor;
	b.tintColor = cyan();
	return b;
}

- (UIView *)makePanel
{
	UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
	v.backgroundColor = panel();
	v.layer.cornerRadius = 12.0;
	v.layer.borderWidth = 0.5;
	v.layer.borderColor = cyan().CGColor;
	return v;
}

- (void)installInWindow:(UIWindow *)window
{
	if (_installed || !window) return;
	_installed = YES;
	_buttons = [NSMutableArray array];
	_anchorLeft = -1;
	_anchorTop = -1;

	_root = [[GXPassThroughView alloc] initWithFrame:window.bounds];
	_root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_root.backgroundColor = [UIColor clearColor];
	_root.hidden = YES;
	[window addSubview:_root];

	_bar = [self makePanel];
	_bar.hidden = YES;
	[_root addSubview:_bar];

	_scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	_scroll.showsVerticalScrollIndicator = NO;
	_scroll.alwaysBounceVertical = NO;
	[_bar addSubview:_scroll];

	_quick = [self makePanel];
	[_root addSubview:_quick];

	_groups = [self makePanel];
	[_root addSubview:_groups];
	_groupsOpen = YES;

	for (int i = 0; i < kKeyCount; ++i) {
		GXKeyButton *b = [[GXKeyButton alloc] initWithFrame:CGRectMake(0, 0, 50, 50) def:&kKeys[i] index:i];
		[b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
		[b addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
		[[self containerForPlace:kKeys[i].place] addSubview:b];
		[_buttons addObject:b];
	}

	_tab = [self makeArrowTab];
	[_tab addTarget:self action:@selector(toggleBar) forControlEvents:UIControlEventTouchUpInside];
	[_root addSubview:_tab];

	_groupTab = [self makeArrowTab];
	[_groupTab addTarget:self action:@selector(toggleGroups) forControlEvents:UIControlEventTouchUpInside];
	[_root addSubview:_groupTab];

	__weak GXHotkeyController *weakSelf = self;
	_root.onLayout = ^{ [weakSelf layoutAll]; };
	_open = NO;
	[self layoutAll];
}

- (void)layoutAll
{
	if (!_root) return;
	const BOOL pad = [self isPad];
	UIEdgeInsets safe = _root.safeAreaInsets;
	const CGFloat W = _root.bounds.size.width, H = _root.bounds.size.height;
	const CGFloat gap = 6.0, inset = 8.0;

	// ---- side bar (right edge) ----
	const CGFloat size = pad ? 64.0 : 52.0;
	const int cols = 3;
	int sideCount = 0;
	for (int i = 0; i < kKeyCount; ++i) if (kKeys[i].place == PLACE_SIDE) ++sideCount;
	const int rows = (sideCount + cols - 1) / cols;
	const CGFloat contentW = cols * size + (cols - 1) * gap;
	const CGFloat contentH = rows * size + (rows - 1) * gap;
	const CGFloat barW = contentW + 2 * inset;
	CGFloat barH = contentH + 2 * inset;
	const CGFloat maxH = H - safe.top - safe.bottom - 16.0;
	if (barH > maxH) barH = maxH;
	const CGFloat barX = W - safe.right - barW;
	const CGFloat barY = safe.top + (H - safe.top - safe.bottom - barH) * 0.5;
	_bar.frame = CGRectMake(barX, barY, barW, barH);
	_scroll.frame = CGRectMake(0, inset, barW, barH - 2 * inset);
	_scroll.contentSize = CGSizeMake(barW, contentH);

	// ---- quick strip (above the money / power bars) ----
	const CGFloat qs = pad ? 58.0 : 48.0;
	int quickCount = 0;
	for (int i = 0; i < kKeyCount; ++i) if (kKeys[i].place == PLACE_QUICK) ++quickCount;
	const CGFloat quickW = quickCount * qs + (quickCount - 1) * gap + 2 * 6.0;
	const CGFloat quickH = qs + 2 * 6.0;
	CGFloat quickX = (_anchorLeft >= 0) ? _anchorLeft : (safe.left + 12.0);
	CGFloat quickY = (_anchorTop >= 0) ? (_anchorTop - quickH - 6.0) : (H - safe.bottom - 170.0);
	if (quickX + quickW > W - safe.right) quickX = W - safe.right - quickW;
	if (quickX < safe.left) quickX = safe.left;
	if (quickY < safe.top + 4.0) quickY = safe.top + 4.0;
	_quick.frame = CGRectMake(quickX, quickY, quickW, quickH);

	// ---- control groups (top, centred) ----
	const CGFloat gs = pad ? 52.0 : 42.0;
	int groupCount = 0;
	for (int i = 0; i < kKeyCount; ++i) if (kKeys[i].place == PLACE_GROUPS) ++groupCount;
	const CGFloat groupsW = groupCount * gs + (groupCount - 1) * 4.0 + 2 * 6.0;
	const CGFloat groupsH = gs + 2 * 5.0;
	const CGFloat groupsX = (W - groupsW) * 0.5;
	const CGFloat groupsY = safe.top + 2.0;
	_groups.frame = CGRectMake(groupsX, groupsY, groupsW, groupsH);
	_groups.hidden = !_groupsOpen;

	int sideIdx = 0, quickIdx = 0, groupIdx = 0;
	for (int i = 0; i < kKeyCount; ++i) {
		GXKeyButton *b = _buttons[i];
		switch (kKeys[i].place) {
			case PLACE_SIDE: {
				const int r = sideIdx / cols, c = sideIdx % cols;
				b.frame = CGRectMake(inset + c * (size + gap), r * (size + gap), size, size);
				++sideIdx;
				break;
			}
			case PLACE_QUICK:
				b.frame = CGRectMake(6.0 + quickIdx * (qs + gap), 6.0, qs, qs);
				++quickIdx;
				break;
			case PLACE_GROUPS:
				b.frame = CGRectMake(6.0 + groupIdx * (gs + 4.0), 5.0, gs, gs);
				++groupIdx;
				break;
		}
	}

	// ---- arrow tabs ----
	UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
	const CGFloat tabW = 26.0, tabH = 72.0;
	const CGFloat tabX = _open ? (barX - tabW + 1.0) : (W - safe.right - tabW);
	_tab.frame = CGRectMake(tabX, safe.top + (H - safe.top - safe.bottom - tabH) * 0.5, tabW, tabH);
	[_tab setImage:[UIImage systemImageNamed:(_open ? @"chevron.right" : @"chevron.left") withConfiguration:cfg] forState:UIControlStateNormal];

	const CGFloat gtW = 64.0, gtH = 22.0;
	const CGFloat gtY = _groupsOpen ? (groupsY + groupsH - 1.0) : (safe.top + 2.0);
	_groupTab.frame = CGRectMake((W - gtW) * 0.5, gtY, gtW, gtH);
	[_groupTab setImage:[UIImage systemImageNamed:(_groupsOpen ? @"chevron.up" : @"chevron.down") withConfiguration:cfg] forState:UIControlStateNormal];
}

- (void)setQuickAnchorLeft:(CGFloat)left top:(CGFloat)top
{
	if (fabs(left - _anchorLeft) < 0.5 && fabs(top - _anchorTop) < 0.5) return;
	_anchorLeft = left;
	_anchorTop = top;
	[self layoutAll];
}

- (void)toggleBar
{
	_open = !_open;
	_bar.hidden = !_open;
	[self layoutAll];
}

- (void)toggleGroups
{
	_groupsOpen = !_groupsOpen;
	[self layoutAll];
}

- (void)setVisible:(BOOL)visible
{
	if (!_root) return;
	_root.hidden = !visible;
	if (!visible) {
		// leaving the match: drop anything held down
		[self releaseAllLatches];
		_open = NO;
		_bar.hidden = YES;
		_groupsOpen = YES;
		[self layoutAll];
	}
}

- (void)releaseAllLatches
{
	for (GXKeyButton *b in _buttons) {
		if (!b.latched) continue;
		const KeyDef &d = kKeys[b.defIndex];
		if (d.kind == KIND_ONESHOT || d.kind == KIND_TOGGLE) gxHotkeySendKey(d.code, false);
		b.latched = NO;
	}
	_setGroupNext = NO;
}

- (void)runAction:(int)action
{
	switch (action) {
		case ACT_ARMY: gxHotkeySelectArmy(); break;
		case ACT_AIR: gxHotkeySelectAir(); break;
		case ACT_RESET_VIEW: gxHotkeyResetView(); break;
		case ACT_CANCEL: gxHotkeyCancel(); break;
	}
}

- (void)keyDown:(GXKeyButton *)b
{
	const KeyDef &d = kKeys[b.defIndex];
	switch (d.kind) {
		case KIND_KEY:
			gxHotkeySendKey(d.code, true);
			break;
		case KIND_NUMBER:
			if (_setGroupNext) {
				gxHotkeySendKey(SDL_SCANCODE_LCTRL, true);
			}
			gxHotkeySendKey(d.code, true);
			break;
		case KIND_ONESHOT:
		case KIND_TOGGLE: {
			const BOOL on = !b.latched;
			b.latched = on;
			gxHotkeySendKey(d.code, on ? true : false);
			break;
		}
		case KIND_SETGROUP:
			_setGroupNext = !_setGroupNext;
			b.latched = _setGroupNext;
			break;
		case KIND_ACTION:
			[self runAction:d.code];
			break;
	}
}

- (void)keyUp:(GXKeyButton *)b
{
	const KeyDef &d = kKeys[b.defIndex];
	if (d.kind == KIND_KEY) {
		gxHotkeySendKey(d.code, false);
	}
	else if (d.kind == KIND_NUMBER) {
		gxHotkeySendKey(d.code, false);
		if (_setGroupNext) {
			gxHotkeySendKey(SDL_SCANCODE_LCTRL, false);
			_setGroupNext = NO;
			for (GXKeyButton *other in _buttons) {
				if (kKeys[other.defIndex].kind == KIND_SETGROUP) other.latched = NO;
			}
		}
	}
}

// A tap on the map finished: release the one-shot modifiers (Add, Force fire) a moment later, so the
// click has been read by the game with the modifier still held.
- (void)tapDone
{
	BOOL any = NO;
	for (GXKeyButton *b in _buttons) {
		if (b.latched && kKeys[b.defIndex].kind == KIND_ONESHOT) { any = YES; break; }
	}
	if (!any) return;
	__weak GXHotkeyController *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		GXHotkeyController *s = weakSelf;
		if (!s) return;
		for (GXKeyButton *b in s->_buttons) {
			if (b.latched && kKeys[b.defIndex].kind == KIND_ONESHOT) {
				gxHotkeySendKey(kKeys[b.defIndex].code, false);
				b.latched = NO;
			}
		}
	});
}

@end

// ---------------------------------------------------------------------------

void gxHotkeyOverlayInit(SDL_Window *window)
{
	if (!window) return;
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	UIWindow *uiWindow = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	if (!uiWindow) {
		fprintf(stderr, "WARNING: hotkey overlay: no UIWindow for the SDL window\n");
		return;
	}
	[[GXHotkeyController shared] installInWindow:uiWindow];
	fprintf(stderr, "INFO: hotkey overlay installed\n");
}

void gxHotkeyOverlaySetVisible(bool visible)
{
	[[GXHotkeyController shared] setVisible:visible ? YES : NO];
}

void gxHotkeyOverlaySetQuickAnchor(float left, float top)
{
	[[GXHotkeyController shared] setQuickAnchorLeft:left top:top];
}

void gxHotkeyNotifyTapDone()
{
	[[GXHotkeyController shared] tapDone];
}

#endif // TARGET_OS_IPHONE
