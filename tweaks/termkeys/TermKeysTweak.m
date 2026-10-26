//
//  TermKeysTweak.m — 给终端类 App 增补 Shift、F1–F12 和常用控制键。
//
//  系统键盘扩展无法传递硬件修饰键状态，所以这里把按键编码成 xterm 序列，
//  直接交给当前 UIKeyInput。对 xterm 兼容终端有效；普通文本输入框没有
//  “功能键”这层语义。插件由 TrollFools 或 MobileSubstrate 注入宿主进程。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static const CGFloat TKBarHeight = 88.0;
static const CGFloat TKRowHeight = 40.0;
static const CGFloat TKButtonSize = 34.0;
static const CGFloat TKButtonSpacing = 7.0;

static UIResponder *TKFindFirstResponder(UIView *view) {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIResponder *found = TKFindFirstResponder(subview);
        if (found) {
            return found;
        }
    }
    return nil;
}

static BOOL TKIsKeyboardWindow(UIWindow *window) {
    NSString *name = NSStringFromClass(window.class);
    return [name containsString:@"Keyboard"] || [name containsString:@"TextEffects"];
}

static UIWindow *TKHostWindow(void) {
    UIWindow *firstVisible = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (TKIsKeyboardWindow(window)) {
            continue;
        }
        if (window.isKeyWindow && window.rootViewController) {
            return window;
        }
        if (!firstVisible && !window.hidden && window.rootViewController) {
            firstVisible = window;
        }
    }
    return firstVisible;
}

static UIResponder *TKCurrentInput(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIResponder *responder = TKFindFirstResponder(window);
        if ([responder respondsToSelector:@selector(insertText:)]) {
            return responder;
        }
    }
    return nil;
}

static char TKStatusBarCoverKey;

static void TKUpdateStatusBarCover(UIWindow *window) {
    if (!window || TKIsKeyboardWindow(window)) {
        return;
    }
    UIView *cover = objc_getAssociatedObject(window, &TKStatusBarCoverKey);
    if (!cover) {
        cover = [[UIView alloc] initWithFrame:CGRectZero];
        cover.userInteractionEnabled = NO;
        cover.backgroundColor = UIColor.systemBackgroundColor;
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        objc_setAssociatedObject(window, &TKStatusBarCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window addSubview:cover];
    }
    CGFloat top = window.safeAreaInsets.top;
    if (top <= 0 && window.windowScene.statusBarManager) {
        top = window.windowScene.statusBarManager.statusBarFrame.size.height;
    }
    if (top <= 0) {
        top = 44.0;
    }
    cover.frame = CGRectMake(0, 0, CGRectGetWidth(window.bounds), top);
    [window bringSubviewToFront:cover];
}

typedef bool (*TKSwiftSendKeyFn)(id, uint8_t, uint32_t);

static TKSwiftSendKeyFn TKSwiftSendKeyFunction(void) {
    static TKSwiftSendKeyFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *name =
            "$s15GhosttyTerminal14UITerminalViewC7sendKey_9modifiersSbAA0bF0O_AA0B14InputModifiersVtF";
        function = (TKSwiftSendKeyFn)dlsym(RTLD_DEFAULT, name);
        if (!function) {
            char underscored[256];
            snprintf(underscored, sizeof(underscored), "_%s", name);
            function = (TKSwiftSendKeyFn)dlsym(RTLD_DEFAULT, underscored);
        }
    });
    return function;
}

static BOOL TKIsTerminalView(UIResponder *responder) {
    if (!responder) {
        return NO;
    }
    const char *name = class_getName(object_getClass(responder));
    return name && strstr(name, "UITerminalView") != NULL;
}

static BOOL TKTryNativeKey(uint8_t key, uint32_t modifiers) {
    UIResponder *input = TKCurrentInput();
    if (!TKIsTerminalView(input)) {
        return NO;
    }
    TKSwiftSendKeyFn function = TKSwiftSendKeyFunction();
    if (!function) {
        return NO;
    }
    return function(input, key, modifiers) ? YES : NO;
}

