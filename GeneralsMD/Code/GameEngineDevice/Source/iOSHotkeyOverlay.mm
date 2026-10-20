// On-screen hotkey buttons for the iOS build.
//
// A transparent UIKit layer sits above the SDL game view. Touches that miss every button fall
// straight through to the game. Three groups of buttons:
//   - a quick strip just above the minimap (Cancel, Stop, Guard, Reset view),
//   - a small strip along the top for control groups (Ctrl + 1..9) that can be folded away,
//   - a side bar (open it with the arrow on the right edge) with the other orders; its "More" button
//     adds the less used ones (Scatter, Add, Force fire, Queue path, Chat, Team chat).
// Most buttons send the same key presses a keyboard would (the engine already reads SDL keyboard
// events); a few call small helpers in the engine (select army, select air force, cancel, reset view).
//
// Edit mode (the gear button under the fps text, or press and hold on one of the arrows): drag a group
// to move it, use - / + to change its size, Done to finish, Reset to go back to the default layout.
// Positions (as a fraction of the screen) and sizes are saved separately for iPhone and iPad.
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
	KIND_TOGGLE,    // latch: key held until tapped again (Queue path = Alt)
	KIND_SETGROUP,  // next number button creates a control group instead of selecting it
	KIND_POINT,     // toggle: the next tap on empty ground sets the selected building's gathering point
	KIND_NUMBER,    // group number 1-9
	KIND_ACTION,    // calls an engine helper
	KIND_REPLAY     // replay playback speed (1x 2x 4x 8x), one lit at a time
};

enum Action { ACT_ARMY = 1, ACT_AIR = 2, ACT_RESET_VIEW = 3, ACT_CANCEL = 4, ACT_MORE = 5 };
enum Place { PLACE_SIDE = 0, PLACE_QUICK = 1, PLACE_GROUPS = 2, PLACE_MORE = 3, PLACE_REPLAY = 4 };
// Movable / resizable groups
enum Group { GROUP_SIDE = 0, GROUP_QUICK = 1, GROUP_NUMBERS = 2, GROUP_COUNT = 3 };

struct KeyDef {
	const char *label;
	const char *symbol; // SF Symbol name
	KeyKind kind;
	int code;           // SDL scancode, or an Action
	Place place;
};

const KeyDef kKeys[] = {
	// quick strip (above the minimap)
	{ "Cancel",     "xmark.circle.fill",                    KIND_ACTION,  ACT_CANCEL,     PLACE_QUICK },
	{ "Stop",       "stop.fill",                            KIND_KEY,     SDL_SCANCODE_S, PLACE_QUICK },
	{ "Guard",      "hand.raised.fill",                     KIND_KEY,     SDL_SCANCODE_G, PLACE_QUICK },
	{ "Reset view", "arrow.triangle.2.circlepath",          KIND_ACTION,  ACT_RESET_VIEW, PLACE_QUICK },

	// control groups (top strip)
	{ "Ctrl",       "",                                     KIND_SETGROUP,0,              PLACE_GROUPS },
	{ "1", "", KIND_NUMBER, SDL_SCANCODE_1, PLACE_GROUPS },
	{ "2", "", KIND_NUMBER, SDL_SCANCODE_2, PLACE_GROUPS },
	{ "3", "", KIND_NUMBER, SDL_SCANCODE_3, PLACE_GROUPS },
	{ "4", "", KIND_NUMBER, SDL_SCANCODE_4, PLACE_GROUPS },
	{ "5", "", KIND_NUMBER, SDL_SCANCODE_5, PLACE_GROUPS },
	{ "6", "", KIND_NUMBER, SDL_SCANCODE_6, PLACE_GROUPS },
	{ "7", "", KIND_NUMBER, SDL_SCANCODE_7, PLACE_GROUPS },
	{ "8", "", KIND_NUMBER, SDL_SCANCODE_8, PLACE_GROUPS },
	{ "9", "", KIND_NUMBER, SDL_SCANCODE_9, PLACE_GROUPS },

	// side bar: main buttons
	{ "Army",       "shield.fill",                          KIND_ACTION,  ACT_ARMY,       PLACE_SIDE },
	{ "Air force",  "airplane",                             KIND_ACTION,  ACT_AIR,        PLACE_SIDE },
	{ "Same type",  "square.on.square",                     KIND_KEY,     SDL_SCANCODE_E, PLACE_SIDE },
	{ "Attack move","scope",                                KIND_KEY,     SDL_SCANCODE_A, PLACE_SIDE },
	{ "Point",      "mappin.and.ellipse",                   KIND_POINT,   0,              PLACE_SIDE },
	{ "Base",       "house.fill",                           KIND_KEY,     SDL_SCANCODE_H, PLACE_SIDE },
	{ "Alert",      "exclamationmark.triangle.fill",        KIND_KEY,     SDL_SCANCODE_SPACE, PLACE_SIDE },
	{ "More",       "ellipsis.circle.fill",                 KIND_ACTION,  ACT_MORE,       PLACE_SIDE },

	// side bar: shown after "More" is pressed
	{ "Scatter",    "arrow.up.left.and.arrow.down.right",   KIND_KEY,     SDL_SCANCODE_X, PLACE_MORE },
	{ "Add",        "plus.circle.fill",                     KIND_ONESHOT, SDL_SCANCODE_LSHIFT, PLACE_MORE },
	{ "Force fire", "flame.fill",                           KIND_ONESHOT, SDL_SCANCODE_LCTRL,  PLACE_MORE },
	{ "Queue path", "point.topleft.down.curvedto.point.bottomright.up", KIND_TOGGLE,  SDL_SCANCODE_LALT,   PLACE_MORE },
	{ "Chat",       "bubble.left.fill",                     KIND_KEY,     SDL_SCANCODE_RETURN, PLACE_MORE },
	{ "Team chat",  "bubble.left.and.bubble.right.fill",    KIND_KEY,     SDL_SCANCODE_BACKSPACE, PLACE_MORE },

	// replay speed (shown only while a replay is playing)
	{ "1x", "", KIND_REPLAY, 1, PLACE_REPLAY },
	{ "2x", "", KIND_REPLAY, 2, PLACE_REPLAY },
	{ "4x", "", KIND_REPLAY, 4, PLACE_REPLAY },
	{ "8x", "", KIND_REPLAY, 8, PLACE_REPLAY },
};
const int kKeyCount = (int)(sizeof(kKeys) / sizeof(kKeys[0]));

