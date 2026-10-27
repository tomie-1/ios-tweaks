//
//  TermKeysTweak.m — 给终端类 App 增补 Shift、NL 和 F1–F12。
//
//  系统键盘扩展无法传递硬件修饰键状态，所以这里把按键交给终端自己的按键
//  入口（拿不到时退回 xterm 序列）。插件由 TrollFools 或 MobileSubstrate
//  注入宿主进程。
//
//  布局：一条两行键栏浮在系统键盘（含 App 自带的那条附件栏）之上。键栏
//  **不并入 inputAccessoryView**——键盘高度只要比原生多出一点，iOS 15 的
//  键盘避让就会把整窗内容上顶，终端首行钻到状态栏下面，那是之前一直修不好
//  的根因。改由根视图 additionalSafeAreaInsets 让终端腾出键栏高度：一次
//  按键事件设一次，不在任何 layout 回调里改 frame，也就不会重排死循环。
//
//  App 自带的附件栏一个按键都不改，只挂一层「只接管点按」的 Shift 拦截。
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
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const CGFloat TKRowHeight = 40.0;
static const CGFloat TKRowGap = 4.0;
static const CGFloat TKBarPadding = 4.0;
static const CGFloat TKBarHeight = TKRowHeight * 2 + TKRowGap + TKBarPadding * 2;
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
// UITerminalView 的 `sendKey(_:modifiers:)` 接的是 Swift 的 `TerminalKey`
// 枚举，不是 HID 用法码，所以要传 `TerminalKey` 的 case 序号——也就是
// libghostty-spm `TerminalKey.swift` 里 case 的声明顺序。下面的值按该文件
// 的声明顺序算出。传错的后果很隐蔽：方向键会变成别的按键，F 键更会被拆成
// ESC。
//
// 调用约定：self 在 x20，按键码在 x0，修饰键在 x1。

enum {
    TKKeyJ = 28,
    TKKeyTab = 63,
    TKKeyDown = 74,
    TKKeyLeft = 75,
    TKKeyRight = 76,
    TKKeyUp = 77,
    TKKeyEscape = 119,
    TKKeyF1 = 120, // F 键连续排列，F12 = 131
};

enum {
    TKModifierShift = 1u << 0,
    TKModifierCtrl = 1u << 1,
};

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
// 单击一次生效，0.3 秒内再点一次锁定，再点解除（与自带栏的 Ctrl/Alt/Cmd
// 同一节奏）。

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
               now - self.lastTapDate.timeIntervalSince1970 < 0.3) {
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
        case 'A': nativeKey = TKKeyUp; break;
        case 'B': nativeKey = TKKeyDown; break;
        case 'C': nativeKey = TKKeyRight; break;
        case 'D': nativeKey = TKKeyLeft; break;
        default: break;
    }
    if (nativeKey && TKTryNativeKey(nativeKey, shift ? TKModifierShift : 0u)) {
        return;
    }
    TKInsertText(shift ? [NSString stringWithFormat:@"\x1b[1;2%C", final]
                       : [NSString stringWithFormat:@"\x1b[%C", final]);
}

static void TKSendFunctionKey(NSInteger number) {
    BOOL shift = [TKShiftController.shared consume];
    uint8_t nativeKey = (uint8_t)(TKKeyF1 + number - 1);
    if (TKTryNativeKey(nativeKey, shift ? TKModifierShift : 0u)) {
        return;
    }
    TKInsertText(TKFunctionKey(number, shift));
}