static NSString *TKFunctionKey(NSInteger number, BOOL shift) {
    static NSString *const fkeys[] = {
        @"", @"\x1bOP", @"\x1bOQ", @"\x1bOR", @"\x1bOS",
        @"\x1b[15~", @"\x1b[17~", @"\x1b[18~", @"\x1b[19~",
        @"\x1b[20~", @"\x1b[21~", @"\x1b[23~", @"\x1b[24~",
    };
    static NSString *const shiftedF5to12[] = {
        @"", @"\x1b[15;2~", @"\x1b[17;2~", @"\x1b[18;2~", @"\x1b[19;2~",
        @"\x1b[20;2~", @"\x1b[21;2~", @"\x1b[23;2~", @"\x1b[24;2~",
    };

    if (number < 1 || number > 12) {
        return @"";
    }
    if (!shift) {
        return fkeys[number];
    }
    if (number <= 4) {
        unichar final = (unichar)('P' + number - 1);
        return [NSString stringWithFormat:@"\x1b[1;2%C", final];
    }
    return shiftedF5to12[number - 4];
}

typedef NS_ENUM(NSInteger, TKShiftState) {
    TKShiftStateInactive,
    TKShiftStateArmed,
    TKShiftStateLocked,
};

@interface TKBarView : UIView
@property(nonatomic, strong) UIScrollView *topScrollView;
@property(nonatomic, strong) UIStackView *topStackView;
@property(nonatomic, strong) UIScrollView *functionScrollView;
@property(nonatomic, strong) UIStackView *functionStackView;
@property(nonatomic, strong) UIButton *shiftButton;
@property(nonatomic, strong) UIView *lockDot;
@property(nonatomic, strong) UIView *nativeAccessoryView;
@property(nonatomic, strong) NSTimer *arrowRepeatTimer;
@property(nonatomic, weak) UIButton *arrowRepeatButton;
@property(nonatomic, assign) TKShiftState shiftState;
@property(nonatomic, strong) NSDate *lastShiftTapDate;
@end

