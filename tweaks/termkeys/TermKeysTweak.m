//
//  TermKeysTweak.m — 给终端类 App 增补 Shift、NL 和 F1–F12。
//
//  系统键盘扩展无法传递硬件修饰键状态，所以这里把按键交给终端自己的按键
//  入口（拿不到时退回 xterm 序列）。插件由 TrollFools 或 MobileSubstrate
//  注入宿主进程。
//
//  iGhostVT：按键直接加进它自带的键盘附件栏（libghostty 的
//  TerminalInputAccessoryView），键栏高度不变，键盘高度也就与官方版一致，
//  终端布局完全不受影响。另加一层键栏会把键盘撑高，iOS 15 的键盘避让随后
//  把整窗内容上顶，终端首行压到状态栏下面——那是之前一直修不好的根因。
//
//  其他终端 App：仍浮一条两行键栏在键盘上方（它们没有 iGhostVT 那种
//  自带键栏可加）。
//
//  运行时开关（`defaults write <bundle-id> <key> ...`）：
//    TermKeys.diag -bool NO   关掉 Documents/termkeys-diag.log 诊断日志
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const CGFloat TKBarHeight = 88.0;
static const CGFloat TKRowHeight = 40.0;
static const CGFloat TKButtonSize = 34.0;
static const CGFloat TKButtonSpacing = 7.0;

#pragma mark - 诊断日志

static NSString *const TKDiagKey = @"TermKeys.diag";

static BOOL TKDiagEnabled(void) {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:TKDiagKey];
    return value ? value.boolValue : YES;
}

static NSString *TKDiagPath(void) {
    NSString *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return documents ? [documents stringByAppendingPathComponent:@"termkeys-diag.log"] : nil;
}

static void TKDiag(NSString *format, ...) {
    if (!TKDiagEnabled()) {
        return;
    }
    NSString *path = TKDiagPath();
    if (!path) {
        return;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attributes.fileSize > 256 * 1024) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      NSProcessInfo.processInfo.systemUptime, message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 宿主窗口与当前输入

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

static UIControl *TKFindControl(UIView *view, NSString *accessibilityLabel) {
    if ([view isKindOfClass:UIControl.class] &&
        [view.accessibilityLabel isEqualToString:accessibilityLabel]) {
        return (UIControl *)view;
    }
    for (UIView *subview in view.subviews) {
        UIControl *found = TKFindControl(subview, accessibilityLabel);
        if (found) {
            return found;
        }
    }
    return nil;
}

#pragma mark - Ghostty 原生按键入口
//
// UITerminalView 的 `sendKey(_:modifiers:)` 是 Swift 方法：self 在 x20，
// 按键码在 x0，修饰键在 x1。走原生入口，F 键才不会被拆成 ESC。

typedef bool (*TKSwiftSendKeyFn)(void);

__attribute__((naked))
static bool TKCallSwiftSendKey(id view, uint8_t key, uint32_t modifiers, TKSwiftSendKeyFn function) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "stp x19, x20, [sp, #-16]!\n"
        "mov x19, x3\n"
        "mov x20, x0\n"
        "mov w0, w1\n"
        "mov w1, w2\n"
        "blr x19\n"
        "ldp x19, x20, [sp], #16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n"
    );
}

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

static Class TKTerminalClass(void) {
    static Class terminalClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terminalClass = NSClassFromString(@"GhosttyTerminal.UITerminalView");
    });
    return terminalClass;
}

static BOOL TKIsTerminalView(UIResponder *responder) {
    // iGhostVT 的焦点类是 LockableTerminalView（UITerminalView 的子类），
    // 按继承关系匹配，才能走原生按键分支。
    Class terminalClass = TKTerminalClass();
    return responder && terminalClass && [responder isKindOfClass:terminalClass];
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
    return TKCallSwiftSendKey(input, key, modifiers, function) ? YES : NO;
}

static void TKInsertText(NSString *text) {
    if (text.length == 0) {
        return;
    }
    UIResponder *input = TKCurrentInput();
    SEL insert = @selector(insertText:);
    if (input && [input respondsToSelector:insert]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(input, insert, text);
    }
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

#pragma mark - Shift 粘滞状态
//
// 单击一次生效，0.35 秒内再点一次锁定，再点解除。

typedef NS_ENUM(NSInteger, TKShiftState) {
    TKShiftStateInactive,
    TKShiftStateArmed,
    TKShiftStateLocked,
};

@interface TKShiftController : NSObject
@property(nonatomic, assign) TKShiftState state;
@property(nonatomic, strong) NSDate *lastTapDate;
@property(nonatomic, copy) void (^onChange)(void);
+ (instancetype)shared;
- (void)toggle;
- (BOOL)consume;
- (BOOL)isActive;
- (BOOL)isLocked;
@end

@implementation TKShiftController

+ (instancetype)shared {
    static TKShiftController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[TKShiftController alloc] init];
    });
    return controller;
}