// NL：终端层的换行。裸 LF 会被软件键盘路由成回车直接提交，所以走 Ctrl+J；
// 拿不到原生入口时借用 App 自带键栏的 Ctrl 键，最后才用括号粘贴兜底。
static void TKSendNewline(void) {
    if (TKTryNativeKey(TKKeyJ, TKModifierCtrl)) {
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

// 所有按键共用的尺寸规则。按钮一律等宽等高，字形一律等点高——这是从实测
// 数据定的，不是凭感觉：44/42/38/40 四种宽度会让整排的圆圈起点错位，
// 字号相同也不等于墨迹同大。
static const CGFloat TKKeyWidth = 40.0;
static const CGFloat TKGlyphHeight = 16.0;

// SF Symbol 的每个符号有自己的边界框，同一个字号下墨迹大小差很多：实测
// `shift` 是 19.0×16.7，`arrow.left` 只有 18.3×14.3，而 `arrow.up` 是
// 15.7×16.7。按字号配必然大小不一，改成按**固定点高**渲染，再让宽度按
// 各自比例走——所有图标就同高了，横向箭头只是更宽，这也是它本来的形状。
static UIImage *TKSymbolImage(NSString *name) {
    UIImageConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:TKGlyphHeight
                            weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:configuration];
    if (!image) {
        return nil;
    }
    // 统一缩放到同一高度；宽度按原比例，不做裁剪。
    CGFloat scale = TKGlyphHeight / MAX(image.size.height, 1.0);
    if (fabs(scale - 1.0) < 0.01) {
        return image;
    }
    CGSize target = CGSizeMake(image.size.width * scale, TKGlyphHeight);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = 0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
    return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
static UIImage *TKShiftImage(void) {
    UIImage *image = TKSymbolImage(@"shift");
    return image ?: TKSymbolImage(@"shift.fill");
}

static UIFont *TKKeyFont(void) {
    return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
}

static UIFont *TKArrowFont(void) {
    return [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
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

#pragma mark - 键栏

@interface TKBarView : UIView
@end

@interface TKBarView ()
- (void)tk_scheduleGlyphMetricsDump:(UIStackView *)topStack functionStack:(UIStackView *)functionStack;
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

    // 第一行固定不滚动：Shift、NL 靠左，方向键靠右。
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

    // 第二行只放 F1–F12，可横向滑动。
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
        [topScroll.topAnchor constraintEqualToAnchor:backdrop.contentView.topAnchor
                                            constant:TKBarPadding],
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
        [functionScroll.topAnchor constraintEqualToAnchor:topScroll.bottomAnchor
                                                  constant:TKRowGap],
        [functionScroll.heightAnchor constraintEqualToConstant:TKRowHeight],

        [functionStack.leadingAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.leadingAnchor
                                                    constant:8.0],
        [functionStack.trailingAnchor
            constraintEqualToAnchor:functionScroll.contentLayoutGuide.trailingAnchor
                           constant:-8.0],
        [functionStack.topAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.topAnchor],
        [functionStack.bottomAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.bottomAnchor],
        [functionStack.heightAnchor constraintEqualToAnchor:functionScroll.frameLayoutGuide.heightAnchor],
    ]];

    [topStack addArrangedSubview:TKMakeShiftButton(TKKeyWidth)];

    TKKeyButton *newline = TKMakeButton(@"NL", TKKeyWidth, TKKeyFont());
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

    static NSString *const arrowSymbols[] = {@"arrow.left", @"arrow.up", @"arrow.down", @"arrow.right"};
    static NSString *const arrowTitles[] = {@"←", @"↑", @"↓", @"→"};
    static const unichar arrowFinals[] = {'D', 'A', 'B', 'C'};
    for (NSInteger index = 0; index < 4; index++) {
        unichar final = arrowFinals[index];
        TKKeyButton *arrow = TKMakeButton(@"", TKKeyWidth, TKArrowFont());
        UIImage *symbol = TKSymbolImage(arrowSymbols[index]);
        if (symbol) {
            [arrow setImage:symbol forState:UIControlStateNormal];
        } else {
            [arrow setTitle:arrowTitles[index] forState:UIControlStateNormal];
        }
        arrow.accessibilityLabel = arrowTitles[index];
        arrow.onTap = ^{
            TKSendArrow(final);
        };
        arrow.onRepeat = arrow.onTap;
        [arrow tk_enableRepeat];
        [topStack addArrangedSubview:arrow];
    }

    for (NSInteger number = 1; number <= 12; number++) {
        TKKeyButton *button =
            TKMakeButton([NSString stringWithFormat:@"F%ld", (long)number], TKKeyWidth, TKKeyFont());
        button.onTap = ^{
            TKSendFunctionKey(number);
        };
        [functionStack addArrangedSubview:button];
    }

    [self tk_scheduleGlyphMetricsDump:topStack functionStack:functionStack];
    return self;
}

// 把每个按键的字形尺寸、圆心和基线差异写进日志，用数据核对「看起来一样大」。
// 看得出来的差异必须有数：字形高宽、按钮内偏移、两行基线。
- (void)tk_scheduleGlyphMetricsDump:(UIStackView *)topStack functionStack:(UIStackView *)functionStack {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!TKDiagEnabled()) {
            return;
        }
        NSMutableString *report = [NSMutableString stringWithString:@"glyph-metrics"];
        for (UIStackView *stack in @[ topStack, functionStack ]) {
            [report appendFormat:@"\n  row axis=h count=%lu", (unsigned long)stack.arrangedSubviews.count];
            for (UIView *view in stack.arrangedSubviews) {
                if (![view isKindOfClass:UIButton.class]) {
                    continue;
                }
                UIButton *button = (UIButton *)view;
                CGRect frameInBar = [button convertRect:button.bounds toView:self];
                NSString *label = button.accessibilityLabel ?: @"?";
                // 文字按钮：看 titleLabel；图形按钮：看 imageView。
                UIView *content = button.currentImage ? button.imageView : button.titleLabel;
                if (!content) {
                    continue;
                }
                CGSize glyph = content.isHidden ? CGSizeZero : content.bounds.size;
                if (content == button.imageView) {
                    glyph = button.currentImage.size;
                }
                CGRect contentFrame = [content convertRect:content.bounds toView:button];
                CGFloat dx = CGRectGetMidX(contentFrame) - CGRectGetMidX(button.bounds);
                CGFloat dy = CGRectGetMidY(contentFrame) - CGRectGetMidY(button.bounds);
                [report appendFormat:
                    @"\n    %@ btn=%.1fx%.1f glyph=%.1fx%.1f dx=%+.1f dy=%+.1f centerY=%.1f",
                    label,
                    CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds),
                    glyph.width, glyph.height, dx, dy,
                    CGRectGetMidY(frameInBar)];
            }
        }
        TKDiag(@"%@", report);
    });
}