UIColor *cyan() { return [UIColor colorWithRed:0.55 green:0.92 blue:1.0 alpha:1.0]; }
UIColor *amber() { return [UIColor colorWithRed:1.0 green:0.78 blue:0.2 alpha:1.0]; }
UIColor *panel() { return [UIColor colorWithRed:0.03 green:0.07 blue:0.13 alpha:0.84]; }

} // namespace


// ---------------------------------------------------------------------------

@interface GXKeyButton : UIControl
@property (nonatomic) int defIndex;
@property (nonatomic) BOOL latched;
- (instancetype)initWithFrame:(CGRect)frame def:(const KeyDef *)def index:(int)index;
@end

@implementation GXKeyButton {
	const KeyDef *_def;
	UIImageView *_bg;       // button artwork
	UIImageView *_lit;      // the pressed / switched-on light (HotkeyUI/frame_lit.png), a little larger than the button
	UIView *_glow;          // plain light, only if that artwork is missing
	UIImageView *_icon;
	UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame def:(const KeyDef *)def index:(int)index
{
	self = [super initWithFrame:frame];
	if (!self) return nil;
	_defIndex = index;
	_def = def;

	NSString *framePath = [[NSBundle mainBundle] pathForResource:@"frame" ofType:@"png" inDirectory:@"HotkeyUI"];
	UIImage *frameImage = framePath ? [UIImage imageWithContentsOfFile:framePath] : nil;
	if (frameImage) {
		_bg = [[UIImageView alloc] initWithImage:frameImage];
		_bg.contentMode = UIViewContentModeScaleToFill;
		_bg.userInteractionEnabled = NO;
		[self addSubview:_bg];
	} else {
		self.backgroundColor = [UIColor colorWithRed:0.07 green:0.12 blue:0.2 alpha:0.92];
		self.layer.cornerRadius = 9.0;
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = cyan().CGColor;
	}

	NSString *litPath = [[NSBundle mainBundle] pathForResource:@"frame_lit" ofType:@"png" inDirectory:@"HotkeyUI"];
	UIImage *litImage = litPath ? [UIImage imageWithContentsOfFile:litPath] : nil;
	if (litImage) {
		_lit = [[UIImageView alloc] initWithImage:litImage];
		_lit.contentMode = UIViewContentModeScaleToFill;
		_lit.userInteractionEnabled = NO;
		_lit.alpha = 0.0;
		[self addSubview:_lit];
	} else {
		_glow = [[UIView alloc] initWithFrame:CGRectZero];
		_glow.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.45];
		_glow.layer.cornerRadius = 7.0;
		_glow.userInteractionEnabled = NO;
		_glow.hidden = YES;
		[self addSubview:_glow];
	}

	// The number and Ctrl buttons show only big text; the others an icon with a small name under it.
	const BOOL textOnly = (def->kind == KIND_NUMBER || def->kind == KIND_SETGROUP || def->kind == KIND_REPLAY);
	if (!textOnly) {
		_icon = [[UIImageView alloc] initWithFrame:CGRectZero];
		_icon.contentMode = UIViewContentModeScaleAspectFit;
		_icon.tintColor = cyan();
		_icon.userInteractionEnabled = NO;
		[self addSubview:_icon];
	}
	_label = [[UILabel alloc] initWithFrame:CGRectZero];
	_label.text = [NSString stringWithUTF8String:def->label];
	_label.textAlignment = NSTextAlignmentCenter;
	_label.adjustsFontSizeToFitWidth = YES;
	_label.minimumScaleFactor = 0.5;
	_label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
	_label.userInteractionEnabled = NO;
	[self addSubview:_label];
	[self updateLookAnimated:NO];
	return self;
}

