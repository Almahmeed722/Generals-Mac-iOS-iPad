// On-screen hotkey bar for the iOS build.
//
// A transparent UIKit layer sits above the SDL game view. Touches that miss every button fall
// straight through to the game; the buttons send the same key presses a keyboard would (the engine
// already reads SDL keyboard events), so no game logic is touched.
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
	KIND_ONESHOT,   // latch: key held until the next map tap finishes (Shift, Ctrl)
	KIND_TOGGLE,    // latch: key held until tapped again (Alt waypoint)
	KIND_MOVEMAP,   // toggles "one finger drags the map"
	KIND_SETGROUP,  // next number button creates a control group instead of selecting it
	KIND_NUMBER,    // group number 1-9
	KIND_CANCEL     // right click: cancels a pending target / placement
};

struct KeyDef {
	const char *label;
	const char *symbol; // SF Symbol name
	KeyKind kind;
	int scancode;
};

const KeyDef kKeys[] = {
	{ "Army",       "shield.fill",                          KIND_KEY,     SDL_SCANCODE_Q },
	{ "Air force",  "airplane",                             KIND_KEY,     SDL_SCANCODE_W },
	{ "Same type",  "square.on.square",                     KIND_KEY,     SDL_SCANCODE_E },
	{ "Base",       "house.fill",                           KIND_KEY,     SDL_SCANCODE_H },
	{ "Alert",      "exclamationmark.triangle.fill",        KIND_KEY,     SDL_SCANCODE_SPACE },

	{ "Stop",       "stop.fill",                            KIND_KEY,     SDL_SCANCODE_S },
	{ "Scatter",    "arrow.up.left.and.arrow.down.right",   KIND_KEY,     SDL_SCANCODE_X },
	{ "Guard",      "hand.raised.fill",                     KIND_KEY,     SDL_SCANCODE_G },
	{ "Attack move","scope",                                KIND_KEY,     SDL_SCANCODE_A },
	{ "Cancel",     "xmark.circle.fill",                    KIND_CANCEL,  0 },
	{ "Move map",   "arrow.up.and.down.and.arrow.left.and.right", KIND_MOVEMAP, 0 },

	{ "Add",        "plus.circle.fill",                     KIND_ONESHOT, SDL_SCANCODE_LSHIFT },
	{ "Force fire", "flame.fill",                           KIND_ONESHOT, SDL_SCANCODE_LCTRL },
	{ "Waypoint",   "flag.fill",                            KIND_TOGGLE,  SDL_SCANCODE_LALT },
	{ "Save group", "square.and.arrow.down.fill",           KIND_SETGROUP,0 },

	{ "1", "1.circle.fill", KIND_NUMBER, SDL_SCANCODE_1 },
	{ "2", "2.circle.fill", KIND_NUMBER, SDL_SCANCODE_2 },
	{ "3", "3.circle.fill", KIND_NUMBER, SDL_SCANCODE_3 },
	{ "4", "4.circle.fill", KIND_NUMBER, SDL_SCANCODE_4 },
	{ "5", "5.circle.fill", KIND_NUMBER, SDL_SCANCODE_5 },
	{ "6", "6.circle.fill", KIND_NUMBER, SDL_SCANCODE_6 },
	{ "7", "7.circle.fill", KIND_NUMBER, SDL_SCANCODE_7 },
	{ "8", "8.circle.fill", KIND_NUMBER, SDL_SCANCODE_8 },
	{ "9", "9.circle.fill", KIND_NUMBER, SDL_SCANCODE_9 },

	{ "Chat",       "bubble.left.fill",                     KIND_KEY,     SDL_SCANCODE_RETURN },
	{ "Team chat",  "bubble.left.and.bubble.right.fill",    KIND_KEY,     SDL_SCANCODE_BACKSPACE },
};
const int kKeyCount = (int)(sizeof(kKeys) / sizeof(kKeys[0]));

