//
//  TermKeysTweak.m — 给终端类 App 增补 Shift、NL 和 F1–F12。
//
//  系统键盘没有 Shift 和 F 键，键盘扩展也无法向宿主传递硬件修饰键状态。
//  所以插件自己画一条键栏，按键不走文本插入，而是调用终端自己的按键入口
//  （取不到入口时退回 xterm 序列）。插件由 TrollFools 或 MobileSubstrate
//  注入宿主进程。
//
//  键栏是浮层：两行，贴在键盘上方，不并入宿主的 inputAccessoryView。
//  附件栏一旦变高，键盘总高度随之变化，而 iOS 15 的键盘避让会把整窗内容
//  上顶，终端首行被推到状态栏下面。浮层不改键盘高度；终端需要让出的空间由
//  根视图的 additionalSafeAreaInsets 声明，只在键盘事件里设一次，不在任何
//  布局回调里改 frame。
//
//  宿主自带的附件栏保持原样，只在其上挂一个手势，让 Shift 也能修饰它自己的
//  按键（见「让 Shift 也能修饰 App 自带栏的按键」）。
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
static const CGFloat TKButtonSize = 34.0;
static const CGFloat TKButtonSpacing = 7.0;

// 键栏高度随 F 行展开状态变化：收起时只剩下面那一行。
static CGFloat TKBarHeight(BOOL functionRowExpanded) {
    return TKBarPadding * 2 + TKRowHeight +
           (functionRowExpanded ? TKRowGap + TKRowHeight : 0.0);
}

#pragma mark - 诊断日志

static NSString *const TKDiagKey = @"TermKeys.diag";

// 诊断默认关闭：日志只服务于排查，日常运行不该在宿主容器的 Documents 里
// 留文件。需要时用
//   defaults write <bundle-id> TermKeys.diag -bool YES
// 打开，排查完再关掉并删除日志。
static BOOL TKDiagEnabled(void) {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:TKDiagKey];
    return value ? value.boolValue : NO;
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
// `UITerminalView.sendKey(_:modifiers:)` 的 `key` 参数是 Swift 枚举
// `TerminalKey`，不是 HID 用法码，所以要传该枚举的 case 序号。下面的值
// 对应 libghostty-spm `TerminalKey.swift` 的声明顺序；上游增删 case 时
// 这些数字会失准，症状是按键变成别的键、F 键被拆成 ESC。
//
// 这是 Swift 方法，调用约定与 C 不同：self 在 x20，key 在 w0，modifiers
// 在 w1。直接按 C 参数调用会走错寄存器，所以下面用一段裸汇编转发。

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

// 键栏的尺寸规则：按钮一律等宽等高，图标一律落在同样大小的正方形里。
// 这两条必须成对成立——按钮宽度不一致，整排圆圈起点就错位；只统一字号
// 而不统一墨迹尺寸，粗的符号看着比细的大一圈。
static const CGFloat TKKeyWidth = 40.0;
static const CGFloat TKGlyphSize = 15.0;

// Shift 用文字键面，五个字符在 TKKeyWidth 里排不下，单独放宽。整个键栏只有
// 这一个例外，其余按键仍按 TKKeyWidth 对齐。
static const CGFloat TKShiftKeyWidth = 56.0;

// SF Symbol 各自带有不同的边界框：`arrow.up` 窄而高，`arrow.left` 宽而扁。
// 按同一字号渲染出来墨迹差别明显，所以这里先取图、再按长边
// 等比缩放，让每个图标的外接尺寸都等于 TKGlyphSize。短边保持原比例，
// 箭头不会被拉变形。
static UIImage *TKSymbolImage(NSString *name) {
    UIImageConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:TKGlyphSize * 1.4
                            weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:configuration];
    if (!image) {
        return nil;
    }
    CGSize source = image.size;
    if (source.width <= 0 || source.height <= 0) {
        return image;
    }
    CGFloat scale = TKGlyphSize / MAX(source.width, source.height);
    CGSize target = CGSizeMake(source.width * scale, source.height * scale);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = 0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
    return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIFont *TKKeyFont(void) {
    return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
}