@implementation TKBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = 14.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.18;
    self.layer.shadowRadius = 8.0;
    self.layer.shadowOffset = CGSizeMake(0, -2);

    UIVisualEffectView *backdrop =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.layer.cornerRadius = 14.0;
    backdrop.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    backdrop.clipsToBounds = YES;
    [self addSubview:backdrop];

    self.topScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.topScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.topScrollView.showsHorizontalScrollIndicator = NO;
    self.topScrollView.scrollEnabled = NO;
    self.topScrollView.alwaysBounceHorizontal = NO;
    self.topScrollView.bounces = NO;
    self.topScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:self.topScrollView];

    self.topStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.topStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.topStackView.axis = UILayoutConstraintAxisHorizontal;
    self.topStackView.alignment = UIStackViewAlignmentCenter;
    self.topStackView.spacing = TKButtonSpacing;
    [self.topScrollView addSubview:self.topStackView];

    self.functionScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.functionScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.functionScrollView.showsHorizontalScrollIndicator = NO;
    self.functionScrollView.alwaysBounceHorizontal = YES;
    self.functionScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:self.functionScrollView];

    self.functionStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.functionStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.functionStackView.axis = UILayoutConstraintAxisHorizontal;
    self.functionStackView.alignment = UIStackViewAlignmentCenter;
    self.functionStackView.spacing = TKButtonSpacing;
    [self.functionScrollView addSubview:self.functionStackView];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.topScrollView.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [self.topScrollView.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [self.topScrollView.topAnchor constraintEqualToAnchor:backdrop.contentView.topAnchor],
        [self.topScrollView.heightAnchor constraintEqualToConstant:TKRowHeight],

        [self.topStackView.leadingAnchor constraintEqualToAnchor:self.topScrollView.contentLayoutGuide.leadingAnchor constant:8.0],
        [self.topStackView.trailingAnchor constraintEqualToAnchor:self.topScrollView.frameLayoutGuide.trailingAnchor constant:-8.0],
        [self.topStackView.topAnchor constraintEqualToAnchor:self.topScrollView.contentLayoutGuide.topAnchor],
        [self.topStackView.bottomAnchor constraintEqualToAnchor:self.topScrollView.contentLayoutGuide.bottomAnchor],
        [self.topStackView.heightAnchor constraintEqualToAnchor:self.topScrollView.frameLayoutGuide.heightAnchor],

        [self.functionScrollView.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [self.functionScrollView.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [self.functionScrollView.topAnchor constraintEqualToAnchor:self.topScrollView.bottomAnchor constant:4.0],
        [self.functionScrollView.heightAnchor constraintEqualToConstant:TKRowHeight],
        [self.functionScrollView.bottomAnchor constraintEqualToAnchor:backdrop.contentView.bottomAnchor constant:-4.0],

        [self.functionStackView.leadingAnchor constraintEqualToAnchor:self.functionScrollView.contentLayoutGuide.leadingAnchor constant:8.0],
        [self.functionStackView.trailingAnchor constraintEqualToAnchor:self.functionScrollView.contentLayoutGuide.trailingAnchor constant:-8.0],
        [self.functionStackView.topAnchor constraintEqualToAnchor:self.functionScrollView.contentLayoutGuide.topAnchor],
        [self.functionStackView.bottomAnchor constraintEqualToAnchor:self.functionScrollView.contentLayoutGuide.bottomAnchor],
        [self.functionStackView.heightAnchor constraintEqualToAnchor:self.functionScrollView.frameLayoutGuide.heightAnchor],
    ]];

    self.shiftButton = [self addButton:@"" action:@selector(toggleShift) width:44.0 stack:self.topStackView];
    UIImageConfiguration *symbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightMedium];
    UIImage *shiftImage = [UIImage systemImageNamed:@"shift" withConfiguration:symbolConfiguration];
    if (!shiftImage) {
        shiftImage = [UIImage systemImageNamed:@"shift.fill" withConfiguration:symbolConfiguration];
    }
    [self.shiftButton setImage:shiftImage forState:UIControlStateNormal];
    self.shiftButton.accessibilityLabel = @"Shift";
    self.shiftButton.accessibilityHint = @"单击一次生效，双击锁定";

    self.lockDot = [[UIView alloc] initWithFrame:CGRectZero];
    self.lockDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.lockDot.userInteractionEnabled = NO;
    self.lockDot.backgroundColor = UIColor.whiteColor;
    self.lockDot.layer.cornerRadius = 3.0;
    self.lockDot.hidden = YES;
    [self.shiftButton addSubview:self.lockDot];
    [NSLayoutConstraint activateConstraints:@[
        [self.lockDot.widthAnchor constraintEqualToConstant:6.0],
        [self.lockDot.heightAnchor constraintEqualToConstant:6.0],
        [self.lockDot.trailingAnchor constraintEqualToAnchor:self.shiftButton.trailingAnchor constant:-8.0],
        [self.lockDot.topAnchor constraintEqualToAnchor:self.shiftButton.topAnchor constant:8.0],
    ]];

    [self addButton:@"NL" action:@selector(sendNewline) width:42.0 stack:self.topStackView];

    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.topStackView addArrangedSubview:spacer];

    [self addArrowButton:@"←" tag:1];
    [self addArrowButton:@"↑" tag:2];
    [self addArrowButton:@"↓" tag:3];
    [self addArrowButton:@"→" tag:4];

    for (NSInteger number = 1; number <= 12; number++) {
        UIButton *button = [self addButton:[NSString stringWithFormat:@"F%ld", (long)number]
                                    action:@selector(sendFunction:)
                                     width:40.0
                                     stack:self.functionStackView];
        button.tag = number;
    }

    [self updateShiftAppearance];
    return self;
}

- (UIButton *)addButton:(NSString *)title action:(SEL)action width:(CGFloat)width stack:(UIStackView *)stack {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:(width <= 36.0 ? 11.0 : 12.0) weight:UIFontWeightSemibold];
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    button.backgroundColor = UIColor.tertiarySystemFillColor;
    button.layer.cornerRadius = TKButtonSize * 0.5;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = title;
    [button.widthAnchor constraintEqualToConstant:width].active = YES;
    [button.heightAnchor constraintEqualToConstant:TKButtonSize].active = YES;
    [stack addArrangedSubview:button];
    return button;
}