@end

#pragma mark - 让 Shift 也能修饰 App 自带栏的按键
//
// libghostty 的粘滞修饰键只管 Ctrl/Alt/Cmd，它的 `Modifier` 枚举里没有
// Shift；自带栏的 Tab/Esc/方向键读的是它自己的状态机，与插件的 Shift 毫无
// 关系。所以 Shift 亮着时得在按钮把动作发出去之前截住，改由插件发带 Shift
// 的原生按键。
//
// 两处小心：一是不在 touchesBegan 就认下触摸（那会连横向滑动一起吞掉），
// 而是等手抬起、确认是点按且落在可修饰的键上才认；二是打开
// delaysTouchesEnded，让按钮的 touchUpInside 晚于本识别器一步，才有机会
// 取消它。手指移动超过阈值即判定为滑动，本识别器立刻失败，滚动照常。

static char TKShiftTapKey;

typedef NS_ENUM(NSUInteger, TKShiftTarget) {
    TKShiftTargetNone,
    TKShiftTargetTab,
    TKShiftTargetEscape,
    TKShiftTargetLeft,
    TKShiftTargetRight,
    TKShiftTargetUp,
    TKShiftTargetDown,
};

// 自带栏的标签来自 TerminalInputAccessoryItem.title。
static TKShiftTarget TKShiftTargetForLabel(NSString *label) {
    static NSDictionary<NSString *, NSNumber *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"Tab": @(TKShiftTargetTab),
            @"Escape": @(TKShiftTargetEscape),
            @"Left Arrow": @(TKShiftTargetLeft),
            @"Right Arrow": @(TKShiftTargetRight),
            @"Up Arrow": @(TKShiftTargetUp),
            @"Down Arrow": @(TKShiftTargetDown),
        };
    });
    NSNumber *value = label ? table[label] : nil;
    return value ? (TKShiftTarget)value.unsignedIntegerValue : TKShiftTargetNone;
}