- (void)toggle {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.state == TKShiftStateInactive) {
        self.state = TKShiftStateArmed;
    } else if (self.state == TKShiftStateArmed &&
               now - self.lastTapDate.timeIntervalSince1970 < 0.35) {
        self.state = TKShiftStateLocked;
    } else {
        self.state = TKShiftStateInactive;
    }
    self.lastTapDate = [NSDate date];
    if (self.onChange) {
        self.onChange();
    }
}

- (BOOL)consume {
    if (self.state == TKShiftStateLocked) {
        return YES;
    }
    if (self.state == TKShiftStateArmed) {
        self.state = TKShiftStateInactive;
        if (self.onChange) {
            self.onChange();
        }
        return YES;
    }
    return NO;
}

- (BOOL)isActive {
    return self.state != TKShiftStateInactive;
}

- (BOOL)isLocked {
    return self.state == TKShiftStateLocked;
}

@end

#pragma mark - 按键发送

static void TKSendArrow(unichar final) {
    BOOL shift = [TKShiftController.shared consume];
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
    TKInsertText(shift ? [NSString stringWithFormat:@"\x1b[1;2%C", final]
                       : [NSString stringWithFormat:@"\x1b[%C", final]);
}

static void TKSendFunctionKey(NSInteger number) {
    BOOL shift = [TKShiftController.shared consume];
    uint8_t nativeKey = (uint8_t)(119 + number); // F1 = 120 ... F12 = 131
    if (TKTryNativeKey(nativeKey, shift ? 1u : 0u)) {
        return;
    }
    TKInsertText(TKFunctionKey(number, shift));
}

// NL：终端层的换行。裸 LF 会被软件键盘路由成回车直接提交，所以走 Ctrl+J；
// 拿不到原生入口时借用 App 自带键栏的 Ctrl 键，最后才用括号粘贴兜底。
static void TKSendNewline(void) {
    if (TKTryNativeKey(28, 2u)) { // TerminalKey.j + Ctrl
        return;
    }
    UIWindow *window = TKHostWindow();
    UIControl *control = window ? TKFindControl((UIView *)window, @"Control") : nil;
    if (control && control.isEnabled) {
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        TKInsertText(@"j");
        return;
    }
    TKInsertText(@"\x1b[200~\n\x1b[201~");
}

#pragma mark - 按键外观

static UIImage *TKShiftImage(void) {
    UIImageConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:@"shift" withConfiguration:configuration];
    return image ?: [UIImage systemImageNamed:@"shift.fill" withConfiguration:configuration];
}

static UIFont *TKKeyFont(void) {
    return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
}

static UIFont *TKArrowFont(void) {
    return [UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightSemibold];
}

@interface TKKeyButton : UIButton
@property(nonatomic, copy) void (^onTap)(void);
@property(nonatomic, copy) void (^onRepeat)(void);
@property(nonatomic, strong) NSTimer *repeatTimer;
@end

@implementation TKKeyButton

- (instancetype)initWithTitle:(NSString *)title width:(CGFloat)width font:(UIFont *)font {
    self = [super initWithFrame:CGRectZero];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self setTitle:title forState:UIControlStateNormal];
    self.titleLabel.font = font;
    [self setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    self.backgroundColor = UIColor.tertiarySystemFillColor;
    self.layer.cornerRadius = TKButtonSize * 0.5;
    self.layer.masksToBounds = YES;
    self.accessibilityLabel = title;
    [self.widthAnchor constraintEqualToConstant:width].active = YES;
    [self.heightAnchor constraintEqualToConstant:TKButtonSize].active = YES;
    [self addTarget:self action:@selector(tk_handleTap) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)tk_handleTap {
    if (self.onTap) {
        self.onTap();
    }
}

- (void)tk_enableRepeat {
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tk_handleLongPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.cancelsTouchesInView = YES;
    [self addGestureRecognizer:longPress];
}

- (void)tk_handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self tk_stopRepeat];
        if (self.onRepeat) {
            self.onRepeat();
        }
        __weak typeof(self) weakSelf = self;
        self.repeatTimer = [NSTimer timerWithTimeInterval:0.075 repeats:YES block:^(__unused NSTimer *timer) {
            if (weakSelf.onRepeat) {
                weakSelf.onRepeat();
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:self.repeatTimer forMode:NSRunLoopCommonModes];
    } else if (gesture.state != UIGestureRecognizerStatePossible) {
        [self tk_stopRepeat];
    }
}