- (void)addArrowButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *button = [self addButton:title action:@selector(sendArrowButton:) width:38.0 stack:self.topStackView];
    button.tag = tag;
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightSemibold];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleArrowLongPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.cancelsTouchesInView = YES;
    [button addGestureRecognizer:longPress];
}

- (void)sendArrowButton:(UIButton *)button {
    switch (button.tag) {
        case 1: [self sendLeft]; break;
        case 2: [self sendUp]; break;
        case 3: [self sendDown]; break;
        case 4: [self sendRight]; break;
        default: break;
    }
}

- (void)handleArrowLongPress:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self stopArrowRepeat];
        self.arrowRepeatButton = button;
        [self sendArrowButton:button];
        self.arrowRepeatTimer = [NSTimer timerWithTimeInterval:0.075
                                                        target:self
                                                      selector:@selector(repeatArrow)
                                                      userInfo:nil
                                                       repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.arrowRepeatTimer forMode:NSRunLoopCommonModes];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled ||
               gesture.state == UIGestureRecognizerStateFailed) {
        [self stopArrowRepeat];
    }
}

- (void)repeatArrow {
    if (!self.arrowRepeatButton) {
        [self stopArrowRepeat];
        return;
    }
    [self sendArrowButton:self.arrowRepeatButton];
}

- (void)stopArrowRepeat {
    [self.arrowRepeatTimer invalidate];
    self.arrowRepeatTimer = nil;
    self.arrowRepeatButton = nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = TKHostWindow();
        if (window) {
            TKUpdateStatusBarCover(window);
        }
    });
}

- (void)dealloc {
    [self.arrowRepeatTimer invalidate];
}

- (void)toggleShift {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.shiftState == TKShiftStateInactive) {
        self.shiftState = TKShiftStateArmed;
    } else if (self.shiftState == TKShiftStateArmed &&
               now - self.lastShiftTapDate.timeIntervalSince1970 < 0.35) {
        self.shiftState = TKShiftStateLocked;
    } else {
        self.shiftState = TKShiftStateInactive;
    }
    self.lastShiftTapDate = [NSDate date];
    [self updateShiftAppearance];
}

- (void)updateShiftAppearance {
    BOOL active = self.shiftState != TKShiftStateInactive;
    BOOL locked = self.shiftState == TKShiftStateLocked;
    self.shiftButton.backgroundColor = active ? UIColor.systemBlueColor : UIColor.tertiarySystemFillColor;
    self.shiftButton.tintColor = active ? UIColor.whiteColor : UIColor.labelColor;
    self.lockDot.hidden = !locked;
    self.shiftButton.accessibilityValue = locked ? @"锁定" : (active ? @"待用" : @"关闭");
}

- (BOOL)consumeShift {
    if (self.shiftState == TKShiftStateLocked) {
        return YES;
    }
    if (self.shiftState == TKShiftStateArmed) {
        self.shiftState = TKShiftStateInactive;
        [self updateShiftAppearance];
        return YES;
    }
    return NO;
}

- (void)sendText:(NSString *)text {
    if (text.length == 0) {
        return;
    }
    UIResponder *input = TKCurrentInput();
    SEL insert = @selector(insertText:);
    if (input && [input respondsToSelector:insert]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(input, insert, text);
    }
}

static UIControl *TKFindButton(UIView *view, NSString *accessibilityLabel) {
    if ([view isKindOfClass:UIControl.class] &&
        [view.accessibilityLabel isEqualToString:accessibilityLabel]) {
        return (UIControl *)view;
    }
    for (UIView *subview in view.subviews) {
        UIControl *found = TKFindButton(subview, accessibilityLabel);
        if (found) {
            return found;
        }
    }
    return nil;
}

- (BOOL)sendControlKeyThroughNativeBar:(NSString *)key {
    if (!self.nativeAccessoryView) {
        return NO;
    }
    UIControl *control = TKFindButton(self.nativeAccessoryView, @"Control");
    if (!control || !control.isEnabled) {
        return NO;
    }
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self sendText:key];
    return YES;
}