// Everything is placed from the button's CURRENT size (the buttons are resized after they are created),
// so text and icons stay exactly in the middle.
- (void)layoutSubviews
{
	[super layoutSubviews];
	const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
	_bg.frame = self.bounds;
	if (_lit) {
		const CGFloat side = w * (171.0 / 160.0); // the light artwork has a soft rim around the button face
		_lit.frame = CGRectMake((w - side) * 0.5, (h - side) * 0.5, side, side);
	}
	_glow.frame = CGRectInset(self.bounds, 4, 4);

	const BOOL textOnly = (_def->kind == KIND_NUMBER || _def->kind == KIND_SETGROUP || _def->kind == KIND_REPLAY);
	// The lit face of the button artwork starts ~6% inside the picture: everything is centred in it, and the
	// text is kept inside it (long names like "Same type" shrink instead of running over).
	const CGFloat faceInset = w * 0.09;
	const CGRect face = CGRectInset(self.bounds, faceInset, faceInset);
	UIFont *font = [UIFont systemFontOfSize:(_def->kind == KIND_NUMBER ? h * 0.46 : (textOnly ? h * 0.30 : h * 0.17)) weight:UIFontWeightBold];
	_label.font = font;
	if (textOnly) {
		// A label centres its whole line box (ascender to descender); shift it so the glyphs themselves
		// sit exactly in the middle of the button.
		const CGFloat dy = (font.capHeight + fabs(font.descender) - font.ascender) / 2.0;
		_label.frame = CGRectOffset(face, 0, dy);
	} else {
		if (_def->symbol[0] != 0) {
			UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:h * 0.30 weight:UIImageSymbolWeightSemibold];
			UIImage *symbol = [UIImage systemImageNamed:[NSString stringWithUTF8String:_def->symbol] withConfiguration:cfg];
			_icon.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		}
		// icon + name are centred together, as one block, in the face
		const CGFloat iconH = h * 0.34, labelH = h * 0.18, gap = h * 0.03;
		const CGFloat top = (h - (iconH + gap + labelH)) * 0.5;
		_icon.frame = CGRectMake(face.origin.x, top, face.size.width, iconH);
		_label.frame = CGRectMake(face.origin.x, top + iconH + gap, face.size.width, labelH);
	}
}

// The light: on at once when you press (or when a latched button is switched on), and a quick fade out
// when you let go. Text and icon turn dark while the button is lit so they stay readable on the light.
- (void)updateLookAnimated:(BOOL)animated
{
	const BOOL on = self.highlighted || _latched;
	UIColor *ink = on ? [UIColor colorWithRed:0.01 green:0.09 blue:0.16 alpha:1.0] : nil;
	_icon.tintColor = ink ? ink : cyan();
	const BOOL textOnly = (_def->kind == KIND_NUMBER || _def->kind == KIND_SETGROUP || _def->kind == KIND_REPLAY);
	_label.textColor = ink ? ink : (textOnly ? cyan() : [UIColor colorWithWhite:0.96 alpha:1.0]);
	void (^apply)(void) = ^{
		self->_lit.alpha = on ? 1.0 : 0.0;
	};
	if (animated && !on) {
		[UIView animateWithDuration:0.28 animations:apply];
	} else {
		apply();
	}
	_glow.hidden = !on;
}

- (void)setLatched:(BOOL)on
{
	_latched = on;
	[self updateLookAnimated:YES];
}