- (void)tk_stopRepeat {
    [self.repeatTimer invalidate];
    self.repeatTimer = nil;
}

- (void)dealloc {
    [_repeatTimer invalidate];
}

@end

static TKKeyButton *TKMakeButton(NSString *title, CGFloat width, UIFont *font) {
    return [[TKKeyButton alloc] initWithTitle:title width:width font:font];
}

static TKKeyButton *TKMakeShiftButton(CGFloat width) {
    TKKeyButton *shift = TKMakeButton(@"", width, TKKeyFont());
    [shift setImage:TKShiftImage() forState:UIControlStateNormal];
    shift.accessibilityLabel = @"Shift";
    shift.accessibilityHint = @"单击一次生效，双击锁定";

    UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.userInteractionEnabled = NO;
    dot.backgroundColor = UIColor.whiteColor;
    dot.layer.cornerRadius = 3.0;
    dot.hidden = YES;
    [shift addSubview:dot];
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:6.0],
        [dot.heightAnchor constraintEqualToConstant:6.0],
        [dot.trailingAnchor constraintEqualToAnchor:shift.trailingAnchor constant:-6.0],
        [dot.topAnchor constraintEqualToAnchor:shift.topAnchor constant:6.0],
    ]];

    TKShiftController *controller = TKShiftController.shared;
    shift.onTap = ^{
        [controller toggle];
    };
    __weak TKKeyButton *weakShift = shift;
    __weak UIView *weakDot = dot;
    void (^refresh)(void) = ^{
        TKKeyButton *button = weakShift;
        UIView *badge = weakDot;
        BOOL active = controller.isActive;
        button.backgroundColor = active ? UIColor.systemBlueColor : UIColor.tertiarySystemFillColor;
        button.tintColor = active ? UIColor.whiteColor : UIColor.labelColor;
        badge.hidden = !controller.isLocked;
    };
    refresh();
    // 单例持有回调；用弱引用让它随按键一起释放。
    controller.onChange = refresh;
    return shift;
}

#pragma mark - 注入 iGhostVT 自带键栏
//
// 自带键栏是 libghostty 的 TerminalInputAccessoryView：模糊视图里套横向
// UIScrollView，滚动区里是与栏同高的横向 UIStackView。把按键加进那个
// stack 即可，栏高度不变。栏已经自带方向键、Esc、Tab、Ctrl/Alt/Cmd，
// 这里只补 Shift、NL 和 F1–F12。

static char TKInjectedKey;

static UIStackView *TKAccessoryStackView(UIView *view) {
    if ([view isKindOfClass:UIStackView.class]) {
        UIStackView *stack = (UIStackView *)view;
        if (stack.axis == UILayoutConstraintAxisHorizontal &&
            [stack.superview isKindOfClass:UIScrollView.class]) {
            return stack;
        }
    }
    for (UIView *subview in view.subviews) {
        UIStackView *found = TKAccessoryStackView(subview);
        if (found) {
            return found;
        }
    }
    return nil;
}

static BOOL TKStackHasInjectedKeys(UIStackView *stack) {
    for (UIView *view in stack.arrangedSubviews) {
        if (objc_getAssociatedObject(view, &TKInjectedKey)) {
            return YES;
        }
    }
    return NO;
}