static BOOL TKSendShiftedTarget(TKShiftTarget target) {
    uint8_t key = 0;
    switch (target) {
        case TKShiftTargetTab: key = TKKeyTab; break;
        case TKShiftTargetEscape: key = TKKeyEscape; break;
        case TKShiftTargetLeft: key = TKKeyLeft; break;
        case TKShiftTargetRight: key = TKKeyRight; break;
        case TKShiftTargetUp: key = TKKeyUp; break;
        case TKShiftTargetDown: key = TKKeyDown; break;
        case TKShiftTargetNone: return NO;
    }
    return TKTryNativeKey(key, TKModifierShift);
}

@interface TKShiftTapRecognizer : UIGestureRecognizer
@property(nonatomic, assign) TKShiftTarget target;
@property(nonatomic, assign) CGPoint startPoint;
@property(nonatomic, assign) BOOL tracking;
@end

@implementation TKShiftTapRecognizer

- (TKShiftTarget)targetAt:(UITouch *)touch event:(UIEvent *)event {
    UIView *hit = [self.view hitTest:[touch locationInView:self.view] withEvent:event];
    while (hit && hit != self.view) {
        if ([hit isKindOfClass:UIControl.class]) {
            return TKShiftTargetForLabel(hit.accessibilityLabel);
        }
        hit = hit.superview;
    }
    return TKShiftTargetNone;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 只在 Shift 亮着、且落点是可修饰的键时才开始跟踪；其余一律放手，
    // 滚动和别的按键都不受影响。
    UITouch *touch = touches.anyObject;
    TKShiftTarget target = TKShiftTargetNone;
    if (touch && TKShiftController.shared.isActive) {
        target = [self targetAt:touch event:event];
    }
    if (target == TKShiftTargetNone) {
        self.tracking = NO;
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    self.tracking = YES;
    self.target = target;
    self.startPoint = touch ? [touch locationInView:self.view] : CGPointZero;
    self.state = UIGestureRecognizerStatePossible;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.tracking) {
        return;
    }
    UITouch *touch = touches.anyObject;
    CGPoint point = touch ? [touch locationInView:self.view] : CGPointZero;
    // 移动了就当成滑动，把这串触摸还给 UIScrollView。
    if (hypot(point.x - self.startPoint.x, point.y - self.startPoint.y) > 10.0) {
        self.tracking = NO;
        self.target = TKShiftTargetNone;
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    TKShiftTarget target = self.target;
    BOOL armed = self.tracking && TKShiftController.shared.isActive;
    self.tracking = NO;
    self.target = TKShiftTargetNone;
    if (!armed || target == TKShiftTargetNone) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    // 认下这一下点按：cancelsTouchesInView 会把按钮的 touchUpInside 撤掉。
    self.state = UIGestureRecognizerStateEnded;
    [TKShiftController.shared consume];
    BOOL sent = TKSendShiftedTarget(target);
    TKDiag(@"shift+bar target=%lu sent=%d", (unsigned long)target, sent);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.tracking = NO;
    self.target = TKShiftTargetNone;
    self.state = UIGestureRecognizerStateFailed;
}

@end

static void TKInstallShiftPassthrough(UIView *accessory) {
    if (!accessory || objc_getAssociatedObject(accessory, &TKShiftTapKey)) {
        return;
    }
    TKShiftTapRecognizer *recognizer = [[TKShiftTapRecognizer alloc] init];
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesEnded = YES;
    recognizer.delaysTouchesBegan = NO;
    [accessory addGestureRecognizer:recognizer];
    objc_setAssociatedObject(accessory, &TKShiftTapKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

typedef UIView *(*TKInputAccessoryGetter)(id, SEL);
static TKInputAccessoryGetter TKOriginalInputAccessoryGetter;

static UIView *TKInputAccessoryViewPassthrough(id self, SEL command) {
    UIView *original = TKOriginalInputAccessoryGetter
        ? TKOriginalInputAccessoryGetter(self, command)
        : nil;
    // 原样返回：键盘高度与官方版一致，布局不因插件而变；这里只挂 Shift
    // 拦截，不改栏里的任何按键。
    TKInstallShiftPassthrough(original);
    return original;
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
    TKDiag(@"hook installed on %@", NSStringFromClass(terminalClass));
    return YES;
}

#pragma mark - 键栏控制

@interface TKKeyboardBarController : NSObject
@property(nonatomic, strong) TKBarView *bar;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic, weak) UIViewController *rootController;
@property(nonatomic, assign) CGFloat reservedHeight;
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

// 键盘真在屏幕上才显示键栏、才给终端留位置。
//
// 收起键盘时 UIKit 报的 frame 高度并不变，只是整块被挪到屏幕下方——光看
// 高度会以为键盘还在，键栏就留在屏幕上了。所以要门控「落在窗口内的高度」：
// 硬件键盘只弹附件栏时它不到 100pt，不该留空白；收起时它 ≤ 0，键栏也该走。
- (BOOL)keyboardIsOnScreenInWindow:(UIWindow *)window frame:(CGRect)frame {
    if (CGRectIsEmpty(frame)) {
        return NO;
    }
    CGRect inWindow = [window convertRect:frame fromWindow:nil];
    return CGRectIntersection(inWindow, window.bounds).size.height > 100.0;
}

// 让终端腾出键栏高度。同一个值只设一次，不在 layout 回调里反复改 frame，
// 也就不会出现之前那种重排死循环。
- (void)updateReservationForWindow:(UIWindow *)window visible:(BOOL)visible {
    UIViewController *root = window.rootViewController;
    if (!root) {
        return;
    }
    CGFloat wanted = visible ? TKBarHeight : 0;
    self.rootController = root;
    if (fabs(self.reservedHeight - wanted) < 0.5) {
        return;
    }
    self.reservedHeight = wanted;
    UIEdgeInsets insets = root.additionalSafeAreaInsets;
    insets.bottom = wanted;
    root.additionalSafeAreaInsets = insets;
    TKDiag(@"reserve %.1f", wanted);
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration =
        [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve =
        (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = TKHostWindow();
        if (!window) {
            return;
        }
        if (CGRectIsEmpty(endFrame)) {
            return;
        }
        if (!self.bar || self.hostWindow != window) {
            [self.bar removeFromSuperview];
            self.bar = [[TKBarView alloc] initWithFrame:CGRectZero];
            [window addSubview:self.bar];
            self.hostWindow = window;
        }

        // 键盘 frame 已含 App 自带附件栏，键栏就叠在它上面。
        CGRect keyboardInWindow = [window convertRect:endFrame fromWindow:nil];
        CGFloat barY = CGRectGetMinY(keyboardInWindow) - TKBarHeight;
        BOOL visible = [self keyboardIsOnScreenInWindow:window frame:endFrame];
        self.bar.hidden = !visible;
        [UIView animateWithDuration:(duration > 0 ? duration : 0.22)
                              delay:0
                            options:(UIViewAnimationOptions)(curve << 16)
                         animations:^{
                             self.bar.frame =
                                 CGRectMake(0, barY, CGRectGetWidth(window.bounds), TKBarHeight);
                         }
                         completion:nil];
        [window bringSubviewToFront:self.bar];

        [self updateReservationForWindow:window visible:visible];
    });
}

- (void)keyboardWillHide:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.bar.hidden = YES;
        UIWindow *window = TKHostWindow();
        if (window) {
            [self updateReservationForWindow:window visible:NO];
        }
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
        if ([bundleID isEqualToString:@"wiki.qaq.iGhostVT"]) {
            // 自带栏原样保留，只加 Shift 拦截；键栏另浮一层。
            TKInstallIGhostHooks();
        }
        (void)[TKKeyboardBarController shared];
    });
}
