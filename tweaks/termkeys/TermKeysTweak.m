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
#include <stdlib.h>
#include <string.h>

static const CGFloat TKBarHeight = 48.0;
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

@interface TKBarView : UIView
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *stackView;
@property(nonatomic, strong) UIButton *shiftButton;
@property(nonatomic, assign) BOOL shiftArmed;
@end

@implementation TKBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = 12.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.22;
    self.layer.shadowRadius = 8.0;
    self.layer.shadowOffset = CGSizeMake(0, -2);

    UIVisualEffectView *backdrop =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.layer.cornerRadius = 12.0;
    backdrop.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    backdrop.clipsToBounds = YES;
    [self addSubview:backdrop];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:self.scrollView];

    self.stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisHorizontal;
    self.stackView.alignment = UIStackViewAlignmentCenter;
    self.stackView.spacing = TKButtonSpacing;
    [self.scrollView addSubview:self.stackView];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.scrollView.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:backdrop.contentView.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:backdrop.contentView.bottomAnchor],

        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:8.0],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-8.0],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.stackView.heightAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.heightAnchor],
    ]];

    self.shiftButton = [self addButton:@"⇧" action:@selector(toggleShift) width:42.0];
    [self addButton:@"Esc" action:@selector(sendEscape) width:42.0];
    [self addButton:@"Tab" action:@selector(sendTab) width:42.0];
    [self addButton:@"⏎" action:@selector(sendEnter) width:42.0];
    [self addButton:@"NL" action:@selector(sendNewline) width:42.0];
    [self addButton:@"←" action:@selector(sendLeft) width:TKButtonSize];
    [self addButton:@"↑" action:@selector(sendUp) width:TKButtonSize];
    [self addButton:@"↓" action:@selector(sendDown) width:TKButtonSize];
    [self addButton:@"→" action:@selector(sendRight) width:TKButtonSize];
    [self addSeparator];

    for (NSInteger number = 1; number <= 12; number++) {
        UIButton *button = [self addButton:[NSString stringWithFormat:@"F%ld", (long)number]
                                    action:@selector(sendFunction:)
                                     width:38.0];
        button.tag = number;
    }

    [self updateShiftAppearance];
    return self;
}

- (UIButton *)addButton:(NSString *)title action:(SEL)action width:(CGFloat)width {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = TKButtonSize * 0.5;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = title;
    [button.widthAnchor constraintEqualToConstant:width].active = YES;
    [button.heightAnchor constraintEqualToConstant:TKButtonSize].active = YES;
    [self.stackView addArrangedSubview:button];
    return button;
}

- (void)addSeparator {
    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    separator.layer.cornerRadius = 1.0;
    [separator.widthAnchor constraintEqualToConstant:2.0].active = YES;
    [separator.heightAnchor constraintEqualToConstant:22.0].active = YES;
    [self.stackView addArrangedSubview:separator];
}

- (void)toggleShift {
    self.shiftArmed = !self.shiftArmed;
    [self updateShiftAppearance];
}

- (void)updateShiftAppearance {
    self.shiftButton.backgroundColor = self.shiftArmed
        ? [UIColor colorWithRed:0.22 green:0.52 blue:1.0 alpha:1.0]
        : [UIColor colorWithWhite:1.0 alpha:0.14];
    [self.shiftButton setTitleColor:(self.shiftArmed ? UIColor.whiteColor : UIColor.labelColor)
                           forState:UIControlStateNormal];
    self.shiftButton.accessibilityValue = self.shiftArmed ? @"开" : @"关";
}

- (BOOL)consumeShift {
    BOOL armed = self.shiftArmed;
    if (armed) {
        self.shiftArmed = NO;
        [self updateShiftAppearance];
    }
    return armed;
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

- (void)sendEscape {
    [self consumeShift];
    [self sendText:@"\x1b"];
}

- (void)sendTab {
    BOOL shift = [self consumeShift];
    [self sendText:(shift ? @"\x1b[Z" : @"\t")];
}

- (void)sendEnter {
    BOOL shift = [self consumeShift];
    [self sendText:(shift ? @"\n" : @"\r")];
}

- (void)sendNewline {
    [self consumeShift];
    [self sendText:@"\n"];
}

- (void)sendLeft { [self sendArrow:'D']; }
- (void)sendUp { [self sendArrow:'A']; }
- (void)sendDown { [self sendArrow:'B']; }
- (void)sendRight { [self sendArrow:'C']; }

- (void)sendArrow:(unichar)final {
    BOOL shift = [self consumeShift];
    if (shift) {
        [self sendText:[NSString stringWithFormat:@"\x1b[1;2%C", final]];
    } else {
        [self sendText:[NSString stringWithFormat:@"\x1b[%C", final]];
    }
}

- (void)sendFunction:(UIButton *)sender {
    BOOL shift = [self consumeShift];
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