static void TKInjectIntoAccessory(UIView *accessory, NSString *reason) {
    if (!accessory) {
        return;
    }
    UIStackView *stack = TKAccessoryStackView(accessory);
    if (!stack) {
        TKDiag(@"inject %@: no stack in %@", reason, NSStringFromClass(accessory.class));
        return;
    }
    if (TKStackHasInjectedKeys(stack)) {
        return;
    }

    TKKeyButton *shift = TKMakeShiftButton(38.0);
    objc_setAssociatedObject(shift, &TKInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [stack insertArrangedSubview:shift atIndex:0];

    TKKeyButton *newline = TKMakeButton(@"NL", 40.0, TKKeyFont());
    newline.accessibilityLabel = @"NL";
    newline.onTap = ^{
        TKSendNewline();
    };
    objc_setAssociatedObject(newline, &TKInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [stack insertArrangedSubview:newline atIndex:1];

    for (NSInteger number = 1; number <= 12; number++) {
        TKKeyButton *button = TKMakeButton([NSString stringWithFormat:@"F%ld", (long)number], 40.0,
                                           TKKeyFont());
        button.onTap = ^{
            TKSendFunctionKey(number);
        };
        objc_setAssociatedObject(button, &TKInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stack addArrangedSubview:button];
    }

    TKDiag(@"inject %@: %@ now %lu keys, h=%.1f", reason, NSStringFromClass(accessory.class),
           (unsigned long)stack.arrangedSubviews.count, CGRectGetHeight(accessory.bounds));
}

typedef UIView *(*TKInputAccessoryGetter)(id, SEL);
static TKInputAccessoryGetter TKOriginalInputAccessoryGetter;

static UIView *TKInputAccessoryViewPassthrough(id self, SEL command) {
    UIView *original = TKOriginalInputAccessoryGetter
        ? TKOriginalInputAccessoryGetter(self, command)
        : nil;
    // 原样返回，键盘高度与官方版一致；按键只是加进它自己的滚动栏。
    TKInjectIntoAccessory(original, @"inputAccessoryView");
    return original;
}

// libghostty 在键位设置变化时会重建栏内按键（rebuildContent 清空 stack），
// 重建后再补一次。
typedef void (*TKRebuildContentFn)(id, SEL);
static TKRebuildContentFn TKOriginalRebuildContent;

static void TKAccessoryRebuildContent(id self, SEL command) {
    if (TKOriginalRebuildContent) {
        TKOriginalRebuildContent(self, command);
    }
    TKInjectIntoAccessory((UIView *)self, @"rebuildContent");
}

static BOOL TKInstallIGhostHooks(void) {
    Class terminalClass = TKTerminalClass();
    if (!terminalClass) {
        TKDiag(@"hook: terminal class missing");
        return NO;
    }
    Method accessoryMethod = class_getInstanceMethod(terminalClass, @selector(inputAccessoryView));
    if (!accessoryMethod) {
        TKDiag(@"hook: inputAccessoryView missing");
        return NO;
    }
    TKOriginalInputAccessoryGetter = (TKInputAccessoryGetter)method_getImplementation(accessoryMethod);
    method_setImplementation(accessoryMethod, (IMP)TKInputAccessoryViewPassthrough);

    Class accessoryClass = NSClassFromString(@"GhosttyTerminal.TerminalInputAccessoryView");
    Method rebuildMethod = accessoryClass
        ? class_getInstanceMethod(accessoryClass, NSSelectorFromString(@"rebuildContent"))
        : NULL;
    if (rebuildMethod) {
        TKOriginalRebuildContent = (TKRebuildContentFn)method_getImplementation(rebuildMethod);
        method_setImplementation(rebuildMethod, (IMP)TKAccessoryRebuildContent);
    }
    TKDiag(@"hooks: terminal=%@ accessory=%@ rebuild=%d", NSStringFromClass(terminalClass),
           NSStringFromClass(accessoryClass), rebuildMethod != NULL);
    return YES;
}

#pragma mark - 其他终端 App：浮动键栏

@interface TKBarView : UIView
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

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.layer.cornerRadius = 14.0;
    backdrop.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    backdrop.clipsToBounds = YES;
    [self addSubview:backdrop];

    UIScrollView *topScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    topScroll.translatesAutoresizingMaskIntoConstraints = NO;
    topScroll.showsHorizontalScrollIndicator = NO;
    topScroll.scrollEnabled = NO;
    topScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:topScroll];

    UIStackView *topStack = [[UIStackView alloc] init];
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    topStack.axis = UILayoutConstraintAxisHorizontal;
    topStack.alignment = UIStackViewAlignmentCenter;
    topStack.spacing = TKButtonSpacing;
    [topScroll addSubview:topStack];

    UIScrollView *functionScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    functionScroll.translatesAutoresizingMaskIntoConstraints = NO;
    functionScroll.showsHorizontalScrollIndicator = NO;
    functionScroll.alwaysBounceHorizontal = YES;
    functionScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:functionScroll];

    UIStackView *functionStack = [[UIStackView alloc] init];
    functionStack.translatesAutoresizingMaskIntoConstraints = NO;
    functionStack.axis = UILayoutConstraintAxisHorizontal;
    functionStack.alignment = UIStackViewAlignmentCenter;
    functionStack.spacing = TKButtonSpacing;
    [functionScroll addSubview:functionStack];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [topScroll.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [topScroll.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [topScroll.topAnchor constraintEqualToAnchor:backdrop.contentView.topAnchor],
        [topScroll.heightAnchor constraintEqualToConstant:TKRowHeight],

        [topStack.leadingAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.leadingAnchor
                                               constant:8.0],
        [topStack.trailingAnchor constraintEqualToAnchor:topScroll.frameLayoutGuide.trailingAnchor
                                                constant:-8.0],
        [topStack.topAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.topAnchor],
        [topStack.bottomAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.bottomAnchor],
        [topStack.heightAnchor constraintEqualToAnchor:topScroll.frameLayoutGuide.heightAnchor],

        [functionScroll.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [functionScroll.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [functionScroll.topAnchor constraintEqualToAnchor:topScroll.bottomAnchor constant:4.0],
        [functionScroll.heightAnchor constraintEqualToConstant:TKRowHeight],
        [functionScroll.bottomAnchor constraintEqualToAnchor:backdrop.contentView.bottomAnchor
                                                    constant:-4.0],

        [functionStack.leadingAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.leadingAnchor
                                                    constant:8.0],
        [functionStack.trailingAnchor
            constraintEqualToAnchor:functionScroll.contentLayoutGuide.trailingAnchor
                           constant:-8.0],
        [functionStack.topAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.topAnchor],
        [functionStack.bottomAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.bottomAnchor],
        [functionStack.heightAnchor constraintEqualToAnchor:functionScroll.frameLayoutGuide.heightAnchor],
    ]];

    [topStack addArrangedSubview:TKMakeShiftButton(44.0)];

    TKKeyButton *newline = TKMakeButton(@"NL", 42.0, TKKeyFont());
    newline.accessibilityLabel = @"NL";
    newline.onTap = ^{
        TKSendNewline();
    };
    [topStack addArrangedSubview:newline];

    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [topStack addArrangedSubview:spacer];

    static NSString *const arrowTitles[] = {@"←", @"↑", @"↓", @"→"};
    static const unichar arrowFinals[] = {'D', 'A', 'B', 'C'};
    for (NSInteger index = 0; index < 4; index++) {
        unichar final = arrowFinals[index];
        TKKeyButton *arrow = TKMakeButton(arrowTitles[index], 38.0, TKArrowFont());
        arrow.onTap = ^{
            TKSendArrow(final);
        };
        arrow.onRepeat = arrow.onTap;
        [arrow tk_enableRepeat];
        [topStack addArrangedSubview:arrow];
    }

    for (NSInteger number = 1; number <= 12; number++) {
        TKKeyButton *button =
            TKMakeButton([NSString stringWithFormat:@"F%ld", (long)number], 40.0, TKKeyFont());
        button.onTap = ^{
            TKSendFunctionKey(number);
        };
        [functionStack addArrangedSubview:button];
    }

    return self;
}

@end

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
    for (NSString *name in @[UIKeyboardWillChangeFrameNotification, UIKeyboardDidChangeFrameNotification]) {
        [center addObserver:self selector:@selector(keyboardWillChangeFrame:) name:name object:nil];
    }
    [center addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    return self;
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration =
        [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve =
        (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

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
        self.bar.hidden = NO;
        [UIView animateWithDuration:(duration > 0 ? duration : 0.22)
                              delay:0
                            options:(UIViewAnimationOptions)(curve << 16)
                         animations:^{
                             self.bar.frame =
                                 CGRectMake(0, barY, CGRectGetWidth(window.bounds), TKBarHeight);
                         }
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

#pragma mark - 入口

__attribute__((constructor))
static void TermKeysInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        TKDiag(@"init %@ terminal=%@ sendKey=%p", bundleID, NSStringFromClass(TKTerminalClass()),
               (void *)TKSwiftSendKeyFunction());
        if ([bundleID isEqualToString:@"wiki.qaq.iGhostVT"] && TKInstallIGhostHooks()) {
            return;
        }
        (void)[TKKeyboardBarController shared];
    });
}