UIColor *cyan() { return [UIColor colorWithRed:0.55 green:0.92 blue:1.0 alpha:1.0]; }

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
	[self addSubview:_glow];

	const CGFloat w = frame.size.width, h = frame.size.height;
	UIImage *symbol = nil;
	if (def->symbol[0] != 0) {
		UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:h * 0.36 weight:UIImageSymbolWeightSemibold];
		symbol = [UIImage systemImageNamed:[NSString stringWithUTF8String:def->symbol] withConfiguration:cfg];
	}
	_icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, h * 0.14, w, h * 0.46)];
	_icon.contentMode = UIViewContentModeScaleAspectFit;
	_icon.tintColor = cyan();
	_icon.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	_icon.userInteractionEnabled = NO;
	[self addSubview:_icon];

	_label = [[UILabel alloc] initWithFrame:CGRectMake(2, h * 0.62, w - 4, h * 0.26)];
	_label.text = [NSString stringWithUTF8String:def->label];
	_label.textAlignment = NSTextAlignmentCenter;
	_label.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
	_label.font = [UIFont systemFontOfSize:h * 0.19 weight:UIFontWeightBold];
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
- (void)tapDone;
@end

@implementation GXHotkeyController {
	GXPassThroughView *_root;
	UIView *_bar;
	UIScrollView *_scroll;
	UIButton *_tab;
	NSMutableArray<GXKeyButton *> *_buttons;
	BOOL _open;
	BOOL _setGroupNext;
	BOOL _moveMap;
	BOOL _installed;
}

+ (instancetype)shared
{
	static GXHotkeyController *c = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ c = [[GXHotkeyController alloc] init]; });
	return c;
}

- (CGFloat)buttonSize
{
	return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 64.0 : 52.0;
}

- (void)installInWindow:(UIWindow *)window
{
	if (_installed || !window) return;
	_installed = YES;
	_buttons = [NSMutableArray array];

	_root = [[GXPassThroughView alloc] initWithFrame:window.bounds];
	_root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_root.backgroundColor = [UIColor clearColor];
	_root.hidden = YES;
	[window addSubview:_root];

	_bar = [[UIView alloc] initWithFrame:CGRectZero];
	_bar.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.13 alpha:0.84];
	_bar.layer.cornerRadius = 12.0;
	_bar.layer.borderWidth = 0.5;
	_bar.layer.borderColor = cyan().CGColor;
	_bar.hidden = YES;
	[_root addSubview:_bar];

	_scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	_scroll.showsVerticalScrollIndicator = NO;
	_scroll.alwaysBounceVertical = NO;
	[_bar addSubview:_scroll];

	const CGFloat size = [self buttonSize];
	for (int i = 0; i < kKeyCount; ++i) {
		GXKeyButton *b = [[GXKeyButton alloc] initWithFrame:CGRectMake(0, 0, size, size) def:&kKeys[i] index:i];
		[b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
		[b addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
		[_scroll addSubview:b];
		[_buttons addObject:b];
	}

	_tab = [UIButton buttonWithType:UIButtonTypeCustom];
	_tab.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.13 alpha:0.84];
	_tab.layer.cornerRadius = 10.0;
	_tab.layer.borderWidth = 0.5;
	_tab.layer.borderColor = cyan().CGColor;
	_tab.tintColor = cyan();
	[_tab addTarget:self action:@selector(toggleBar) forControlEvents:UIControlEventTouchUpInside];
	[_root addSubview:_tab];

	__weak GXHotkeyController *weakSelf = self;
	_root.onLayout = ^{ [weakSelf layoutAll]; };
	_open = NO;
	[self layoutAll];
}