static UIFont *TKArrowFont(void) {
    return [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
}

// Shift 键面比别的键多几个字符，靠加宽键位容纳，字号与其它文字键保持一致。
static UIFont *TKShiftFont(void) {
    return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
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

// 键面用文字而不是 ⇧ 图标：iOS 的 shift 符号和 Caps Lock 几乎一样，键栏上
// 又没有大写键可对照，很容易被读成「大写锁定」。直接写 Shift 没有歧义。
//
// "Shift" 五个字符在 40pt 圆钮里排不下（等宽 12pt 时约需 36pt 文本宽，
// 圆钮内可用不到 30pt），所以这个键比别的宽一档，而不是缩字号——缩到
// 放得下会比相邻按键明显小一圈。
static TKKeyButton *TKMakeShiftButton(CGFloat width) {
    TKKeyButton *shift = TKMakeButton(@"Shift", MAX(width, TKShiftKeyWidth), TKShiftFont());
    shift.accessibilityLabel = @"Shift";
    shift.accessibilityHint = @"单击一次生效，双击锁定";

    // 锁定徽标：锁定时出现在右上角的小白点。尺寸随图标走——图标只有
    // 15pt 时，过大的点会盖住键面。
    UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.userInteractionEnabled = NO;
    dot.backgroundColor = UIColor.whiteColor;
    dot.layer.cornerRadius = 2.0;
    dot.hidden = YES;
    [shift addSubview:dot];
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:4.0],
        [dot.heightAnchor constraintEqualToConstant:4.0],
        [dot.trailingAnchor constraintEqualToAnchor:shift.trailingAnchor constant:-7.0],
        [dot.topAnchor constraintEqualToAnchor:shift.topAnchor constant:7.0],
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
        // 三态要一眼分得开：灰底深字 → 浅蓝底蓝字 → 实心蓝底白字 + 白点。
        // tintColor 只对图片生效，文字键面必须改标题色。
        TKShiftState state = controller.state;
        BOOL active = state != TKShiftStateInactive;
        BOOL locked = state == TKShiftStateLocked;
        button.backgroundColor =
            locked ? UIColor.systemBlueColor
                   : (active ? [UIColor.systemBlueColor colorWithAlphaComponent:0.18]
                             : UIColor.tertiarySystemFillColor);
        [button setTitleColor:(locked ? UIColor.whiteColor
                             : (active ? UIColor.systemBlueColor : UIColor.labelColor))
                     forState:UIControlStateNormal];
        badge.hidden = !locked;
    };
    refresh();
    // 单例持有回调；用弱引用让它随按键一起释放。
    controller.onChange = refresh;
    return shift;
}

#pragma mark - 键栏

@interface TKBarView : UIView
/// F 行是否展开。收起时键栏只剩一行，高度由 TKBarHeight() 给出。
@property(nonatomic, assign, getter=isFunctionRowExpanded) BOOL functionRowExpanded;
/// 展开状态变化后回调。键栏不改自己的 frame，交给 controller 重算。
@property(nonatomic, copy) void (^onFunctionRowToggle)(BOOL expanded);
- (instancetype)initWithFrame:(CGRect)frame expanded:(BOOL)expanded;
@end

@interface TKBarView ()
@property(nonatomic, strong) UIScrollView *functionScroll;
@property(nonatomic, strong) UIStackView *functionStack;
@property(nonatomic, strong) NSLayoutConstraint *functionRowHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rowGapConstraint;
@property(nonatomic, strong) TKKeyButton *functionToggleButton;
- (void)applyFunctionRowStateAnimated:(BOOL)animated notify:(BOOL)notify;
@end

@implementation TKBarView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame expanded:YES];
}