- (void)setHighlighted:(BOOL)highlighted
{
	[super setHighlighted:highlighted];
	[self updateLookAnimated:YES];
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

@interface GXHotkeyController : NSObject
+ (instancetype)shared;
- (void)installInWindow:(UIWindow *)window;
- (void)setVisible:(BOOL)visible;
- (void)setQuickAnchorLeft:(CGFloat)left top:(CGFloat)top width:(CGFloat)width;
- (void)pointModeConsumed;
- (void)tapDone;
- (void)releaseToggles;
- (void)setReplayMode:(BOOL)on;
@end

@implementation GXHotkeyController {
	GXPassThroughView *_root;
	UIView *_bar;          // side bar
	UIScrollView *_scroll;
	UIButton *_tab;        // side bar arrow
	UIView *_quick;        // quick strip above the minimap
	UIView *_groups;       // control group strip at the top
	UIView *_replay;       // replay speed buttons (only while a replay is playing)
	BOOL _replayMode;
	UIButton *_groupTab;   // arrow that folds the group strip
	NSMutableArray<GXKeyButton *> *_buttons;
	BOOL _open;
	BOOL _moreOpen;
	BOOL _groupsOpen;
	BOOL _setGroupNext;
	BOOL _installed;
	CGFloat _anchorLeft, _anchorTop, _anchorWidth;

	// edit mode
	BOOL _edit;
	UIButton *_gear;
	UIButton *_resetBtn;
	UILabel *_hint;
	UIView *_pill[GROUP_COUNT];   // "- / +" for each group, shown only while editing
	CGFloat _cx[GROUP_COUNT], _cy[GROUP_COUNT]; // saved centre as a fraction of the screen (negative = default)
	CGFloat _scale[GROUP_COUNT];
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
		case PLACE_REPLAY: return _replay;
		default: return _scroll; // side + more
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

// ---- saved layout (per device type) ----

- (NSString *)defaultsKey:(int)g name:(NSString *)name
{
	return [NSString stringWithFormat:@"gxui.%@.%d.%@", [self isPad] ? @"pad" : @"phone", g, name];
}

- (void)loadConfig
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	for (int g = 0; g < GROUP_COUNT; ++g) {
		id cx = [d objectForKey:[self defaultsKey:g name:@"cx"]];
		id cy = [d objectForKey:[self defaultsKey:g name:@"cy"]];
		id sc = [d objectForKey:[self defaultsKey:g name:@"scale"]];
		_cx[g] = (cx && cy) ? [cx doubleValue] : -1.0;
		_cy[g] = (cx && cy) ? [cy doubleValue] : -1.0;
		_scale[g] = sc ? MIN(1.6, MAX(0.6, [sc doubleValue])) : 1.0;
	}
}

- (void)saveConfig
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	for (int g = 0; g < GROUP_COUNT; ++g) {
		if (_cx[g] >= 0) {
			[d setDouble:_cx[g] forKey:[self defaultsKey:g name:@"cx"]];
			[d setDouble:_cy[g] forKey:[self defaultsKey:g name:@"cy"]];
		} else {
			[d removeObjectForKey:[self defaultsKey:g name:@"cx"]];
			[d removeObjectForKey:[self defaultsKey:g name:@"cy"]];
		}
		[d setDouble:_scale[g] forKey:[self defaultsKey:g name:@"scale"]];
	}
	[d synchronize];
}

- (UIButton *)makeTextButton:(NSString *)title
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.backgroundColor = panel();
	b.layer.cornerRadius = 10.0;
	b.layer.borderWidth = 1.0;
	b.layer.borderColor = amber().CGColor;
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:amber() forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
	return b;
}