- (void)layoutAll
{
	if (!_root) return;
	const CGFloat size = [self buttonSize];
	const CGFloat gap = 6.0, pad = 8.0;
	const int cols = 3;
	UIEdgeInsets safe = _root.safeAreaInsets;
	const CGFloat W = _root.bounds.size.width, H = _root.bounds.size.height;

	const int rows = (kKeyCount + cols - 1) / cols;
	const CGFloat contentW = cols * size + (cols - 1) * gap;
	const CGFloat contentH = rows * size + (rows - 1) * gap;
	const CGFloat barW = contentW + 2 * pad;
	CGFloat barH = contentH + 2 * pad;
	const CGFloat maxH = H - safe.top - safe.bottom - 16.0;
	if (barH > maxH) barH = maxH;

	const CGFloat barX = W - safe.right - barW;
	const CGFloat barY = safe.top + (H - safe.top - safe.bottom - barH) * 0.5;
	_bar.frame = CGRectMake(barX, barY, barW, barH);
	_scroll.frame = CGRectMake(0, pad, barW, barH - 2 * pad);
	_scroll.contentSize = CGSizeMake(barW, contentH);
	for (int i = 0; i < kKeyCount; ++i) {
		const int r = i / cols, c = i % cols;
		_buttons[i].frame = CGRectMake(pad + c * (size + gap), r * (size + gap), size, size);
	}

	const CGFloat tabW = 26.0, tabH = 72.0;
	const CGFloat tabX = _open ? (barX - tabW + 1.0) : (W - safe.right - tabW);
	_tab.frame = CGRectMake(tabX, safe.top + (H - safe.top - safe.bottom - tabH) * 0.5, tabW, tabH);
	UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
	UIImage *chev = [UIImage systemImageNamed:(_open ? @"chevron.right" : @"chevron.left") withConfiguration:cfg];
	[_tab setImage:chev forState:UIControlStateNormal];
}

- (void)toggleBar
{
	_open = !_open;
	_bar.hidden = !_open;
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
		[self layoutAll];
	}
}

- (void)releaseAllLatches
{
	for (GXKeyButton *b in _buttons) {
		if (!b.latched) continue;
		const KeyDef &d = kKeys[b.defIndex];
		if (d.kind == KIND_ONESHOT || d.kind == KIND_TOGGLE) gxHotkeySendKey(d.scancode, false);
		b.latched = NO;
	}
	_setGroupNext = NO;
	if (_moveMap) { _moveMap = NO; gxHotkeySetMoveMode(false); }
}

- (void)keyDown:(GXKeyButton *)b
{
	const KeyDef &d = kKeys[b.defIndex];
	switch (d.kind) {
		case KIND_KEY:
			gxHotkeySendKey(d.scancode, true);
			break;
		case KIND_NUMBER:
			if (_setGroupNext) {
				gxHotkeySendKey(SDL_SCANCODE_LCTRL, true);
			}
			gxHotkeySendKey(d.scancode, true);
			break;
		case KIND_ONESHOT:
		case KIND_TOGGLE: {
			const BOOL on = !b.latched;
			b.latched = on;
			gxHotkeySendKey(d.scancode, on ? true : false);
			break;
		}
		case KIND_MOVEMAP:
			_moveMap = !_moveMap;
			b.latched = _moveMap;
			gxHotkeySetMoveMode(_moveMap ? true : false);
			break;
		case KIND_SETGROUP:
			_setGroupNext = !_setGroupNext;
			b.latched = _setGroupNext;
			break;
		case KIND_CANCEL:
			gxHotkeyRightClick();
			break;
	}
}

- (void)keyUp:(GXKeyButton *)b
{
	const KeyDef &d = kKeys[b.defIndex];
	if (d.kind == KIND_KEY) {
		gxHotkeySendKey(d.scancode, false);
	}
	else if (d.kind == KIND_NUMBER) {
		gxHotkeySendKey(d.scancode, false);
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
				gxHotkeySendKey(kKeys[b.defIndex].scancode, false);
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

void gxHotkeyNotifyTapDone()
{
	[[GXHotkeyController shared] tapDone];
}

#endif // TARGET_OS_IPHONE