- (instancetype)initWithFrame:(CGRect)frame expanded:(BOOL)expanded {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    _functionRowExpanded = expanded;

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

    // 下面这行：Shift、NL 靠左，F 折叠键居中，方向键靠右。布局固定，但照样
    // 允许横向拖动——内容宽度等于可视宽度，所以拖到头会回弹，不会有内容
    // 滚出屏幕。这是手感，不是滚动。
    UIScrollView *topScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    topScroll.translatesAutoresizingMaskIntoConstraints = NO;
    topScroll.showsHorizontalScrollIndicator = NO;
    topScroll.alwaysBounceHorizontal = YES;
    topScroll.bounces = YES;
    topScroll.scrollEnabled = YES;
    topScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [backdrop.contentView addSubview:topScroll];

    UIStackView *topStack = [[UIStackView alloc] init];
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    topStack.axis = UILayoutConstraintAxisHorizontal;
    topStack.alignment = UIStackViewAlignmentCenter;
    topStack.spacing = TKButtonSpacing;
    [topScroll addSubview:topStack];

    // 上面这行：只有 F1–F12，默认展开，由下面那行中间的键收起。放不下
    // 一屏，可以真正横向滚动。
    UIScrollView *functionScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    functionScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.functionScroll = functionScroll;
    functionScroll.showsHorizontalScrollIndicator = NO;
    functionScroll.alwaysBounceHorizontal = YES;
    functionScroll.bounces = YES;
    functionScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    // 收起时高度会缩到 0，而里面的按键有固定高度、无法跟着缩。裁掉溢出
    // 的部分，否则按钮会画到行外、叠到下面那行上。
    functionScroll.clipsToBounds = YES;
    [backdrop.contentView addSubview:functionScroll];

    UIStackView *functionStack = [[UIStackView alloc] init];
    functionStack.translatesAutoresizingMaskIntoConstraints = NO;
    functionStack.axis = UILayoutConstraintAxisHorizontal;
    functionStack.alignment = UIStackViewAlignmentCenter;
    functionStack.spacing = TKButtonSpacing;
    self.functionStack = functionStack;
    [functionScroll addSubview:functionStack];

    self.functionRowHeightConstraint =
        [functionScroll.heightAnchor constraintEqualToConstant:expanded ? TKRowHeight : 0.0];
    self.rowGapConstraint = [topScroll.topAnchor constraintEqualToAnchor:functionScroll.bottomAnchor
                                                               constant:expanded ? TKRowGap : 0.0];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // F 行在上，主行在下。行高与行距都可变，收起时一起归零，键栏才会
        // 真正变矮而不是留一块空白。宽度固定，高度由 constraint 控制。
        //
        // F 行的底边锚在主行上方，顶边随高度自由——收起时行高变成 0，
        // 消失的是顶边那一侧，内容跟着往上收。若反过来锚顶边，收缩时底边
        // 上移会把 F 行推进主行，看起来像两层叠在一起。
        [functionScroll.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [functionScroll.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        [functionScroll.topAnchor constraintEqualToAnchor:backdrop.contentView.topAnchor
                                                 constant:TKBarPadding],
        self.functionRowHeightConstraint,

        [topScroll.leadingAnchor constraintEqualToAnchor:backdrop.contentView.leadingAnchor],
        [topScroll.trailingAnchor constraintEqualToAnchor:backdrop.contentView.trailingAnchor],
        self.rowGapConstraint,
        [topScroll.heightAnchor constraintEqualToConstant:TKRowHeight],

        // 栈的整体必须作为内容一起移动：两边都锚内容区，宽度显式等于
        // 可视宽度。若把右边锚到 frame 上，右侧方向键会被固定在屏幕上，
        // 拖动时只有左边几个键跟着动。
        [topStack.leadingAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.leadingAnchor
                                               constant:8.0],
        [topStack.trailingAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.trailingAnchor
                                                constant:-8.0],
        [topStack.widthAnchor constraintEqualToAnchor:topScroll.frameLayoutGuide.widthAnchor
                                             constant:-16.0],
        [topStack.topAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.topAnchor],
        [topStack.bottomAnchor constraintEqualToAnchor:topScroll.contentLayoutGuide.bottomAnchor],
        [topStack.heightAnchor constraintEqualToAnchor:topScroll.frameLayoutGuide.heightAnchor],

        [functionStack.leadingAnchor constraintEqualToAnchor:functionScroll.contentLayoutGuide.leadingAnchor
                                                    constant:8.0],
        [functionStack.trailingAnchor
            constraintEqualToAnchor:functionScroll.contentLayoutGuide.trailingAnchor
                           constant:-8.0],
        // 内容区高度固定在按键高度：滚动视图要知道内容多高才能横向滚动。
        [functionScroll.contentLayoutGuide.heightAnchor constraintEqualToConstant:TKButtonSize],
        // 内容锚在底部而不是居中：收起时行高从 40 缩到 0，锚底的内容会留在
        // 原处、由容器从上方裁掉（抽屉效果）；若居中，内容会跟着行高一起
        // 往上走，行高越小越贴近上一行，看起来就是两层叠在一起。
        [functionStack.bottomAnchor
            constraintEqualToAnchor:functionScroll.contentLayoutGuide.bottomAnchor],
        [functionStack.heightAnchor constraintEqualToConstant:TKButtonSize],
    ]];

    [topStack addArrangedSubview:TKMakeShiftButton(TKKeyWidth)];

    TKKeyButton *newline = TKMakeButton(@"NL", TKKeyWidth, TKKeyFont());
    newline.accessibilityLabel = @"NL";
    newline.onTap = ^{
        TKSendNewline();
    };
    [topStack addArrangedSubview:newline];

    UIView *leftSpacer = [[UIView alloc] initWithFrame:CGRectZero];
    [leftSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                                 forAxis:UILayoutConstraintAxisHorizontal];
    [leftSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                               forAxis:UILayoutConstraintAxisHorizontal];
    [topStack addArrangedSubview:leftSpacer];

    // F 折叠键放在原来那片空白里：点一下收起上面一行 F 键，再点一下展开。
    // 展开时键面用与 Shift armed 同一档浅蓝，跟其它键区分开。
    TKKeyButton *functionToggle = TKMakeButton(@"F", TKKeyWidth, TKKeyFont());
    functionToggle.accessibilityLabel = @"功能键";
    functionToggle.accessibilityHint = @"点按展开或收起 F1–F12";
    __weak TKBarView *weakBar = self;
    functionToggle.onTap = ^{
        TKBarView *bar = weakBar;
        if (!bar) {
            return;
        }
        bar.functionRowExpanded = !bar.isFunctionRowExpanded;
    };
    [topStack addArrangedSubview:functionToggle];
    self.functionToggleButton = functionToggle;

    UIView *rightSpacer = [[UIView alloc] initWithFrame:CGRectZero];
    [rightSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                                  forAxis:UILayoutConstraintAxisHorizontal];
    [rightSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    [topStack addArrangedSubview:rightSpacer];

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

    [self applyFunctionRowStateAnimated:NO notify:NO];
    return self;
}

- (void)setFunctionRowExpanded:(BOOL)expanded {
    if (_functionRowExpanded == expanded) {
        return;
    }
    _functionRowExpanded = expanded;
    [self applyFunctionRowStateAnimated:YES notify:YES];
}

// 只改内部约束：键栏自己的 frame 由 controller 按 TKBarHeight() 重算，
// 这里不碰，避免两边各算一次高度。
//
// notify 与 animated 分开：构造期间要把约束摆成初始状态，但那时 controller
// 还没准备好，也不该有人来改 frame。
//
// 收起/展开的动画要素：
//   · 只动行高与行距，内容锚在行底部（见上方约束说明），收起时自然被容器
//     从上方裁掉，不需要额外的淡出或位移。
//   · 只对 F 行那一层 layoutIfNeeded，不要对整棵子树：整棵会把 12 个 F 键
//     连同按钮一起重排，动画期间它们被压扁。
//   · hidden 不可动画，收起等动画结束再补，让它彻底退出命中测试。
- (void)applyFunctionRowStateAnimated:(BOOL)animated notify:(BOOL)notify {
    BOOL expanded = self.isFunctionRowExpanded;
    // 展开时先取消隐藏，否则看不到内容。
    if (expanded) {
        self.functionScroll.hidden = NO;
    }
    void (^changes)(void) = ^{
        self.functionRowHeightConstraint.constant = expanded ? TKRowHeight : 0.0;
        self.rowGapConstraint.constant = expanded ? TKRowGap : 0.0;
        self.functionToggleButton.backgroundColor =
            expanded ? [UIColor.systemBlueColor colorWithAlphaComponent:0.18]
                     : UIColor.tertiarySystemFillColor;
        [self.functionToggleButton setTitleColor:(expanded ? UIColor.systemBlueColor
                                                          : UIColor.labelColor)
                                        forState:UIControlStateNormal];
        // 只让 F 行所在的那一层完成布局。构造期还没进窗口，跳过。
        if (self.window) {
            [self.functionScroll.superview layoutIfNeeded];
        }
        // 回调放在动画块内：controller 在这里改键栏 frame 与终端安全区，
        // 才会和上面这些约束变化落在同一个事务里。
        if (notify && self.onFunctionRowToggle) {
            self.onFunctionRowToggle(expanded);
        }
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (!expanded) {
            self.functionScroll.hidden = YES;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

@end

#pragma mark - 让 Shift 也能修饰 App 自带栏的按键
//
// 宿主自带的附件栏有自己的粘滞修饰键，但只支持 Ctrl/Alt/Cmd——libghostty
// 的 `Modifier` 枚举里没有 Shift。栏上的 Tab/Esc/方向键读的是那套状态机，
// 与插件的 Shift 互不相干，所以 Shift 亮着时按 Tab 只会发出普通 Tab，Shift
// 也不会熄灭。
//
// 唯一能介入的位置是触摸：Shift 亮着、落点又正好是这几个键时，由插件改发
// 带 Shift 的原生按键，并让原生按钮收不到这次点按。
//
// 三个约束决定了实现方式：
//   · 不能一按下就认领触摸，否则横向滑动也被吞掉——要等手抬起、确认是
//     点按，才认。
//   · 手指一旦移动超过阈值，立即判为滑动并失败，把这串触摸还给滚动视图。
//   · 按钮的 touchUpInside 默认先于手势触发，所以打开
//     delaysTouchesEnded，让按钮的动作晚一步，才有机会被 cancelsTouchesInView
//     取消。

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
    // 原样返回，只顺手挂上 Shift 手势。不改返回值是刻意的：栏的高度、布局
    // 与官方版完全一致，键盘总高度才不会被插件改变。
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
/// F 行展开状态。键栏换窗口重建时沿用上一次的选择。
@property(nonatomic, assign) BOOL functionRowExpanded;
/// 最近一次键盘上沿在窗口坐标里的 y，收起/展开时用它重排键栏 frame。
@property(nonatomic, assign) CGFloat keyboardTopY;
/// 上一次写入安全区的根控制器。换根时基线要重新取，否则新根永远拿不到
/// 键栏高度。
@property(nonatomic, weak) UIViewController *reservedController;
/// 该根控制器原有的底部安全区，写入时作为基准加在键栏高度之前。
@property(nonatomic, assign) CGFloat baselineBottomInset;
/// 当前已经写进去的高度，用于避免重复写入。
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
    _functionRowExpanded = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[UIKeyboardWillChangeFrameNotification, UIKeyboardDidChangeFrameNotification]) {
        [center addObserver:self selector:@selector(keyboardWillChangeFrame:) name:name object:nil];
    }
    [center addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    return self;
}

// 判断键盘是否真的在屏幕上。UIKit 收起键盘时不会缩小 frame，只是把整块挪
// 到屏幕下方，所以单看高度会误判成「还在」。这里量的是它与窗口的实际
// 交集：收起时为 0；硬件键盘只弹附件栏时不到 100pt，也不算软件键盘。
- (BOOL)keyboardIsOnScreenInWindow:(UIWindow *)window frame:(CGRect)frame {
    if (CGRectIsEmpty(frame)) {
        return NO;
    }
    CGRect inWindow = [window convertRect:frame fromWindow:nil];
    return CGRectIntersection(inWindow, window.bounds).size.height > 100.0;
}

// 让终端为键栏腾出底部空间。用根视图的 additionalSafeAreaInsets 而不是改
// 任何视图的 frame：后者会在布局过程中再次触发布局，形成死循环。同一值只
// 写一次，键盘反复回调也不会抖动。
//
// 写入的高度 = 该根控制器原有的底部安全区 + 键栏高度。把原有值算进去，
// 宿主自己声明的底部安全区才不会被挤掉。换根控制器时重新读基线。
- (void)updateReservationForWindow:(UIWindow *)window visible:(BOOL)visible {
    UIViewController *root = window.rootViewController;
    if (!root) {
        return;
    }
    CGFloat wanted = visible ? TKBarHeight(self.functionRowExpanded) : 0;
    BOOL newRoot = self.reservedController != root;
    if (!newRoot && fabs(self.reservedHeight - wanted) < 0.5) {
        return;
    }
    if (newRoot) {
        // 新根的当前底部安全区就是基线。
        self.reservedController = root;
        self.baselineBottomInset = root.additionalSafeAreaInsets.bottom;
    }
    self.reservedHeight = wanted;
    UIEdgeInsets insets = root.additionalSafeAreaInsets;
    insets.bottom = self.baselineBottomInset + wanted;
    root.additionalSafeAreaInsets = insets;
    TKDiag(@"reserve %.1f (base %.1f)", wanted, self.baselineBottomInset);
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
            self.bar = [[TKBarView alloc] initWithFrame:CGRectZero
                                               expanded:self.functionRowExpanded];
            __weak TKKeyboardBarController *weakSelf = self;
            self.bar.onFunctionRowToggle = ^(BOOL expanded) {
                [weakSelf handleFunctionRowToggle:expanded];
            };
            [window addSubview:self.bar];
            self.hostWindow = window;
        }

        // 键盘 frame 已包含宿主自带的附件栏，所以键栏直接叠在它上沿。
        CGRect keyboardInWindow = [window convertRect:endFrame fromWindow:nil];
        CGFloat keyboardTop = CGRectGetMinY(keyboardInWindow);
        CGFloat barHeight = TKBarHeight(self.functionRowExpanded);
        self.keyboardTopY = keyboardTop;
        BOOL visible = [self keyboardIsOnScreenInWindow:window frame:endFrame];
        self.bar.hidden = !visible;
        [UIView animateWithDuration:(duration > 0 ? duration : 0.22)
                              delay:0
                            options:(UIViewAnimationOptions)(curve << 16)
                         animations:^{
                             self.bar.frame = CGRectMake(0, keyboardTop - barHeight,
                                                         CGRectGetWidth(window.bounds), barHeight);
                         }
                         completion:nil];
        [window bringSubviewToFront:self.bar];

        [self updateReservationForWindow:window visible:visible];
    });
}