- (void)installInWindow:(UIWindow *)window
{
	if (_installed || !window) return;
	_installed = YES;
	_buttons = [NSMutableArray array];
	_anchorLeft = -1;
	_anchorTop = -1;
	[self loadConfig];

	_root = [[GXPassThroughView alloc] initWithFrame:window.bounds];
	_root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_root.backgroundColor = [UIColor clearColor];
	_root.hidden = YES;
	[window addSubview:_root];

	_bar = [self makePanel];
	_bar.hidden = YES;
	_bar.tag = GROUP_SIDE;
	[_root addSubview:_bar];

	_scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	_scroll.showsVerticalScrollIndicator = NO;
	_scroll.alwaysBounceVertical = NO;
	[_bar addSubview:_scroll];

	_quick = [self makePanel];
	_quick.tag = GROUP_QUICK;
	[_root addSubview:_quick];

	_groups = [self makePanel];
	_groups.tag = GROUP_NUMBERS;
	[_root addSubview:_groups];
	_groupsOpen = YES;

	_replay = [self makePanel];
	_replay.hidden = YES;
	[_root addSubview:_replay];

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

	// press and hold an arrow = edit mode
	for (UIButton *t in @[ _tab, _groupTab ]) {
		UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(arrowHeld:)];
		lp.minimumPressDuration = 0.6;
		[t addGestureRecognizer:lp];
	}

	// dragging a group (only active while editing)
	for (UIView *p in @[ _bar, _quick, _groups ]) {
		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(groupPanned:)];
		pan.enabled = NO;
		[p addGestureRecognizer:pan];
	}

	// edit controls: gear, Reset, hint, and a "- / +" pill per group
	_gear = [self makeTextButton:@""];
	[_gear addTarget:self action:@selector(gearTapped) forControlEvents:UIControlEventTouchUpInside];
	_gear.tintColor = cyan();
	[_root addSubview:_gear];

	_resetBtn = [self makeTextButton:@"Reset"];
	[_resetBtn addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
	_resetBtn.hidden = YES;
	[_root addSubview:_resetBtn];

	_hint = [[UILabel alloc] initWithFrame:CGRectZero];
	_hint.text = @"Drag a group to move it.  − / +  changes its size.";
	_hint.textColor = amber();
	_hint.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	_hint.hidden = YES;
	_hint.userInteractionEnabled = NO;
	[_root addSubview:_hint];

	for (int g = 0; g < GROUP_COUNT; ++g) {
		UIView *pill = [self makePanel];
		pill.layer.borderColor = amber().CGColor;
		pill.layer.borderWidth = 1.0;
		pill.layer.cornerRadius = 12.0;
		pill.hidden = YES;
		for (int k = 0; k < 2; ++k) {
			UIButton *b = [self makeTextButton:(k == 0 ? @"−" : @"+")];
			b.tag = g * 10 + k;
			b.frame = CGRectMake(4 + k * 40, 4, 36, 30);
			[b addTarget:self action:@selector(sizeTapped:) forControlEvents:UIControlEventTouchUpInside];
			[pill addSubview:b];
		}
		_pill[g] = pill;
		[_root addSubview:pill];
	}

	__weak GXHotkeyController *weakSelf = self;
	_root.onLayout = ^{ [weakSelf layoutAll]; };
	_open = NO;
	[self layoutAll];
}

// ---- layout ----

// Frame for a group: its saved centre (or the given default centre), kept inside the safe area.
- (CGRect)frameForGroup:(int)g size:(CGSize)sz defaultCenter:(CGPoint)dc
{
	UIEdgeInsets safe = _root.safeAreaInsets;
	const CGFloat W = _root.bounds.size.width, H = _root.bounds.size.height;
	CGPoint c = (_cx[g] >= 0) ? CGPointMake(_cx[g] * W, _cy[g] * H) : dc;
	CGFloat x = c.x - sz.width * 0.5, y = c.y - sz.height * 0.5;
	const CGFloat minX = safe.left + 2.0, maxX = W - safe.right - sz.width - 2.0;
	const CGFloat minY = safe.top + 2.0, maxY = H - safe.bottom - sz.height - 2.0;
	x = MAX(minX, MIN(maxX < minX ? minX : maxX, x));
	y = MAX(minY, MIN(maxY < minY ? minY : maxY, y));
	return CGRectMake(round(x), round(y), sz.width, sz.height);
}