- (void)sendNewline {
    if (TKTryNativeKey(28, 2u)) { // TerminalKey.j + Ctrl
        return;
    }
    if ([self sendControlKeyThroughNativeBar:@"j"]) {
        return;
    }
    // Fallback for terminals without the native Ctrl accessory: a one-byte
    // LF inside a bracketed paste reaches the app as text, not as Return.
    [self sendText:@"\x1b[200~\n\x1b[201~"];
}

- (void)sendLeft { [self sendArrow:'D']; }
- (void)sendUp { [self sendArrow:'A']; }
- (void)sendDown { [self sendArrow:'B']; }
- (void)sendRight { [self sendArrow:'C']; }

- (void)sendArrow:(unichar)final {
    BOOL shift = [self consumeShift];
    uint8_t nativeKey = 0;
    switch (final) {
        case 'A': nativeKey = 77; break; // TerminalKey.arrowUp
        case 'B': nativeKey = 74; break; // TerminalKey.arrowDown
        case 'C': nativeKey = 76; break; // TerminalKey.arrowRight
        case 'D': nativeKey = 75; break; // TerminalKey.arrowLeft
        default: break;
    }
    if (nativeKey && TKTryNativeKey(nativeKey, shift ? 1u : 0u)) {
        return;
    }
    if (shift) {
        [self sendText:[NSString stringWithFormat:@"\x1b[1;2%C", final]];
    } else {
        [self sendText:[NSString stringWithFormat:@"\x1b[%C", final]];
    }
}

- (void)sendFunction:(UIButton *)sender {
    BOOL shift = [self consumeShift];
    uint8_t nativeKey = (uint8_t)(119 + sender.tag); // F1 = 120 ... F12 = 131
    if (TKTryNativeKey(nativeKey, shift ? 1u : 0u)) {
        return;
    }
    [self sendText:TKFunctionKey(sender.tag, shift)];
}

@end

@interface TKCombinedAccessoryView : UIView
@property(nonatomic, strong) TKBarView *termKeysBar;
@property(nonatomic, strong) UIView *originalAccessory;
- (instancetype)initWithOriginalAccessory:(UIView *)originalAccessory;
@end

@implementation TKCombinedAccessoryView

@synthesize originalAccessory = _originalAccessory;

- (instancetype)initWithOriginalAccessory:(UIView *)originalAccessory {
    CGFloat originalHeight = originalAccessory
        ? MAX(originalAccessory.intrinsicContentSize.height, 44.0)
        : 0.0;
    CGRect initialFrame = CGRectMake(
        0,
        0,
        UIScreen.mainScreen.bounds.size.width,
        TKBarHeight + originalHeight
    );
    self = [super initWithFrame:initialFrame];
    if (!self) {
        return nil;
    }
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.termKeysBar = [[TKBarView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(initialFrame), TKBarHeight)];
    self.termKeysBar.nativeAccessoryView = originalAccessory;
    [self addSubview:self.termKeysBar];
    self.originalAccessory = originalAccessory;
    return self;
}

- (void)setOriginalAccessory:(UIView *)originalAccessory {
    if (_originalAccessory == originalAccessory) {
        return;
    }
    [_originalAccessory removeFromSuperview];
    _originalAccessory = originalAccessory;
    self.termKeysBar.nativeAccessoryView = originalAccessory;
    if (originalAccessory) {
        originalAccessory.translatesAutoresizingMaskIntoConstraints = YES;
        originalAccessory.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:originalAccessory];
    }
    CGFloat originalHeight = originalAccessory
        ? MAX(originalAccessory.intrinsicContentSize.height, 44.0)
        : 0.0;
    CGRect frame = self.frame;
    if (CGRectGetWidth(frame) <= 0) {
        frame.size.width = UIScreen.mainScreen.bounds.size.width;
    }
    frame.size.height = TKBarHeight + originalHeight;
    self.frame = frame;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