// 收起/展开只改键栏自己的高度：底边仍贴着键盘上沿，所以上边上下移动。
// 高度变了，安全区预留也得跟着改，否则终端底部会多让或少让一行。
//
// 这个回调由键栏在它的动画块内部调用，所以这里直接改 frame 和 inset 就会
// 落进同一个动画事务——键栏高度与终端底部同步变化。若在这里再包一层
// UIView animate，会另起事务，两边各走各的曲线，看起来就是错开动。
- (void)handleFunctionRowToggle:(BOOL)expanded {
    self.functionRowExpanded = expanded;
    TKBarView *bar = self.bar;
    UIWindow *window = self.hostWindow;
    if (!bar || !window) {
        return;
    }
    CGFloat height = TKBarHeight(expanded);
    CGRect frame = bar.frame;
    frame.size.height = height;
    frame.origin.y = self.keyboardTopY - height;
    bar.frame = frame;
    [self updateReservationForWindow:window visible:!bar.hidden];
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
        if (![bundleID isEqualToString:@"wiki.qaq.iGhostVT"]) {
            TKDiag(@"skip %@: not iGhostVT", bundleID);
            return;
        }
        TKDiag(@"init %@ terminal=%@ sendKey=%p", bundleID, NSStringFromClass(TKTerminalClass()),
               (void *)TKSwiftSendKeyFunction());
        // iGhostVT 自带附件栏：保留它，只挂 Shift 手势。键栏仍由下面的
        // 统一逻辑负责浮在键盘上。
        TKInstallIGhostHooks();
        (void)[TKKeyboardBarController shared];
    });
}