- (void)layoutAll
{
	if (!_root) return;
	const BOOL pad = [self isPad];
	UIEdgeInsets safe = _root.safeAreaInsets;
	const CGFloat W = _root.bounds.size.width, H = _root.bounds.size.height;
	const CGFloat gap = 6.0, inset = 8.0;
	const BOOL barOpen = _open || _edit;
	const BOOL groupsOpen = (_groupsOpen || _edit) && !_replayMode;

	// ---- side bar ----
	const CGFloat size = round((pad ? 64.0 : 46.0) * _scale[GROUP_SIDE]);
	const int cols = pad ? 3 : 2;
	int sideCount = 0;
	for (int i = 0; i < kKeyCount; ++i) {
		if (kKeys[i].place == PLACE_SIDE || (kKeys[i].place == PLACE_MORE && _moreOpen)) ++sideCount;
	}
	const int rows = (sideCount + cols - 1) / cols;
	const CGFloat contentW = cols * size + (cols - 1) * gap;
	const CGFloat contentH = rows * size + (rows - 1) * gap;
	const CGFloat barW = contentW + 2 * inset;
	CGFloat barH = contentH + 2 * inset;
	const CGFloat maxH = H - safe.top - safe.bottom - 16.0;
	if (barH > maxH) barH = maxH;
	CGRect barF = [self frameForGroup:GROUP_SIDE size:CGSizeMake(barW, barH)
		defaultCenter:CGPointMake(W - safe.right - barW * 0.5, safe.top + (H - safe.top - safe.bottom) * 0.5)];
	_bar.frame = barF;
	_bar.hidden = !barOpen;
	_scroll.frame = CGRectMake(0, inset, barW, barH - 2 * inset);
	_scroll.contentSize = CGSizeMake(barW, contentH);
	_scroll.userInteractionEnabled = !_edit;

	// ---- quick strip (above the minimap) ----
	const CGFloat qs = round((pad ? 58.0 : 44.0) * _scale[GROUP_QUICK]);
	int quickCount = 0;
	for (int i = 0; i < kKeyCount; ++i) if (kKeys[i].place == PLACE_QUICK) ++quickCount;
	const CGFloat quickW = quickCount * qs + (quickCount - 1) * gap + 2 * 6.0;
	const CGFloat quickH = qs + 2 * 6.0;
	CGPoint quickDef;
	quickDef.x = (_anchorLeft >= 0) ? (_anchorLeft + _anchorWidth * 0.5) : (safe.left + 12.0 + quickW * 0.5);
	quickDef.y = (_anchorTop >= 0) ? (_anchorTop - quickH * 0.5 - 6.0) : (H - safe.bottom - 170.0 + quickH * 0.5);
	_quick.frame = [self frameForGroup:GROUP_QUICK size:CGSizeMake(quickW, quickH) defaultCenter:quickDef];

	// ---- control groups (top, centred) ----
	const CGFloat gs = round((pad ? 44.0 : 34.0) * _scale[GROUP_NUMBERS]);
	int groupCount = 0;
	for (int i = 0; i < kKeyCount; ++i) if (kKeys[i].place == PLACE_GROUPS) ++groupCount;
	const CGFloat groupsW = groupCount * gs + (groupCount - 1) * 4.0 + 2 * 6.0;
	const CGFloat groupsH = gs + 2 * 5.0;
	CGRect groupsF = [self frameForGroup:GROUP_NUMBERS size:CGSizeMake(groupsW, groupsH)
		defaultCenter:CGPointMake(W * 0.5, safe.top + 2.0 + groupsH * 0.5)];
	_groups.frame = groupsF;
	_groups.hidden = !groupsOpen;

	// ---- replay speed strip (top left, under the gear) ----
	const CGFloat rs = pad ? 46.0 : 38.0;
	const CGFloat replayW = 4 * rs + 3 * 4.0 + 2 * 6.0;
	const CGFloat replayH = rs + 2 * 5.0;
	_replay.frame = CGRectMake(safe.left + 8.0, safe.top + 30.0 + 44.0, replayW, replayH);
	_replay.hidden = !_replayMode || _edit;

	// ---- buttons ----
	int sideIdx = 0, quickIdx = 0, groupIdx = 0, replayIdx = 0;
	for (int i = 0; i < kKeyCount; ++i) {
		GXKeyButton *b = _buttons[i];
		b.userInteractionEnabled = !_edit;
		switch (kKeys[i].place) {
			case PLACE_SIDE:
			case PLACE_MORE: {
				const BOOL shown = (kKeys[i].place == PLACE_SIDE) || _moreOpen;
				b.hidden = !shown;
				if (!shown) break;
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
			case PLACE_REPLAY:
				b.frame = CGRectMake(6.0 + replayIdx * (rs + 4.0), 5.0, rs, rs);
				++replayIdx;
				break;
		}
	}

	// ---- arrow tabs ----
	UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
	const CGFloat tabW = 26.0, tabH = 72.0;
	const CGFloat tabX = barOpen ? (barF.origin.x - tabW + 1.0) : (W - safe.right - tabW);
	_tab.frame = CGRectMake(MAX(safe.left, tabX), CGRectGetMidY(barF) - tabH * 0.5, tabW, tabH);
	[_tab setImage:[UIImage systemImageNamed:(_open ? @"chevron.right" : @"chevron.left") withConfiguration:cfg] forState:UIControlStateNormal];
	_tab.hidden = _edit;

	const CGFloat gtW = 64.0, gtH = 22.0;
	const CGFloat gtY = _groupsOpen ? (CGRectGetMaxY(groupsF) - 1.0) : groupsF.origin.y;
	_groupTab.frame = CGRectMake(CGRectGetMidX(groupsF) - gtW * 0.5, gtY, gtW, gtH);
	[_groupTab setImage:[UIImage systemImageNamed:(_groupsOpen ? @"chevron.up" : @"chevron.down") withConfiguration:cfg] forState:UIControlStateNormal];
	_groupTab.hidden = _edit || _replayMode;

	// ---- edit mode controls ----
	UIImageSymbolConfiguration *gcfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
	const CGFloat gy = safe.top + 30.0;
	[_gear setImage:[UIImage systemImageNamed:(_edit ? @"checkmark" : @"gearshape.fill") withConfiguration:gcfg] forState:UIControlStateNormal];
	_gear.tintColor = _edit ? amber() : cyan();
	_gear.layer.borderColor = (_edit ? amber() : cyan()).CGColor;
	_gear.alpha = _edit ? 1.0 : 0.6;
	_gear.frame = CGRectMake(safe.left + 8.0, gy, 36.0, 36.0);
	_resetBtn.frame = CGRectMake(CGRectGetMaxX(_gear.frame) + 8.0, gy, 64.0, 36.0);
	_resetBtn.hidden = !_edit;
	_hint.frame = CGRectMake(CGRectGetMaxX(_resetBtn.frame) + 10.0, gy, 360.0, 36.0);
	_hint.hidden = !_edit;

	UIView *panels[GROUP_COUNT] = { _bar, _quick, _groups };
	for (int g = 0; g < GROUP_COUNT; ++g) {
		UIView *p = panels[g];
		const BOOL shown = _edit && !p.hidden;
		_pill[g].hidden = !shown;
		p.layer.borderColor = (_edit ? amber() : cyan()).CGColor;
		p.layer.borderWidth = _edit ? 2.0 : 0.5;
		if (shown) {
			const CGFloat pw = 84.0, ph = 38.0;
			CGFloat px = CGRectGetMidX(p.frame) - pw * 0.5;
			px = MAX(safe.left + 2.0, MIN(W - safe.right - pw - 2.0, px));
			CGFloat py = p.frame.origin.y - ph - 4.0;
			if (py < safe.top + 2.0) py = CGRectGetMaxY(p.frame) + 4.0;
			if (py + ph > H - safe.bottom) py = p.frame.origin.y + 4.0;
			_pill[g].frame = CGRectMake(px, py, pw, ph);
			[_root bringSubviewToFront:_pill[g]];
		}
	}
	[_root bringSubviewToFront:_gear];
	[_root bringSubviewToFront:_resetBtn];
}

- (void)setQuickAnchorLeft:(CGFloat)left top:(CGFloat)top width:(CGFloat)width
{
	if (fabs(left - _anchorLeft) < 0.5 && fabs(top - _anchorTop) < 0.5 && fabs(width - _anchorWidth) < 0.5) return;
	_anchorLeft = left;
	_anchorTop = top;
	_anchorWidth = width;
	[self layoutAll];
}

- (void)toggleBar
{
	_open = !_open;
	[self layoutAll];
}

- (void)toggleGroups
{
	_groupsOpen = !_groupsOpen;
	[self layoutAll];
}

// ---- edit mode ----

- (void)setEditMode:(BOOL)on
{
	if (_edit == on) return;
	if (on) [self releaseAllLatches];
	_edit = on;
	for (UIView *p in @[ _bar, _quick, _groups ]) {
		for (UIGestureRecognizer *gr in p.gestureRecognizers) {
			if ([gr isKindOfClass:[UIPanGestureRecognizer class]]) gr.enabled = on;
		}
	}
	if (!on) [self saveConfig];
	[self layoutAll];
}

- (void)gearTapped { [self setEditMode:!_edit]; }

- (void)arrowHeld:(UILongPressGestureRecognizer *)gr
{
	if (gr.state == UIGestureRecognizerStateBegan) [self setEditMode:YES];
}

- (void)resetLayout
{
	for (int g = 0; g < GROUP_COUNT; ++g) {
		_cx[g] = -1.0;
		_cy[g] = -1.0;
		_scale[g] = 1.0;
	}
	[self saveConfig];
	[self layoutAll];
}

- (void)sizeTapped:(UIButton *)b
{
	const int g = (int)(b.tag / 10);
	const BOOL plus = (b.tag % 10) == 1;
	_scale[g] = MIN(1.6, MAX(0.6, _scale[g] + (plus ? 0.1 : -0.1)));
	[self layoutAll];
	[self saveConfig];
}

- (void)groupPanned:(UIPanGestureRecognizer *)gr
{
	UIView *v = gr.view;
	const int g = (int)v.tag;
	const CGFloat W = _root.bounds.size.width, H = _root.bounds.size.height;
	if (W < 1 || H < 1) return;
	if (gr.state == UIGestureRecognizerStateChanged || gr.state == UIGestureRecognizerStateEnded) {
		CGPoint t = [gr translationInView:_root];
		[gr setTranslation:CGPointZero inView:_root];
		_cx[g] = (v.center.x + t.x) / W;
		_cy[g] = (v.center.y + t.y) / H;
		[self layoutAll];
		// keep what the screen actually shows (the frame is kept inside the safe area)
		_cx[g] = v.center.x / W;
		_cy[g] = v.center.y / H;
	}
	if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) [self saveConfig];
}