- (CGSize)intrinsicContentSize {
    CGFloat originalHeight = self.originalAccessory
        ? MAX(self.originalAccessory.intrinsicContentSize.height, 44.0)
        : 0.0;
    return CGSizeMake(UIScreen.mainScreen.bounds.size.width, TKBarHeight + originalHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    self.termKeysBar.frame = CGRectMake(0, 0, width, TKBarHeight);
    CGFloat originalHeight = MAX(0, CGRectGetHeight(self.bounds) - TKBarHeight);
    self.originalAccessory.frame = CGRectMake(0, TKBarHeight, width, originalHeight);
}

@end

typedef UIView *(*TKInputAccessoryGetter)(id, SEL);
static TKInputAccessoryGetter TKOriginalInputAccessoryGetter;
static char TKCombinedAccessoryKey;

static Class TKFindIGhostTerminalClass(void) {
    Class direct = NSClassFromString(@"GhosttyTerminal.UITerminalView");
    if (!direct) {
        direct = NSClassFromString(@"UITerminalView");
    }
    if (direct) {
        return direct;
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        return Nil;
    }
    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    if (!classes) {
        return Nil;
    }
    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int index = 0; index < count; index++) {
        const char *name = class_getName(classes[index]);
        if (name && strstr(name, "UITerminalView")) {
            found = classes[index];
            break;
        }
    }
    free(classes);
    return found;
}

static UIView *TKInputAccessoryViewReplacement(id self, SEL command) {
    UIView *original = TKOriginalInputAccessoryGetter
        ? TKOriginalInputAccessoryGetter(self, command)
        : nil;
    TKCombinedAccessoryView *combined =
        objc_getAssociatedObject(self, &TKCombinedAccessoryKey);
    if (!combined) {
        combined = [[TKCombinedAccessoryView alloc] initWithOriginalAccessory:original];
        objc_setAssociatedObject(self, &TKCombinedAccessoryKey, combined, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        combined.originalAccessory = original;
    }
    return combined;
}

static BOOL TKInstallIGhostAccessoryHook(void) {
    Class terminalClass = TKFindIGhostTerminalClass();
    if (!terminalClass) {
        return NO;
    }
    Method method = class_getInstanceMethod(terminalClass, @selector(inputAccessoryView));
    if (!method) {
        return NO;
    }
    TKOriginalInputAccessoryGetter = (TKInputAccessoryGetter)method_getImplementation(method);
    method_setImplementation(method, (IMP)TKInputAccessoryViewReplacement);
    return YES;
}

@interface TKKeyboardBarController : NSObject
@property(nonatomic, strong) TKBarView *bar;
@property(nonatomic, weak) UIWindow *hostWindow;
@end

@implementation TKKeyboardBarController

+ (instancetype)shared {
    static TKKeyboardBarController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[TKKeyboardBarController alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(keyboardWillChangeFrame:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardWillChangeFrame:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardWillChangeFrame:)
                   name:UIKeyboardDidShowNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardWillHide:)
                   name:UIKeyboardWillHideNotification
                 object:nil];
    return self;
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = TKHostWindow();
        if (!window || CGRectIsEmpty(endFrame)) {
            return;
        }
        if (!self.bar || self.hostWindow != window) {
            [self.bar removeFromSuperview];
            self.bar = [[TKBarView alloc] initWithFrame:CGRectZero];
            [window addSubview:self.bar];
            self.hostWindow = window;
        }

        CGRect keyboardInWindow = [window convertRect:endFrame fromWindow:nil];
        CGFloat barY = CGRectGetMinY(keyboardInWindow) - TKBarHeight;
        CGRect barFrame = CGRectMake(0, barY, CGRectGetWidth(window.bounds), TKBarHeight);
        self.bar.hidden = NO;
        [UIView animateWithDuration:(duration > 0 ? duration : 0.22)
                              delay:0
                            options:(UIViewAnimationOptions)(curve << 16)
                         animations:^{ self.bar.frame = barFrame; }
                         completion:nil];
        [window bringSubviewToFront:self.bar];
    });
}

- (void)keyboardWillHide:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.bar.hidden = YES;
    });
}

@end

__attribute__((constructor))
static void TermKeysInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if ([bundleID isEqualToString:@"wiki.qaq.iGhostVT"] && TKInstallIGhostAccessoryHook()) {
            return;
        }
        (void)[TKKeyboardBarController shared];
    });
}