// Replay playback: show the speed buttons (starting at 1x); leaving the replay puts the speed back to normal.
- (void)setReplayMode:(BOOL)on
{
	if (!_root || _replayMode == on) return;
	_replayMode = on;
	gxHotkeySetReplaySpeed(1);
	for (GXKeyButton *b in _buttons) {
		if (kKeys[b.defIndex].kind == KIND_REPLAY) b.latched = (on && kKeys[b.defIndex].code == 1);
	}
	[self layoutAll];
}

- (void)setVisible:(BOOL)visible
{
	if (!_root) return;
	_root.hidden = !visible;
	if (!visible) {
		// leaving the match: drop anything held down
		if (_edit) [self setEditMode:NO];
		[self releaseAllLatches];
		_open = NO;
		_moreOpen = NO;
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
	gxHotkeySetPointMode(false);
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

// "Queue path" (Alt) must not stay held after the orders are given: let go of every latched toggle.
- (void)releaseToggles
{
	for (GXKeyButton *b in _buttons) {
		if (!b.latched || kKeys[b.defIndex].kind != KIND_TOGGLE) continue;
		gxHotkeySendKey(kKeys[b.defIndex].code, false);
		b.latched = NO;
	}
}

- (void)keyDown:(GXKeyButton *)b
{
	const KeyDef &d = kKeys[b.defIndex];
	// any other order button ends a queued path (Alt)
	if (d.kind == KIND_KEY || d.kind == KIND_NUMBER || d.kind == KIND_POINT || (d.kind == KIND_ACTION && d.code != ACT_MORE)) {
		[self releaseToggles];
	}
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
		case KIND_POINT:
			b.latched = !b.latched;
			gxHotkeySetPointMode(b.latched ? true : false);
			break;
		case KIND_REPLAY:
			gxHotkeySetReplaySpeed(d.code);
			for (GXKeyButton *other in _buttons) {
				if (kKeys[other.defIndex].kind == KIND_REPLAY) other.latched = (other == b);
			}
			break;
		case KIND_ACTION:
			if (d.code == ACT_MORE) {
				// opens / closes the extra buttons; the button itself is not left lit
				_moreOpen = !_moreOpen;
				[self layoutAll];
			} else {
				[self runAction:d.code];
			}
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

// The engine used the "Point" mode for one tap: the button's light goes off.
- (void)pointModeConsumed
{
	for (GXKeyButton *b in _buttons) {
		if (kKeys[b.defIndex].kind == KIND_POINT) b.latched = NO;
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

void gxHotkeyOverlaySetQuickAnchor(float left, float top, float width)
{
	[[GXHotkeyController shared] setQuickAnchorLeft:left top:top width:width];
}

void gxHotkeyNotifyTapDone()
{
	[[GXHotkeyController shared] tapDone];
}

void gxHotkeyOverlaySetReplay(bool replay)
{
	[[GXHotkeyController shared] setReplayMode:replay ? YES : NO];
}

void gxHotkeyReleaseQueuePath()
{
	[[GXHotkeyController shared] releaseToggles];
}

void gxHotkeyPointModeConsumed()
{
	[[GXHotkeyController shared] pointModeConsumed];
}

// ---------------------------------------------------------------------------
// Background time: when the app leaves the foreground (answering a call, switching app) iOS normally
// freezes it within seconds. A background task asks for up to ~30 s, so the game's network keeps being
// serviced and the other players do not count us as gone.
static UIBackgroundTaskIdentifier g_bgTask = UIBackgroundTaskInvalid;

static void gxRunOnMain(void (^block)(void))
{
	if ([NSThread isMainThread]) block();
	else dispatch_async(dispatch_get_main_queue(), block);
}

void gxBackgroundTaskBegin()
{
	gxRunOnMain(^{
		if (g_bgTask != UIBackgroundTaskInvalid) return;
		g_bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"GeneralsNetwork" expirationHandler:^{
			UIBackgroundTaskIdentifier t = g_bgTask;
			g_bgTask = UIBackgroundTaskInvalid;
			if (t != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:t];
		}];
	});
}

void gxBackgroundTaskEnd()
{
	gxRunOnMain(^{
		UIBackgroundTaskIdentifier t = g_bgTask;
		g_bgTask = UIBackgroundTaskInvalid;
		if (t != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:t];
	});
}

#endif // TARGET_OS_IPHONE
