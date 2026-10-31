//
//  SoulTweak.m  — SOUL 助手（越狱 dylib）
//  纯 Objective-C 运行时 hook，无 Substrate 依赖。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#import <objc/message.h>
#import <stdarg.h>
#import <UserNotifications/UserNotifications.h>

// 统一命名：soulfx_<功能>（不带版本后缀；改名走 SoulCfgMigrate 迁移）
static NSString * const kDiceEnabledKey     = @"soulfx_dice_enabled";
static NSString * const kRecallBlockedKey   = @"soulfx_recall_blocked";
static NSString * const kLegacyRecallBlockedKey = @"soul_fx_recall_blocked_v1";

static NSString * const kFxSnapUnlock    = @"soulfx_snap_unlock";
static NSString * const kFxSaveNoWM      = @"soulfx_save_nowm";
static NSString * const kFxShareHome     = @"soulfx_share_home";
static NSString * const kFxAntiRecall    = @"soulfx_anti_recall";
static NSString * const kFxOwnRecall     = @"soulfx_own_recall";
static NSString * const kFxMuteMatchBgm  = @"soulfx_mute_match_bgm";
static NSString * const kFxBlockInput    = @"soulfx_block_input";
static NSString * const kFxGiftFree      = @"soulfx_gift_free";
static NSString * const kFxEtiquetteFree = @"soulfx_etiquette_free";
static NSString * const kFxDebugLog      = @"soulfx_debug_log";

// —— 2026-10-08 新增批次 ——
static NSString * const kFxPickerFree    = @"soulfx_picker_free";
static NSString * const kFxNoSplashAd    = @"soulfx_no_splash_ad";
static NSString * const kFxNoTeenPopup   = @"soulfx_no_teen_popup";
static NSString * const kFxNoAds         = @"soulfx_no_ads";
static NSString * const kFxAutoVoiceText = @"soulfx_auto_voice_text";
static NSString * const kFxBlockRead     = @"soulfx_block_read";
static NSString * const kFxAutoRead      = @"soulfx_auto_read";
static NSString * const kFxNoCloseFriend = @"soulfx_no_close_friend";
static NSString * const kFxClearNotif    = @"soulfx_clear_notif";
static NSString * const kFxVoiceUnlock   = @"soulfx_voice_unlock";

#pragma mark - 插件独立目录（不写 App 自身配置）

// 插件所有数据统一放在 <App容器>/Library/Preferences/SoulFX/
//   config.plist  开关配置
//   soulfx.log    调试日志（开关打开后才写）
//   recall.plist  防撤回角标记录
//   skip.txt      调试跳过分组
static NSString *SoulFXDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/SoulFX"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}
static NSString *SoulFXPath(NSString *name) {
    return [SoulFXDir() stringByAppendingPathComponent:name];
}

static NSMutableDictionary *gSoulCfg = nil;
static NSLock *gSoulCfgLock = nil;

// 旧键名 -> 新键名（v1 时代用 soul_ / soul_fx_ 前缀 + _v1 后缀）
static NSDictionary<NSString *, NSString *> *SoulLegacyKeyMap(void) {
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{ @"soul_dice_tweak_enabled_v1": kDiceEnabledKey,
               @"soul_fx_snap_unlock_v1": kFxSnapUnlock,
               @"soul_fx_snap_multi_v1": kFxSnapUnlock,
               @"soul_fx_save_nowm_v1": kFxSaveNoWM,
               @"soul_fx_share_free_v1": kFxSaveNoWM,
               @"soul_fx_share_home_v1": kFxShareHome,
               @"soul_fx_anti_recall_v1": kFxAntiRecall,
               @"soul_fx_own_recall_v1": kFxOwnRecall,
               @"soul_fx_mute_match_bgm_v1": kFxMuteMatchBgm,
               @"soul_fx_block_input_v1": kFxBlockInput,
               @"soul_fx_block_view_v1": kFxBlockInput,
               @"soul_fx_gift_free_v1": kFxGiftFree,
               @"soul_fx_qiyu_free_v1": kFxGiftFree,
               @"soul_fx_etiquette_free_v1": kFxEtiquetteFree,
               @"soulfx_snap_multi": kFxSnapUnlock,
               @"soulfx_share_free": kFxSaveNoWM,
               @"soulfx_block_view": kFxBlockInput,
               @"soulfx_qiyu_free": kFxGiftFree,
               @"soulfx_group_recall": kFxAntiRecall,
               @"soul_fx_net_log_v1": kFxDebugLog,
               @"soulfx_net_log": kFxDebugLog,
               @"soulfx_file_log": kFxDebugLog };
    });
    return m;
}

// 启动时把旧键名统一成新键名，来源三处：现有 config.plist、App 自身 NSUserDefaults、旧 suite。
// 幂等：新键已存在就只删旧键；日期类键是字符串，按原类型保留。
static void SoulCfgMigrate(void) {
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *old = [[NSUserDefaults alloc] initWithSuiteName:@"com.soulapp.soulfx"];
    [SoulLegacyKeyMap() enumerateKeysAndObjectsUsingBlock:^(NSString *oldKey, NSString *newKey, BOOL *stop) {
        if (gSoulCfg[newKey] == nil) {
            id v = gSoulCfg[oldKey];
            if (v == nil) v = [std objectForKey:oldKey];
            if (v == nil) v = [old objectForKey:oldKey];
            if (v != nil) gSoulCfg[newKey] = [v isKindOfClass:[NSString class]] ? v : @([v boolValue]);
        }
        [gSoulCfg removeObjectForKey:oldKey];
    }];
    NSDictionary *rec = [NSDictionary dictionaryWithContentsOfFile:SoulFXPath(@"recall.plist")];
    if (rec[kRecallBlockedKey] == nil) {
        id arr = rec[kLegacyRecallBlockedKey];
        if (arr == nil) arr = [old arrayForKey:kLegacyRecallBlockedKey];
        if ([arr isKindOfClass:[NSArray class]] && [arr count]) {
            [@{kRecallBlockedKey: arr} writeToFile:SoulFXPath(@"recall.plist") atomically:YES];
        }
    }
}

static void SoulCfgLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSoulCfgLock = [NSLock new];
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:SoulFXPath(@"config.plist")];
        gSoulCfg = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
        SoulCfgMigrate();
        [gSoulCfg writeToFile:SoulFXPath(@"config.plist") atomically:YES];
    });
}
static void SoulCfgSave(void) {
    [gSoulCfg writeToFile:SoulFXPath(@"config.plist") atomically:YES];
}

#pragma mark - 日志

// 默认只写系统日志；打开「调试日志」后才落盘到 SoulFX/soulfx.log
static BOOL SoulFileLogOn(void) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    id o = gSoulCfg[kFxDebugLog];
    BOOL v = (o == nil) ? NO : [o boolValue];
    [gSoulCfgLock unlock];
    return v;
}

static void SoulLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SoulDice] %@", msg);
    if (!SoulFileLogOn()) return;
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    FILE *f = fopen(SoulFXPath(@"soulfx.log").fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

#pragma mark - 开关

static BOOL SoulDef(NSString *key) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    BOOL v = [gSoulCfg[key] boolValue];
    [gSoulCfgLock unlock];
    return v;
}
static BOOL SoulDefOn(NSString *key, BOOL defValue) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    id o = gSoulCfg[key];
    BOOL v = (o == nil) ? defValue : [o boolValue];
    [gSoulCfgLock unlock];
    return v;
}
static NSString *SoulCfgString(NSString *key) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    id o = gSoulCfg[key];
    NSString *s = [o isKindOfClass:[NSString class]] ? o : nil;
    [gSoulCfgLock unlock];
    return s;
}
static void SoulSyncLoveBellPatch(void);

static void SoulSetDef(NSString *key, BOOL on) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    gSoulCfg[key] = @(on);
    SoulCfgSave();
    [gSoulCfgLock unlock];
    SoulLog(@"toggle %@ -> %d", key, (int)on);
    if ([key isEqualToString:kFxGiftFree]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SoulSyncLoveBellPatch(); });
    }
}
static void SoulSetCfgString(NSString *key, NSString *val) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    if (val) gSoulCfg[key] = val; else [gSoulCfg removeObjectForKey:key];
    SoulCfgSave();
    [gSoulCfgLock unlock];
}
static BOOL SoulDiceOn(void) { return SoulDef(kDiceEnabledKey); }

// 面板分组：@[ @{@"title": 分组名, @"items": @[ @[标题, 键, 默认] ... ]} ... ]
static NSArray<NSDictionary *> *SoulFxSections(void) {
    return @[
        @{ @"title": @"聊天与消息", @"items": @[
            @[@"自定义骰子 / 猜拳",          kDiceEnabledKey,  @NO],
            @[@"防撤回（私聊 / 群聊）",      kFxAntiRecall,    @NO],
            @[@"超2分钟也能撤回自己消息",    kFxOwnRecall,     @YES],
            @[@"禁止上报状态（输入 / 查看主页）", kFxBlockInput, @NO],
            @[@"禁止上报「已读」回执",       kFxBlockRead,     @NO],
            @[@"收到消息自动已读",           kFxAutoRead,      @NO],
            @[@"语音消息自动转文字",         kFxAutoVoiceText, @NO],
            @[@"禁止弹「挚友」邀请",         kFxNoCloseFriend, @NO],
            @[@"去除青少年弹窗",             kFxNoTeenPopup,   @NO],
            @[@"回前台自动清除通知",         kFxClearNotif,    @NO],
        ]},
        @{ @"title": @"图片 / 视频 / 分享", @"items": @[
            @[@"阅后即焚解锁（截屏 / 多次查看）", kFxSnapUnlock, @NO],
            @[@"保存 / 分享：无水印 + 无限制", kFxSaveNoWM,    @NO],
            @[@"去除主页分享限制（隐私防护）", kFxShareHome,   @NO],
            @[@"解除图片 / 视频选择数量上限", kFxPickerFree,   @NO],
        ]},
        @{ @"title": @"限制与体验", @"items": @[
            @[@"去除送礼限制（聊天 / 奇遇铃）", kFxGiftFree,    @NO],
            @[@"去除礼仪分限制",             kFxEtiquetteFree, @NO],
            @[@"关闭匹配背景音乐",           kFxMuteMatchBgm,  @NO],
            @[@"跳过开屏 / 启动广告",        kFxNoSplashAd,    @NO],
            @[@"去除广告（信息流 / 搜索 / 评论 / 聊天）", kFxNoAds, @NO],
            @[@"语音消息解锁装扮",           kFxVoiceUnlock,   @NO],
        ]},
        @{ @"title": @"调试", @"items": @[
            @[@"调试日志（请求日志 + 落盘）", kFxDebugLog,      @NO],
        ]},
    ];
}

#pragma mark - 窗口 / 顶层控制器

static UIWindow *SoulKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static UIViewController *SoulTopViewController(void) {
    UIWindow *keyWindow = SoulKeyWindow();
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
        if ([sel isKindOfClass:[UINavigationController class]]) sel = ((UINavigationController *)sel).visibleViewController;
        if (sel) vc = sel;
    }
    return vc;
}

static UIWindow *SoulHostWindow(void) {
    UIWindow *w = SoulTopViewController().view.window;
    if (w) return w;
    return SoulKeyWindow();
}

#pragma mark - 主题（跟随 SOUL 实际深浅色）

static BOOL SoulColorIsDark(UIColor *c) {
    if (!c) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        if (a < 0.4) return NO;
        CGFloat lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        return lum < 0.5;
    }
    CGFloat w = 0;
    if ([c getWhite:&w alpha:&a]) { if (a < 0.4) return NO; return w < 0.5; }
    return NO;
}

static BOOL SoulAppDark(void) {
    UIWindow *w = SoulHostWindow();
    if (w) {
        if (w.overrideUserInterfaceStyle == UIUserInterfaceStyleDark) return YES;
        if (w.overrideUserInterfaceStyle == UIUserInterfaceStyleLight) return NO;
    }
    UIView *v = SoulTopViewController().view;
    int guard = 0;
    while (v && guard++ < 24) {
        UIColor *bg = v.backgroundColor;
        if (bg && CGColorGetAlpha(bg.CGColor) > 0.5) return SoulColorIsDark(bg);
        v = v.superview;
    }
    if (w && w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) return YES;
    return NO;
}

static UIColor *SoulAccent(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:1.00 green:0.42 blue:0.55 alpha:1.0]
            : [UIColor colorWithRed:0.98 green:0.28 blue:0.45 alpha:1.0];
    }];
}
// 面板透明度：数值越高越不透明（这里比之前更实）
static UIColor *SoulPanelBg(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.99]
            : [UIColor colorWithWhite:1.00 alpha:0.99];
    }];
}
static UIColor *SoulRowBg(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.19 green:0.19 blue:0.22 alpha:0.98]
            : [UIColor colorWithWhite:0.95 alpha:0.98];
    }];
}
static UIColor *SoulRowHi(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.27 green:0.27 blue:0.31 alpha:1.0]
            : [UIColor colorWithWhite:0.90 alpha:1.0];
    }];
}
static UIColor *SoulText(void)    { return [UIColor labelColor]; }
static UIColor *SoulHair(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:1.0 alpha:0.16]
            : [UIColor colorWithWhite:0.0 alpha:0.12];
    }];
}

#pragma mark - hook 安装工具

static void SoulInstallMethodHook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (orig) *orig = method_getImplementation(m);
    /* 若该类本身没实现（方法是从父类继承来的），必须用 class_addMethod 挂到本类；
       直接 method_setImplementation 会改到父类的实现，波及整个 App。 */
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        method_setImplementation(m, newImp);
    }
}

static BOOL SoulClassImplements(Class c, SEL sel) {
    unsigned int mc = 0; Method *ms = class_copyMethodList(c, &mc);
    BOOL found = NO;
    for (unsigned int i = 0; i < mc; i++) { if (method_getName(ms[i]) == sel) { found = YES; break; } }
    if (ms) free(ms);
    return found;
}

#pragma mark - 选择面板（竖向 / 跟随深浅色）

typedef NS_ENUM(NSInteger, SoulGameMode) {
    SoulGameModeDice = 0,
    SoulGameModeFinger = 1,
};

@interface SoulPickerVC : UIViewController
@property (nonatomic, assign) SoulGameMode mode;
@property (nonatomic, copy) void (^onDone)(NSInteger value);
@end

@implementation SoulPickerVC {
    NSInteger _selected;
    NSMutableArray *_rows;
}

- (instancetype)initWithMode:(SoulGameMode)mode {
    if ((self = [super init])) {
        _mode = mode;
        _selected = -1;
        _rows = [NSMutableArray array];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (NSArray<NSArray *> *)options {
    if (_mode == SoulGameModeDice) {
        return @[@[@"随机", @(-1)], @[@"1 点", @1], @[@"2 点", @2], @[@"3 点", @3],
                 @[@"4 点", @4], @[@"5 点", @5], @[@"6 点", @6]];
    }
    return @[@[@"随机", @(-1)], @[@"✋  布", @1], @[@"✌️  剪刀", @2], @[@"✊  石头", @3]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)]];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = SoulPanelBg();
    card.layer.cornerRadius = 22;
    card.layer.masksToBounds = YES;
    [self.view addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = (_mode == SoulGameModeDice) ? @"选择骰子点数" : @"选择猜拳";
    title.textColor = SoulText();
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.distribution = UIStackViewDistributionFillEqually;

    for (NSArray *o in [self options]) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.tag = [o[1] integerValue];
        [row setTitle:o[0] forState:UIControlStateNormal];
        [row setTitleColor:SoulText() forState:UIControlStateNormal];
        row.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        row.backgroundColor = SoulRowBg();
        row.layer.cornerRadius = 14;
        row.layer.borderWidth = 1.5;
        row.layer.borderColor = [UIColor clearColor].CGColor;
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row.heightAnchor constraintEqualToConstant:44].active = YES;
        [stack addArrangedSubview:row];
        [_rows addObject:row];
    }
    [card addSubview:stack];

    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [sendBtn setTitle:@"发送" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    sendBtn.backgroundColor = SoulAccent();
    sendBtn.layer.cornerRadius = 23;
    [sendBtn addTarget:self action:@selector(sendTapped:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:sendBtn];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-36],

        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [stack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [sendBtn.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:14],
        [sendBtn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [sendBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [sendBtn.heightAnchor constraintEqualToConstant:46],
        [sendBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    [self refresh];
}

- (void)rowTapped:(UIButton *)b {
    _selected = b.tag;
    SoulLog(@"picker row tap -> %ld", (long)_selected);
    [self refresh];
}

- (void)refresh {
    for (UIButton *b in _rows) {
        BOOL active = (b.tag == _selected);
        b.backgroundColor = active ? SoulRowHi() : SoulRowBg();
        b.layer.borderColor = active ? SoulAccent().CGColor : [UIColor clearColor].CGColor;
        [b setTitleColor:active ? SoulAccent() : SoulText() forState:UIControlStateNormal];
    }
}

- (void)bgTapped:(id)sender { [self cancelTapped:nil]; }

- (void)sendTapped:(id)sender {
    NSInteger v = _selected;
    SoulLog(@"picker send tap -> %ld", (long)v);
    void (^done)(NSInteger) = self.onDone;
    self.onDone = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (done) done(v); }];
}

- (void)cancelTapped:(id)sender {
    SoulLog(@"picker cancel");
    void (^done)(NSInteger) = self.onDone;
    self.onDone = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (done) done(NSNotFound); }];
}

@end

#pragma mark - 悬浮设置窗口（可拖动 / 可滚动多项开关）

/* 悬浮面板的遮罩层：单独一个类，避免给 UIView 加手势 delegate 方法
   （那会让所有 UIView 都响应 gestureRecognizer:shouldReceiveTouch:，
    从而拦掉 SWTableViewCell 等控件的滑动手势）。 */
@interface SoulPanelOverlay : UIView <UIGestureRecognizerDelegate>
@end

static UIView *gSoulPanel = nil;
static NSArray<NSString *> *gSoulPanelKeys = nil;

static void SoulHidePanel(void) {
    if (gSoulPanel) { [gSoulPanel removeFromSuperview]; gSoulPanel = nil; }
}

static void SoulTogglePanel(void) {
    SoulLog(@"entry tapped. panel=%@", (gSoulPanel && gSoulPanel.superview) ? @"open" : @"closed");
    if (gSoulPanel && gSoulPanel.superview) { SoulHidePanel(); return; }
    gSoulPanel = nil;

    UIWindow *win = SoulHostWindow();
    if (!win) { SoulLog(@"toggle: no host window"); return; }

    BOOL dark = SoulAppDark();
    NSArray<NSDictionary *> *sections = SoulFxSections();

    const CGFloat W = 306;
    const CGFloat headerH = 48;
    const CGFloat rowH = 46;
    const CGFloat secH = 34;
    CGFloat contentH = 8;
    for (NSDictionary *sec in sections) {
        contentH += secH + ((NSArray *)sec[@"items"]).count * rowH;
    }
    CGFloat maxH = win.bounds.size.height - 130;
    CGFloat H = MIN(maxH, headerH + contentH);
    H = MAX(H, 260);

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    panel.backgroundColor = SoulPanelBg();
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = NO;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = SoulHair().CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = dark ? 0.5 : 0.18;
    panel.layer.shadowRadius = 18;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    if (@available(iOS 13.0, *)) {
        panel.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }

    UIView *inner = [[UIView alloc] initWithFrame:panel.bounds];
    inner.backgroundColor = SoulPanelBg();
    inner.layer.cornerRadius = 18;
    inner.layer.masksToBounds = YES;
    inner.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:inner];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 4, 200, headerH - 8)];
    title.text = @"Soul 助手";
    title.textColor = SoulText();
    title.font = [UIFont boldSystemFontOfSize:16];
    [inner addSubview:title];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, headerH - 0.5, W, 0.5)];
    line.backgroundColor = SoulHair();
    [inner addSubview:line];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, headerH, W, H - headerH)];
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [inner addSubview:scroll];

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    CGFloat y = 4;
    for (NSDictionary *sec in sections) {
        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 6, W - 32, secH - 6)];
        head.text = sec[@"title"];
        head.textColor = [SoulText() colorWithAlphaComponent:0.5];
        head.font = [UIFont boldSystemFontOfSize:12.5];
        [scroll addSubview:head];
        y += secH;

        NSArray *items = sec[@"items"];
        for (NSInteger j = 0; j < (NSInteger)items.count; j++) {
            NSArray *row = items[j];

            UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 16 - 62, rowH)];
            lab.text = row[0];
            lab.textColor = SoulText();
            lab.font = [UIFont systemFontOfSize:14.5];
            lab.adjustsFontSizeToFitWidth = YES;
            lab.minimumScaleFactor = 0.8;
            [scroll addSubview:lab];

            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(W - 16 - 51, y + (rowH - 31) / 2.0, 51, 31)];
            sw.onTintColor = SoulAccent();
            sw.on = SoulDefOn(row[1], [row[2] boolValue]);
            sw.tag = (NSInteger)keys.count;
            [keys addObject:row[1]];
            [sw addTarget:panel action:@selector(soulSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [scroll addSubview:sw];

            if (j < (NSInteger)items.count - 1) {
                UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(16, y + rowH - 0.5, W - 32, 0.5)];
                sep.backgroundColor = SoulHair();
                [scroll addSubview:sep];
            }
            y += rowH;
        }
    }
    gSoulPanelKeys = keys;
    scroll.contentSize = CGSizeMake(W, contentH);

    SoulPanelOverlay *overlay = [[SoulPanelOverlay alloc] initWithFrame:win.bounds];
    overlay.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.35]
                                   : [UIColor colorWithWhite:0 alpha:0.15];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:overlay
                                                                         action:@selector(soulBackdropTapped:)];
    tap.delegate = overlay;
    [overlay addGestureRecognizer:tap];

    CGFloat cx = win.bounds.size.width / 2;
    CGFloat cy = win.bounds.size.height / 2;
    panel.center = CGPointMake(cx, cy);

    [overlay addSubview:panel];
    [win addSubview:overlay];
    [win bringSubviewToFront:overlay];
    gSoulPanel = overlay;
    SoulLog(@"panel shown dark=%d center=(%.0f,%.0f) h=%.0f rows=%d", (int)dark, cx, cy, H, (int)keys.count);
}

@implementation SoulPanelOverlay
- (void)soulBackdropTapped:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded) SoulHidePanel();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return t.view == self;
}
@end

@implementation UIView (SoulPanel)
- (void)soulSwitchChanged:(UISwitch *)sw {
    if (!gSoulPanelKeys) return;
    if (sw.tag < 0 || sw.tag >= (NSInteger)gSoulPanelKeys.count) return;
    SoulSetDef(gSoulPanelKeys[sw.tag], sw.on);
}
@end

#pragma mark - 右上角入口图标（与导航栏标题垂直对齐）

static const void *kSoulEntryInstalledKey = &kSoulEntryInstalledKey;

static UILabel *SoulFindWidestLabel(UIView *root, UILabel *best) {
    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)root;
        if (l.text.length && !l.hidden && l.alpha > 0.05 && CGRectGetWidth(l.bounds) > 30) {
            if (!best || CGRectGetWidth(l.bounds) > CGRectGetWidth(best.bounds)) best = l;
        }
    }
    for (UIView *s in root.subviews) best = SoulFindWidestLabel(s, best);
    return best;
}

static void SoulInstallEntry(UIViewController *vc) {
    if (!vc) return;
    if (objc_getAssociatedObject(vc, kSoulEntryInstalledKey)) return;
    objc_setAssociatedObject(vc, kSoulEntryInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *icon = [UIImage systemImageNamed:@"die.face.5.fill"];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    if (icon) {
        [btn setImage:icon forState:UIControlStateNormal];
    } else {
        [btn setTitle:@"🎲" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:20];
    }
    btn.tintColor = SoulText();
    btn.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.16];
    btn.layer.cornerRadius = 17;
    [btn addTarget:vc action:@selector(soulEntryTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *nav = nil;
    SEL navSel = NSSelectorFromString(@"navView");
    if ([vc respondsToSelector:navSel]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(vc, navSel);
        if ([v isKindOfClass:[UIView class]]) nav = v;
    }

    UIView *host = nav ?: vc.view;
    [host addSubview:btn];

    UILabel *titleLabel = nav ? SoulFindWidestLabel(nav, nil) : nil;

    NSMutableArray *cs = [NSMutableArray array];
    [cs addObject:[btn.widthAnchor constraintEqualToConstant:34]];
    [cs addObject:[btn.heightAnchor constraintEqualToConstant:34]];
    [cs addObject:[btn.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12]];
    if (titleLabel) {
        [cs addObject:[btn.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor]];
    } else {
        [cs addObject:[btn.centerYAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:22]];
    }
    [NSLayoutConstraint activateConstraints:cs];
}

@implementation UIViewController (SoulEntry)
- (void)soulEntryTapped:(id)sender { SoulTogglePanel(); }
@end

#pragma mark - 骰子/猜拳 hook

static void (*gOrigSendRollDice)(id, SEL, long long, id);
static void (*gOrigSendFinger)(id, SEL, long long, id);
static BOOL gPickerShowing = NO;
static BOOL gInOrig = NO;
static int gSeq = 0;

static void SoulPresentPicker(SoulGameMode mode, void (^done)(NSInteger value)) {
    if (gPickerShowing) { SoulLog(@"picker already showing, drop"); return; }
    gPickerShowing = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = SoulTopViewController();
        if (!top) { SoulLog(@"picker: no top vc"); gPickerShowing = NO; return; }
        SoulPickerVC *picker = [[SoulPickerVC alloc] initWithMode:mode];
        if (@available(iOS 13.0, *)) {
            picker.overrideUserInterfaceStyle = SoulAppDark() ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        }
        picker.onDone = ^(NSInteger value) {
            gPickerShowing = NO;
            if (done) done(value);
        };
        [top presentViewController:picker animated:YES completion:nil];
        SoulLog(@"picker presented on %@", NSStringFromClass([top class]));
    });
}

static void SoulHookSendDice(id self, SEL _cmd, long long value, id to) {
    gSeq++;
    SoulLog(@"dice hook #%d value=%lld inOrig=%d showing=%d self=%@", gSeq, value, (int)gInOrig, (int)gPickerShowing, NSStringFromClass([self class]));
    if (gInOrig || !SoulDiceOn()) { gOrigSendRollDice(self, _cmd, value, to); return; }
    SoulPresentPicker(SoulGameModeDice, ^(NSInteger chosen) {
        if (chosen == NSNotFound) { SoulLog(@"dice cancelled"); return; }
        long long out = (chosen < 0) ? value : (long long)chosen;
        SoulLog(@"dice send out=%lld", out);
        gInOrig = YES;
        gOrigSendRollDice(self, _cmd, out, to);
        gInOrig = NO;
    });
}

static void SoulHookSendFinger(id self, SEL _cmd, long long value, id to) {
    gSeq++;
    SoulLog(@"finger hook #%d value=%lld inOrig=%d showing=%d self=%@", gSeq, value, (int)gInOrig, (int)gPickerShowing, NSStringFromClass([self class]));
    if (gInOrig || !SoulDiceOn()) { gOrigSendFinger(self, _cmd, value, to); return; }
    SoulPresentPicker(SoulGameModeFinger, ^(NSInteger chosen) {
        if (chosen == NSNotFound) { SoulLog(@"finger cancelled"); return; }
        long long out = (chosen < 0) ? value : (long long)chosen;
        SoulLog(@"finger send out=%lld", out);
        gInOrig = YES;
        gOrigSendFinger(self, _cmd, out, to);
        gInOrig = NO;
    });
}

#pragma mark - 阅后即焚解锁（允许截屏 / 录屏 / 后台不失效）

static void (*gOrigSnapDidTakeScreenshot)(id, SEL);
static void (*gOrigSnapScreenCaptureChanged)(id, SEL);
static void (*gOrigSnapWillResignActive)(id, SEL);
static BOOL gSnapHooksInstalled = NO;

static void SoulSnapDidTakeScreenshot(id self, SEL _cmd) {
    if (SoulDef(kFxSnapUnlock) || SoulDef(kFxSnapUnlock)) { SoulLog(@"snap didTakeScreenshot swallowed"); return; }
    if (gOrigSnapDidTakeScreenshot) gOrigSnapDidTakeScreenshot(self, _cmd);
}
static void SoulSnapScreenCaptureChanged(id self, SEL _cmd) {
    if (SoulDef(kFxSnapUnlock) || SoulDef(kFxSnapUnlock)) { SoulLog(@"snap screenCaptureStatusChanged swallowed"); return; }
    if (gOrigSnapScreenCaptureChanged) gOrigSnapScreenCaptureChanged(self, _cmd);
}
static void SoulSnapWillResignActive(id self, SEL _cmd) {
    if (SoulDef(kFxSnapUnlock) || SoulDef(kFxSnapUnlock)) { SoulLog(@"snap willResignActive swallowed"); return; }
    if (gOrigSnapWillResignActive) gOrigSnapWillResignActive(self, _cmd);
}

static void SoulInstallSnapHooks(void) {
    if (gSnapHooksInstalled) return;
    Class cls = objc_getClass("_TtC15SoulPrivateChat23SOChatSnapshotPreviewVC");
    if (!cls) cls = objc_getClass("SOChatSnapshotPreviewVC");
    if (!cls) return;
    gSnapHooksInstalled = YES;
    SoulInstallMethodHook(cls, NSSelectorFromString(@"didTakeScreenshot"),
                          (IMP)SoulSnapDidTakeScreenshot, (IMP *)&gOrigSnapDidTakeScreenshot);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"screenCaptureStatusChanged"),
                          (IMP)SoulSnapScreenCaptureChanged, (IMP *)&gOrigSnapScreenCaptureChanged);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"willResignActive"),
                          (IMP)SoulSnapWillResignActive, (IMP *)&gOrigSnapWillResignActive);
    SoulLog(@"snap hooks installed on %@", NSStringFromClass(cls));
}

static void SoulInstallSnapHooksRetry(int n) {
    if (gSnapHooksInstalled) return;
    if (objc_getClass("_TtC15SoulPrivateChat23SOChatSnapshotPreviewVC") ||
        objc_getClass("SOChatSnapshotPreviewVC")) {
        SoulInstallSnapHooks();
        return;
    }
    if (n <= 0) { SoulLog(@"snap class not found after retries"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulInstallSnapHooksRetry(n - 1); });
}

#pragma mark - 保存无水印（SOSaveAlbumWithWaterMarkUtils）

static void (*gOrigSaveImgWM)(id, SEL, id, BOOL, id);
static void (*gOrigSaveImgWMai)(id, SEL, id, BOOL, id, id);
static void (*gOrigWriteWM)(id, SEL, id, BOOL, BOOL, id);
static void (*gOrigWriteWMai)(id, SEL, id, BOOL, BOOL, id, id);
static void (*gOrigSaveVidWM)(id, SEL, id, BOOL, id);
static void (*gOrigSaveVidWMtoast)(id, SEL, id, BOOL, BOOL, id);
static void (*gOrigSaveVidWMprog)(id, SEL, id, BOOL, id, BOOL, id);

static void SoulHookSaveImgWM(id s, SEL c, id u, BOOL wm, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save image: force no watermark"); }
    if (gOrigSaveImgWM) gOrigSaveImgWM(s, c, u, wm, cb);
}
static void SoulHookSaveImgWMai(id s, SEL c, id u, BOOL wm, id ai, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save image(ai): force no watermark"); }
    if (gOrigSaveImgWMai) gOrigSaveImgWMai(s, c, u, wm, ai, cb);
}
static void SoulHookWriteWM(id s, SEL c, id u, BOOL toast, BOOL wm, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save write: force no watermark"); }
    if (gOrigWriteWM) gOrigWriteWM(s, c, u, toast, wm, cb);
}
static void SoulHookWriteWMai(id s, SEL c, id u, BOOL toast, BOOL wm, id ai, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save write(ai): force no watermark"); }
    if (gOrigWriteWMai) gOrigWriteWMai(s, c, u, toast, wm, ai, cb);
}
static void SoulHookSaveVidWM(id s, SEL c, id v, BOOL wm, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save video: force no watermark"); }
    if (gOrigSaveVidWM) gOrigSaveVidWM(s, c, v, wm, cb);
}
static void SoulHookSaveVidWMtoast(id s, SEL c, id v, BOOL wm, BOOL toast, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save video(toast): force no watermark"); }
    if (gOrigSaveVidWMtoast) gOrigSaveVidWMtoast(s, c, v, wm, toast, cb);
}
static void SoulHookSaveVidWMprog(id s, SEL c, id v, BOOL wm, id prog, BOOL toast, id cb) {
    if (SoulDef(kFxSaveNoWM)) { wm = NO; SoulLog(@"save video(prog): force no watermark"); }
    if (gOrigSaveVidWMprog) gOrigSaveVidWMprog(s, c, v, wm, prog, toast, cb);
}

static void SoulInstallWatermarkHooks(void) {
    Class cls = objc_getClass("SOSaveAlbumWithWaterMarkUtils");
    if (!cls) { SoulLog(@"watermark class not found"); return; }
    SoulInstallMethodHook(cls, NSSelectorFromString(@"saveImageToAlbumWithUrl:needWartermark:completion:"),
                          (IMP)SoulHookSaveImgWM, (IMP *)&gOrigSaveImgWM);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"saveImageToAlbumWithUrl:needWartermark:aiDataModel:completion:"),
                          (IMP)SoulHookSaveImgWMai, (IMP *)&gOrigSaveImgWMai);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"writeToAlbumWithUrl:handleResultToast:needWartermark:completion:"),
                          (IMP)SoulHookWriteWM, (IMP *)&gOrigWriteWM);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"writeToAlbumWithUrl:handleResultToast:needWartermark:aiDataModel:completion:"),
                          (IMP)SoulHookWriteWMai, (IMP *)&gOrigWriteWMai);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"saveVideoToAlbum:watermark:completion:"),
                          (IMP)SoulHookSaveVidWM, (IMP *)&gOrigSaveVidWM);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"saveVideoToAlbum:watermark:toast:completion:"),
                          (IMP)SoulHookSaveVidWMtoast, (IMP *)&gOrigSaveVidWMtoast);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"saveVideoToAlbum:watermark:progress:toast:completion:"),
                          (IMP)SoulHookSaveVidWMprog, (IMP *)&gOrigSaveVidWMprog);
    SoulLog(@"watermark hooks installed");
}

#pragma mark - 视频水印（SOWatermarkOperation）

static void (*gOrigWmSetShouldUse)(id, SEL, BOOL);
static void (*gOrigWmSetAddDefault)(id, SEL, BOOL);
static void (*gOrigWmStart)(id, SEL);

static void SoulHookWmSetShouldUse(id s, SEL c, BOOL v) {
    if (SoulDef(kFxSaveNoWM)) { v = NO; }
    if (gOrigWmSetShouldUse) gOrigWmSetShouldUse(s, c, v);
}
static void SoulHookWmSetAddDefault(id s, SEL c, BOOL v) {
    if (SoulDef(kFxSaveNoWM)) { v = NO; }
    if (gOrigWmSetAddDefault) gOrigWmSetAddDefault(s, c, v);
}
static void SoulHookWmStart(id s, SEL c) {
    SoulLog(@"SOWatermarkOperation start nowm=%d", (int)SoulDef(kFxSaveNoWM));
    if (SoulDef(kFxSaveNoWM)) {
        SEL a = NSSelectorFromString(@"setShouldUseWatermark:");
        SEL b = NSSelectorFromString(@"setAddDefaultWatermark:");
        if ([s respondsToSelector:a]) ((void (*)(id, SEL, BOOL))objc_msgSend)(s, a, NO);
        if ([s respondsToSelector:b]) ((void (*)(id, SEL, BOOL))objc_msgSend)(s, b, NO);
    }
    if (gOrigWmStart) gOrigWmStart(s, c);
}
static void SoulInstallVideoWatermarkHooks(void) {
    Class cls = objc_getClass("SOWatermarkOperation");
    if (!cls) { SoulLog(@"SOWatermarkOperation not found"); return; }
    SoulInstallMethodHook(cls, NSSelectorFromString(@"setShouldUseWatermark:"),
                          (IMP)SoulHookWmSetShouldUse, (IMP *)&gOrigWmSetShouldUse);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"setAddDefaultWatermark:"),
                          (IMP)SoulHookWmSetAddDefault, (IMP *)&gOrigWmSetAddDefault);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"start"),
                          (IMP)SoulHookWmStart, (IMP *)&gOrigWmStart);
    SoulLog(@"video watermark hooks installed");
}

#pragma mark - 关闭匹配背景音乐（SOMatchMusicManager）

static void (*gOrigBgmA)(id, SEL, id, BOOL, BOOL);
static void (*gOrigBgmB)(id, SEL, id, BOOL, BOOL, BOOL);
static void (*gOrigBgmOpen)(id, SEL);

static void SoulHookBgmA(id s, SEL c, id url, BOOL loop, BOOL skip) {
    if (SoulDef(kFxMuteMatchBgm)) { SoulLog(@"match bgm blocked A url=%@", url); return; }
    if (gOrigBgmA) gOrigBgmA(s, c, url, loop, skip);
}
static void SoulHookBgmB(id s, SEL c, id url, BOOL busy, BOOL loop, BOOL skip) {
    if (SoulDef(kFxMuteMatchBgm)) { SoulLog(@"match bgm blocked B url=%@", url); return; }
    if (gOrigBgmB) gOrigBgmB(s, c, url, busy, loop, skip);
}
static void SoulHookBgmOpen(id s, SEL c) {
    if (SoulDef(kFxMuteMatchBgm)) { SoulLog(@"match bgm blocked openMusic"); return; }
    if (gOrigBgmOpen) gOrigBgmOpen(s, c);
}

static void SoulInstallBgmHooks(void) {
    Class cls = objc_getClass("SOMatchMusicManager");
    if (!cls) { SoulLog(@"match music class not found"); return; }
    SoulInstallMethodHook(cls, NSSelectorFromString(@"playWithMusicURL:loop:skipCheckMute:"),
                          (IMP)SoulHookBgmA, (IMP *)&gOrigBgmA);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"playWithMusicURL:checkMediaIsBusying:loop:skipCheckMute:"),
                          (IMP)SoulHookBgmB, (IMP *)&gOrigBgmB);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"openMusic"),
                          (IMP)SoulHookBgmOpen, (IMP *)&gOrigBgmOpen);
    SoulLog(@"match bgm hooks installed");
}

#pragma mark - 出站请求日志（用于定位 输入状态 / 主页访问 / 权益限制 等接口）

static BOOL SoulNetInterested(void) {
    return SoulDef(kFxDebugLog) || SoulDef(kFxBlockInput) || SoulDef(kFxGiftFree) ||
           SoulDef(kFxEtiquetteFree) || SoulDef(kFxSaveNoWM);
}

static void SoulLogRequest(NSURLRequest *req, NSString *via) {
    if (!req || !SoulNetInterested()) return;
    NSString *u = req.URL.absoluteString ?: @"";
    NSString *m = req.HTTPMethod ?: @"GET";
    NSString *body = @"";
    NSData *bd = req.HTTPBody;
    if (bd.length) {
        NSString *s = [[NSString alloc] initWithData:bd encoding:NSUTF8StringEncoding];
        if (s.length) body = (s.length > 800) ? [s substringToIndex:800] : s;
        else body = [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)bd.length];
    }
    SoulLog(@"NET %@ %@ %@ body=%@", via, m, u, body);
}

static BOOL SoulShouldBlockRequest(NSURLRequest *req) {
    if (!SoulDef(kFxSnapUnlock)) return NO;
    NSString *u = req.URL.absoluteString ?: @"";
    if ([u containsString:@"/snapchat/read"]) return YES;
    return NO;
}

static id (*gOrigDataTaskHandler)(id, SEL, NSURLRequest *, id);
typedef void (^SoulDataTaskCompletion)(NSData *data, NSURLResponse *response, NSError *error);

static id SoulHookDataTaskHandler(id self, SEL _cmd, NSURLRequest *req, id handler) {
    SoulLogRequest(req, @"dataTaskWithRequest:completionHandler:");
    id wrapped = handler;
    if (handler) {
        SoulDataTaskCompletion cb = (SoulDataTaskCompletion)handler;
        NSString *ru = req.URL.absoluteString ?: @"";
        BOOL wantResp = SoulNetInterested() &&
            ([ru containsString:@"limit"] || [ru containsString:@"gift"] ||
             [ru containsString:@"snapchat"] || [ru containsString:@"friendly"] ||
             [ru containsString:@"session/status"] || [ru containsString:@"socialGrace"] ||
             [ru containsString:@"increase/sign"]);
        if (wantResp) {
            wrapped = ^(NSData *d, NSURLResponse *resp, NSError *err) {
                if (d.length) {
                    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                    if (s) {
                        if (s.length > 4000) s = [s substringToIndex:4000];
                        SoulLog(@"RESP %@ -> %@", ru, s);
                    } else {
                        SoulLog(@"RESP %@ -> <%lu bytes>", ru, (unsigned long)d.length);
                    }
                }
                cb(d, resp, err);
            };
        } else {
            wrapped = ^(NSData *d, NSURLResponse *resp, NSError *err) {
                cb(d, resp, err);
            };
        }
    }
    id task = gOrigDataTaskHandler(self, _cmd, req, wrapped);
    if (SoulShouldBlockRequest(req)) {
        SoulLog(@"snap read blocked (multi-view) url=%@", req.URL.absoluteString);
        [task cancel];
    }
    return task;
}

static id (*gOrigDataTask)(id, SEL, NSURLRequest *);
static id SoulHookDataTask(id self, SEL _cmd, NSURLRequest *req) {
    SoulLogRequest(req, @"dataTaskWithRequest:");
    id task = gOrigDataTask(self, _cmd, req);
    if (SoulShouldBlockRequest(req)) {
        SoulLog(@"snap read blocked (multi-view) url=%@", req.URL.absoluteString);
        [task cancel];
    }
    return task;
}



static void SoulInstallNetHooks(void) {
    Class cls = objc_getClass("NSURLSession");
    if (!cls) return;
    SoulInstallMethodHook(cls, NSSelectorFromString(@"dataTaskWithRequest:completionHandler:"),
                          (IMP)SoulHookDataTaskHandler, (IMP *)&gOrigDataTaskHandler);
    SoulInstallMethodHook(cls, NSSelectorFromString(@"dataTaskWithRequest:"),
                          (IMP)SoulHookDataTask, (IMP *)&gOrigDataTask);
    SoulLog(@"net hooks installed");
}

#pragma mark - 阅后即焚 / 隐私保护 探针

static void (*gOrigSnapViewDidLoad)(id, SEL);
static id (*gOrigSnapInitSnapInfo)(id, SEL, id);
static void (*gOrigSnapViewWillDisappear)(id, SEL, BOOL);
static void (*gSuperSnapViewWillDisappear)(id, SEL, BOOL);

static UIImage *SoulFindBiggestImage(UIView *v, CGFloat *bestArea) {
    UIImage *best = nil;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *im = ((UIImageView *)v).image;
        if (im) {
            CGFloat a = v.bounds.size.width * v.bounds.size.height;
            if (a > *bestArea) { *bestArea = a; best = im; }
        }
    }
    for (UIView *sub in v.subviews) {
        UIImage *im = SoulFindBiggestImage(sub, bestArea);
        if (im) best = im;
    }
    return best;
}

static void SoulSnapShowNativeSheet(UIViewController *vc);
static void SoulSnapClosePreview(void);
static void SoulSnapFixHintLabel(UIView *v);

@interface SoulSnapSaveHelper : NSObject
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end
@implementation SoulSnapSaveHelper
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIViewController *vc = (UIViewController *)g.view.nextResponder;
    if (![vc isKindOfClass:[UIViewController class]]) vc = SoulTopViewController();
    SoulSnapShowNativeSheet(vc);
}
- (void)handleSingleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    SoulSnapClosePreview();
}
@end

static SoulSnapSaveHelper *SoulSnapHelper(void) {
    static SoulSnapSaveHelper *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [SoulSnapSaveHelper new]; });
    return h;
}

static void SoulSnapSaveImageToAlbum(UIImage *img) {
    if (!img) return;
    UIImageWriteToSavedPhotosAlbum(img, nil, nil, NULL);
    SoulLog(@"snap: saved image to album size=%@", NSStringFromCGSize(img.size));
}

static void SoulSnapShowNativeSheet(UIViewController *vc) {
    if (!vc) vc = SoulTopViewController();
    CGFloat area = 0;
    UIImage *img = SoulFindBiggestImage(vc.view, &area);
    if (!img) { SoulLog(@"snap sheet: no image found"); return; }
    Class itemCls = objc_getClass("SOActionSheetItem");
    Class sheetCls = objc_getClass("SOActionSheet");
    if (!itemCls || !sheetCls) { SoulSnapSaveImageToAlbum(img); return; }
    NSMutableArray *items = [NSMutableArray array];
    id item = ((id (*)(id, SEL, id, id))objc_msgSend)([itemCls alloc], NSSelectorFromString(@"initWithTitle:icon:"), @"保存图片", nil);
    if (item) [items addObject:item];
    id sheet = ((id (*)(id, SEL, id, id, id))objc_msgSend)([sheetCls alloc], NSSelectorFromString(@"initWithTitle:cancelTitle:items:"), @"", @"取消", items);
    if (!sheet) { SoulSnapSaveImageToAlbum(img); return; }
    void (^done)(NSInteger, id) = ^(NSInteger idx, id it) {
        if (idx == 0) SoulSnapSaveImageToAlbum(img);
    };
    SEL showSel = NSSelectorFromString(@"showWithCompletion:");
    if ([sheet respondsToSelector:showSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(sheet, showSel, done);
        SoulLog(@"snap: native photo sheet shown");
    } else {
        SoulSnapSaveImageToAlbum(img);
    }
}

static void SoulSnapClosePreview(void) {
    UIViewController *vc = SoulTopViewController();
    SoulLog(@"snap: close %@", NSStringFromClass([vc class]));
    if (vc.navigationController && vc.navigationController.viewControllers.count > 1) {
        [vc.navigationController popViewControllerAnimated:YES];
    } else {
        [vc dismissViewControllerAnimated:YES completion:nil];
    }
}

static void SoulSnapFixHintLabel(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if ([l.text containsString:@"秒后销毁"] || [l.text containsString:@"点击屏幕可查看"]) {
            l.text = @"点按关闭 · 长按保存";
            SoulLog(@"snap: hint label rewritten");
        }
    }
    for (UIView *s in v.subviews) SoulSnapFixHintLabel(s);
}

static void SoulSnapViewDidLoad(id self, SEL _cmd) {
    if (gOrigSnapViewDidLoad) gOrigSnapViewDidLoad(self, _cmd);
    SoulLog(@"SNAP viewDidLoad %@", NSStringFromClass([self class]));
    if (SoulDef(kFxSnapUnlock) || SoulDef(kFxSnapUnlock)) {
        UIViewController *vc = (UIViewController *)self;
        UILongPressGestureRecognizer *lpGr = nil;
        UITapGestureRecognizer *tapGr = nil;
        for (UIGestureRecognizer *gr in vc.view.gestureRecognizers) {
            if ([gr isKindOfClass:[UILongPressGestureRecognizer class]]) lpGr = (UILongPressGestureRecognizer *)gr;
            if ([gr isKindOfClass:[UITapGestureRecognizer class]] && ((UITapGestureRecognizer *)gr).numberOfTapsRequired == 1) tapGr = (UITapGestureRecognizer *)gr;
        }
        if (!lpGr) {
            lpGr = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:SoulSnapHelper()
                    action:@selector(handleLongPress:)];
            lpGr.minimumPressDuration = 0.4;
            [vc.view addGestureRecognizer:lpGr];
            SoulLog(@"snap: long-press native-menu installed");
        }
        if (!tapGr) {
            tapGr = [[UITapGestureRecognizer alloc]
                     initWithTarget:SoulSnapHelper()
                     action:@selector(handleSingleTap:)];
            tapGr.numberOfTapsRequired = 1;
            [vc.view addGestureRecognizer:tapGr];
            SoulLog(@"snap: single-tap-close installed");
        }
        if (lpGr && tapGr) [tapGr requireGestureRecognizerToFail:lpGr];
        for (double d = 0.5; d <= 2.0; d += 0.5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SoulSnapFixHintLabel(vc.view);
            });
        }
    }
}
static id SoulSnapInitSnapInfo(id self, SEL _cmd, id info) {
    id r = gOrigSnapInitSnapInfo ? gOrigSnapInitSnapInfo(self, _cmd, info) : self;
    SoulLog(@"SNAP initWithSnapInfo info=%@", info);
    return r;
}
static void SoulSnapViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    SoulLog(@"SNAP viewWillDisappear %@", NSStringFromClass([self class]));
    /* 原实现 = [super viewWillDisappear:] + 本地焚毁(sub_1060346cc)。
       开启「多次查看」时只调 super，跳过本地焚毁，图片留在本地可反复打开。 */
    if (SoulDef(kFxSnapUnlock) && [self isKindOfClass:[UIViewController class]]) {
        if (gSuperSnapViewWillDisappear) gSuperSnapViewWillDisappear(self, _cmd, animated);
        SoulLog(@"snap: skip local burn on close");
        return;
    }
    if (gOrigSnapViewWillDisappear) gOrigSnapViewWillDisappear(self, _cmd, animated);
}
static void SoulInstallSnapProbes(void) {
    Class cls = objc_getClass("_TtC15SoulPrivateChat23SOChatSnapshotPreviewVC");
    if (!cls) cls = objc_getClass("SOChatSnapshotPreviewVC");
    if (!cls) { SoulLog(@"snap probe: class not found"); return; }
    SoulInstallMethodHook(cls, NSSelectorFromString(@"viewDidLoad"),
                          (IMP)SoulSnapViewDidLoad, (IMP *)&gOrigSnapViewDidLoad);
    if (class_getInstanceMethod(cls, NSSelectorFromString(@"initWithSnapInfo:"))) {
        SoulInstallMethodHook(cls, NSSelectorFromString(@"initWithSnapInfo:"),
                              (IMP)SoulSnapInitSnapInfo, (IMP *)&gOrigSnapInitSnapInfo);
    }
    Class supCls = class_getSuperclass(cls);
    if (supCls) {
        gSuperSnapViewWillDisappear = (void (*)(id, SEL, BOOL))
            class_getMethodImplementation(supCls, NSSelectorFromString(@"viewWillDisappear:"));
    }
    SoulInstallMethodHook(cls, NSSelectorFromString(@"viewWillDisappear:"),
                          (IMP)SoulSnapViewWillDisappear, (IMP *)&gOrigSnapViewWillDisappear);
    SoulLog(@"snap probes installed");
}

#pragma mark - 阅后即焚：多次查看（禁本地焚毁）

static void (*gOrigSnapScheduleBurn)(id, SEL, id, double, id);
static BOOL (*gOrigSnapShouldBurn)(id, SEL, long);

static void SoulHookSnapScheduleBurn(id s, SEL c, id msgId, double delay, id block) {
    if (SoulDef(kFxSnapUnlock)) {
        SoulLog(@"snap burn canceled (multiview) msgId=%@ delay=%.1f", msgId, delay);
        return;
    }
    if (gOrigSnapScheduleBurn) gOrigSnapScheduleBurn(s, c, msgId, delay, block);
}
static BOOL SoulHookSnapShouldBurn(id s, SEL c, long scene) {
    if (SoulDef(kFxSnapUnlock)) { return NO; }
    return gOrigSnapShouldBurn ? gOrigSnapShouldBurn(s, c, scene) : NO;
}

static void (*gOrigSnapRecallSched)(id, SEL, id, double, id, id);
static void SoulHookSnapRecallSched(id s, SEL c, id msgId, double delay, id reason, id completion) {
    if (SoulDef(kFxSnapUnlock)) {
        SoulLog(@"snap recall schedule canceled (multiview) msgId=%@ delay=%.1f", msgId, delay);
        return;
    }
    if (gOrigSnapRecallSched) gOrigSnapRecallSched(s, c, msgId, delay, reason, completion);
}
static void (*gOrigSnapRecallSend)(id, SEL, id, id);
static void SoulHookSnapRecallSend(id s, SEL c, id msgId, id uid) {
    if (SoulDef(kFxSnapUnlock)) {
        SoulLog(@"snap recall IM blocked (multiview) msgId=%@ to=%@", msgId, uid);
        return;
    }
    if (gOrigSnapRecallSend) gOrigSnapRecallSend(s, c, msgId, uid);
}

static void SoulInstallSnapMultiHooks(void) {
    Class t = objc_getClass("SOSnapMsgBurnTimer");
    if (t) {
        SoulInstallMethodHook(t, NSSelectorFromString(@"scheduleBurnForMsgId:delay:burnBlock:"),
                              (IMP)SoulHookSnapScheduleBurn, (IMP *)&gOrigSnapScheduleBurn);
        SoulLog(@"snap burn timer hooked");
    } else {
        SoulLog(@"SOSnapMsgBurnTimer not found");
    }
    Class m = objc_getClass("SOSnapMsgStateModel");
    if (m) {
        SoulInstallMethodHook(m, NSSelectorFromString(@"shouldBeBurnedForScene:"),
                              (IMP)SoulHookSnapShouldBurn, (IMP *)&gOrigSnapShouldBurn);
        SoulLog(@"snap state model hooked");
    } else {
        SoulLog(@"SOSnapMsgStateModel not found");
    }
    Class rs = objc_getClass("SOPCSnapBurnRecallScheduler");
    if (rs) {
        SoulInstallMethodHook(rs, NSSelectorFromString(@"scheduleWithMsgId:delay:reason:completion:"),
                              (IMP)SoulHookSnapRecallSched, (IMP *)&gOrigSnapRecallSched);
        SoulLog(@"snap recall scheduler hooked");
    } else {
        SoulLog(@"SOPCSnapBurnRecallScheduler not found");
    }
    Class ps = objc_getClass("SOPCMessageSender");
    if (ps) {
        SoulInstallMethodHook(ps, NSSelectorFromString(@"sendSnapBurnRecallIMMessageWithMsgId:to:"),
                              (IMP)SoulHookSnapRecallSend, (IMP *)&gOrigSnapRecallSend);
        SoulLog(@"snap recall sender hooked");
    }
}

#pragma mark - Web 容器（定位设置页）

static NSString *SoulWebURL(id vc) {
    SEL sels[] = { NSSelectorFromString(@"webViewPageUrl"), NSSelectorFromString(@"getUrl") };
    for (int i = 0; i < 2; i++) {
        if (![vc respondsToSelector:sels[i]]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(vc, sels[i]);
        if ([v isKindOfClass:[NSURL class]]) return ((NSURL *)v).absoluteString;
        if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    }
    return nil;
}

static void (*gOrigWebDidAppear)(id, SEL, BOOL);

static void SoulHookWebDidAppear(id self, SEL _cmd, BOOL animated) {
    gOrigWebDidAppear(self, _cmd, animated);
    NSString *url = SoulWebURL(self);
    SoulLog(@"web appear %@ url=%@", NSStringFromClass([self class]), url);
    if (url.length) {
        NSString *l = url.lowercaseString;
        if ([l containsString:@"/setting"] || [l containsString:@"setting/#"]) {
            SoulInstallEntry((UIViewController *)self);
        }
    }
}

#pragma mark - 安装

#pragma mark - Share-home-page limit (privacy protection) hooks

static BOOL (*gOrigCfgEnableShare)(id, SEL);
static void (*gOrigCfgSetEnableShare)(id, SEL, BOOL);
static BOOL (*gOrigCfgUnableOutside)(id, SEL);
static void (*gOrigCfgSetUnableOutside)(id, SEL, BOOL);
static BOOL (*gOrigPostUnableOutside)(id, SEL);
static void (*gOrigPostSetUnableOutside)(id, SEL, BOOL);
static BOOL (*gOrigViewCanShare)(id, SEL);
static void (*gOrigViewSetCanShare)(id, SEL, BOOL);

static BOOL SoulHookCfgEnableShare(id self, SEL _cmd) {
    if (SoulDef(kFxShareHome)) return YES;
    return gOrigCfgEnableShare ? gOrigCfgEnableShare(self, _cmd) : YES;
}
static void SoulHookCfgSetEnableShare(id self, SEL _cmd, BOOL v) {
    if (SoulDef(kFxShareHome)) v = YES;
    if (gOrigCfgSetEnableShare) gOrigCfgSetEnableShare(self, _cmd, v);
}
static BOOL SoulHookCfgUnableOutside(id self, SEL _cmd) {
    if (SoulDef(kFxShareHome)) return NO;
    return gOrigCfgUnableOutside ? gOrigCfgUnableOutside(self, _cmd) : NO;
}
static void SoulHookCfgSetUnableOutside(id self, SEL _cmd, BOOL v) {
    if (SoulDef(kFxShareHome)) v = NO;
    if (gOrigCfgSetUnableOutside) gOrigCfgSetUnableOutside(self, _cmd, v);
}
static BOOL SoulHookPostUnableOutside(id self, SEL _cmd) {
    if (SoulDef(kFxShareHome)) return NO;
    return gOrigPostUnableOutside ? gOrigPostUnableOutside(self, _cmd) : NO;
}
static void SoulHookPostSetUnableOutside(id self, SEL _cmd, BOOL v) {
    if (SoulDef(kFxShareHome)) v = NO;
    if (gOrigPostSetUnableOutside) gOrigPostSetUnableOutside(self, _cmd, v);
}
static BOOL SoulHookViewCanShare(id self, SEL _cmd) {
    if (SoulDef(kFxShareHome)) return YES;
    return gOrigViewCanShare ? gOrigViewCanShare(self, _cmd) : YES;
}
static void SoulHookViewSetCanShare(id self, SEL _cmd, BOOL v) {
    if (SoulDef(kFxShareHome)) v = YES;
    if (gOrigViewSetCanShare) gOrigViewSetCanShare(self, _cmd, v);
}

static void SoulInstallShareHooks(void) {
    Class cfg = objc_getClass("SOCommonShareAndToolConfig");
    if (cfg) {
        SoulInstallMethodHook(cfg, NSSelectorFromString(@"enableShare"), (IMP)SoulHookCfgEnableShare, (IMP *)&gOrigCfgEnableShare);
        SoulInstallMethodHook(cfg, NSSelectorFromString(@"setEnableShare:"), (IMP)SoulHookCfgSetEnableShare, (IMP *)&gOrigCfgSetEnableShare);
        SoulInstallMethodHook(cfg, NSSelectorFromString(@"isUnableOutsideShare"), (IMP)SoulHookCfgUnableOutside, (IMP *)&gOrigCfgUnableOutside);
        SoulInstallMethodHook(cfg, NSSelectorFromString(@"setIsUnableOutsideShare:"), (IMP)SoulHookCfgSetUnableOutside, (IMP *)&gOrigCfgSetUnableOutside);
        SoulLog(@"share config hooked");
    }
    Class view = objc_getClass("SOCommonShareAndToolView");
    if (view) {
        SoulInstallMethodHook(view, NSSelectorFromString(@"canShare"), (IMP)SoulHookViewCanShare, (IMP *)&gOrigViewCanShare);
        SoulInstallMethodHook(view, NSSelectorFromString(@"setCanShare:"), (IMP)SoulHookViewSetCanShare, (IMP *)&gOrigViewSetCanShare);
        SoulLog(@"share view hooked");
    }
    Class post = objc_getClass("SOPostToolModel");
    if (post) {
        SoulInstallMethodHook(post, NSSelectorFromString(@"isUnableOutsideShare"), (IMP)SoulHookPostUnableOutside, (IMP *)&gOrigPostUnableOutside);
        SoulInstallMethodHook(post, NSSelectorFromString(@"setIsUnableOutsideShare:"), (IMP)SoulHookPostSetUnableOutside, (IMP *)&gOrigPostSetUnableOutside);
        SoulLog(@"post tool model hooked");
    }
}

#pragma mark - Anti recall hooks

static void (*gOrigDMUpdateRecall)(id, SEL, id);
static void (*gOrigDBUpdateRecall)(id, SEL, id);

static void SoulHookDMUpdateRecall(id self, SEL _cmd, id msgs) {
    if (SoulDef(kFxAntiRecall)) {
        SoulLog(@"anti-recall: SOIMDataManager blocked count=%lu", (unsigned long)[msgs count]);
        return;
    }
    if (gOrigDMUpdateRecall) gOrigDMUpdateRecall(self, _cmd, msgs);
}

static void SoulHookDBUpdateRecall(id self, SEL _cmd, id msgs) {
    if (SoulDef(kFxAntiRecall)) {
        SoulLog(@"anti-recall: SOIMDBManager blocked count=%lu", (unsigned long)[msgs count]);
        return;
    }
    if (gOrigDBUpdateRecall) gOrigDBUpdateRecall(self, _cmd, msgs);
}

static void (*gOrigPCUpdateInChatRecall)(id, SEL, id, id);
static void (*gOrigGCRecallMsg)(id, SEL, id);
static BOOL gAntiRecallPC = NO, gAntiRecallGC = NO, gAntiRecallBadge = NO;

/* 私聊：撤回消息到达后，把聊天内模型改成「已撤回」提示的地方。
   拦掉它就等于不把原消息替换成撤回提示。 */
/* ===== 防撤回「已拦截」角标 ===== */

static NSMutableSet<NSString *> *gRecallBlockedIds = nil;
static NSLock *gRecallBlockedLock = nil;

static void SoulRecallStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecallBlockedIds = [NSMutableSet set];
        NSDictionary *rd = [NSDictionary dictionaryWithContentsOfFile:SoulFXPath(@"recall.plist")];
        id saved = rd[kRecallBlockedKey] ?: rd[kLegacyRecallBlockedKey];
        if ([saved isKindOfClass:[NSArray class]]) {
            for (id x in (NSArray *)saved)
                if ([x isKindOfClass:[NSString class]] && [(NSString *)x length])
                    [gRecallBlockedIds addObject:x];
        }
        gRecallBlockedLock = [NSLock new];
    });
}

/* 拦截记录落盘：重启后角标仍在（消息本体因拦了 DB 更新而保留） */
static void SoulRecallPersist(void) {
    if (!gRecallBlockedIds) return;
    [@{kRecallBlockedKey: [gRecallBlockedIds allObjects]} writeToFile:SoulFXPath(@"recall.plist") atomically:YES];
}

static NSString *SoulMsgIdOf(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]])
        return [obj description];
    SEL sels[4] = { NSSelectorFromString(@"msgId"), NSSelectorFromString(@"messageId"),
                    NSSelectorFromString(@"msgID"), NSSelectorFromString(@"msgid") };
    for (int i = 0; i < 4; i++) {
        if (![obj respondsToSelector:sels[i]]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(obj, sels[i]);
        if (v && v != [NSNull null]) return [v description];
    }
    return nil;
}

/* layout / cell / model 上层层取 message，再取 msgId */
static NSString *SoulRecallMsgId(id obj) {
    if (!obj) return nil;
    NSString *mid = SoulMsgIdOf(obj);
    if (mid.length) return mid;
    SEL sels[8] = { NSSelectorFromString(@"message"), NSSelectorFromString(@"layout"),
                    NSSelectorFromString(@"msgLayout"), NSSelectorFromString(@"messageLayout"),
                    NSSelectorFromString(@"model"), NSSelectorFromString(@"messageModel"),
                    NSSelectorFromString(@"msgModel"), NSSelectorFromString(@"msg") };
    for (int i = 0; i < 8; i++) {
        if (![obj respondsToSelector:sels[i]]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(obj, sels[i]);
        mid = SoulMsgIdOf(v);
        if (mid.length) return mid;
        if (v && [v respondsToSelector:NSSelectorFromString(@"message")]) {
            id m = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"message"));
            mid = SoulMsgIdOf(m);
            if (mid.length) return mid;
        }
    }
    return nil;
}

static void SoulRecallMarkBlocked(id obj) {
    SoulRecallStore();
    NSString *mid = SoulRecallMsgId(obj);
    if (!mid.length) return;
    [gRecallBlockedLock lock];
    if (gRecallBlockedIds.count > 400) [gRecallBlockedIds removeAllObjects];
    [gRecallBlockedIds addObject:mid];
    SoulRecallPersist();
    [gRecallBlockedLock unlock];
    SoulLog(@"anti-recall: mark blocked id=%@ cls=%@", mid, NSStringFromClass([obj class]));
}

static BOOL SoulRecallIsBlocked(id obj) {
    SoulRecallStore();
    NSString *mid = SoulRecallMsgId(obj);
    if (!mid.length) return NO;
    [gRecallBlockedLock lock];
    BOOL r = [gRecallBlockedIds containsObject:mid];
    [gRecallBlockedLock unlock];
    return r;
}

static const NSInteger kSoulRecallBadgeTag = 0x534C5242; /* 'SLRB' */

/* 从 cell 上取布局对象（用于把角标贴到气泡下方） */
static id SoulCellLayout(UIView *cell) {
    SEL sels[3] = { NSSelectorFromString(@"msgLayout"), NSSelectorFromString(@"layout"),
                    NSSelectorFromString(@"messageLayout") };
    for (int i = 0; i < 3; i++) {
        if (![cell respondsToSelector:sels[i]]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(cell, sels[i]);
        if (v) return v;
    }
    return nil;
}

static const CGFloat kSoulRecallBadgeH = 11.0;

/* 找 cell 里的气泡视图（SOChatBubbleView），角标要贴它的下边 */
static UIView *SoulBubbleView(UIView *cell) {
    UIView *cv = cell;
    if ([cell isKindOfClass:[UITableViewCell class]]) cv = ((UITableViewCell *)cell).contentView;
    else if ([cell isKindOfClass:[UICollectionViewCell class]]) cv = ((UICollectionViewCell *)cell).contentView;
    UIView *best = nil;
    for (UIView *sv in cv.subviews) {
        NSString *cn = NSStringFromClass([sv class]);
        if ([cn rangeOfString:@"Bubble"].location == NSNotFound) continue;
        if (sv.bounds.size.width <= 1.0 || sv.bounds.size.height <= 1.0) continue;
        if (!best || sv.bounds.size.width > best.bounds.size.width) best = sv;
    }
    return best;
}

static void SoulApplyRecallBadge(UIView *cell, id layout, BOOL blocked) {
    if (!cell) return;
    UIView *old = [cell viewWithTag:kSoulRecallBadgeTag];
    if (!blocked) {
        if (old) { [old removeFromSuperview]; SoulLog(@"anti-recall: badge removed cell=%@", NSStringFromClass([cell class])); }
        return;
    }
    UILabel *l = (UILabel *)old;
    if (!l) {
        l = [[UILabel alloc] init];
        l.tag = kSoulRecallBadgeTag;
        l.text = @"已拦截撤回";
        l.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
        l.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.50]
                : [UIColor colorWithWhite:0.0 alpha:0.38];
        }];
        l.backgroundColor = [UIColor clearColor];
        l.textAlignment = NSTextAlignmentLeft;
        l.layer.cornerRadius = 6;
        l.layer.masksToBounds = YES;
        l.userInteractionEnabled = NO;
        l.autoresizingMask = UIViewAutoresizingNone;
        [cell addSubview:l];
    }
    /* 每次布局都重算位置：layoutSubviews 早期 cell 高度可能还没定，之后要能纠正 */
    CGFloat h = kSoulRecallBadgeH, w = 100;
    CGFloat bx = 70, by = cell.bounds.size.height - h - 2;
    UIView *bubble = SoulBubbleView(cell);
    if (bubble) {
        CGRect bf = [bubble convertRect:bubble.bounds toView:cell];
        bx = bf.origin.x;
        by = CGRectGetMaxY(bf) + 1;
    }
    if (!bubble && by + h > cell.bounds.size.height - 1) by = cell.bounds.size.height - h - 1;
    if (bx < 4) bx = 4;
    if (bx + w > cell.bounds.size.width - 4) bx = cell.bounds.size.width - w - 4;
    CGRect f = CGRectMake(bx, by, w, h);
    if (!CGRectEqualToRect(l.frame, f)) {
        SoulLog(@"anti-recall: badge geo cellH=%.1f bubble=%@ -> (%.1f,%.1f)",
                cell.bounds.size.height, bubble ? NSStringFromCGRect([bubble convertRect:bubble.bounds toView:cell]) : @"nil", bx, by);
        l.frame = f;
    }
}

/* 立刻扫描当前可见 cell 贴角标（撤回到达时消息已在屏上） */
static void SoulRefreshRecallBadges(void) {
    UIWindow *win = SoulKeyWindow();
    if (!win) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
    while (stack.count) {
        UIView *v = [stack lastObject]; [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) {
            for (UITableViewCell *c in ((UITableView *)v).visibleCells)
                SoulApplyRecallBadge(c, SoulCellLayout(c), SoulRecallIsBlocked(c));
        } else if ([v isKindOfClass:[UICollectionView class]]) {
            for (UICollectionViewCell *c in ((UICollectionView *)v).visibleCells)
                SoulApplyRecallBadge(c, SoulCellLayout(c), SoulRecallIsBlocked(c));
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
}

static BOOL SoulSkipGroup(NSString *g);
static void (*gOrigDisplayWillCell)(id, SEL, id, id, id);
static void (*gOrigDisplayOnCell)(id, SEL, id, id, id);
static void SoulInstallRecallCellLayoutHook(void);

static void SoulHookDisplayWillCell(id self, SEL _cmd, id dc, id cell, id layout) {
    if (gOrigDisplayWillCell) gOrigDisplayWillCell(self, _cmd, dc, cell, layout);
    SoulInstallRecallCellLayoutHook();
    BOOL b = SoulDef(kFxAntiRecall) && SoulRecallIsBlocked(layout);
    if (b) SoulLog(@"anti-recall: badge shown cell=%@ id=%@", NSStringFromClass([cell class]), SoulRecallMsgId(layout));
    SoulApplyRecallBadge(cell, layout, b);
    if (b) {
        __weak UIView *wc = cell; __weak id wl = layout;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *c = wc; id ly = wl;
            if (c && SoulDef(kFxAntiRecall) && SoulRecallIsBlocked(ly)) SoulApplyRecallBadge(c, ly, YES);
        });
    }
}
static void SoulHookDisplayOnCell(id self, SEL _cmd, id dc, id cell, id layout) {
    if (gOrigDisplayOnCell) gOrigDisplayOnCell(self, _cmd, dc, cell, layout);
    SoulApplyRecallBadge(cell, layout, SoulDef(kFxAntiRecall) && SoulRecallIsBlocked(layout));
}

/* 跟随 cell 布局自动重贴角标：滚动/刷新/复用时不会丢 */
static void (*gOrigRecallCellLayout)(id, SEL);
static BOOL gAntiRecallCellL = NO;
static Class gRecallCellLayoutClass = nil;
static void SoulHookRecallCellLayout(id self, SEL _cmd) {
    if (gOrigRecallCellLayout) {
        gOrigRecallCellLayout(self, _cmd);
    } else if (gRecallCellLayoutClass) {
        Class sup = class_getSuperclass(gRecallCellLayoutClass);
        Method m = sup ? class_getInstanceMethod(sup, _cmd) : NULL;
        IMP imp = m ? method_getImplementation(m) : NULL;
        if (imp) ((void (*)(id, SEL))imp)(self, _cmd);
    }
    if (!gAntiRecallBadge || !gRecallBlockedIds) return;
    if (!SoulDef(kFxAntiRecall)) return;
    NSString *cn = NSStringFromClass([self class]);
    if ([cn rangeOfString:@"Message"].location == NSNotFound) return;
    id layout = SoulCellLayout(self);
    if (!layout) return;
    SoulApplyRecallBadge(self, layout, SoulRecallIsBlocked(layout));
}
/* 类可能启动后才注册，故惰性安装。该类自身没实现 layoutSubviews，就给它加一个，
   hook 里显式调用父类实现，避免误改 UIKit 的继承实现。 */
static void SoulInstallRecallCellLayoutHook(void) {
    if (gAntiRecallCellL) return;
    Class c = objc_getClass("SOChatTextMessageTableViewCell");
    if (!c) return;
    SEL sel = NSSelectorFromString(@"layoutSubviews");
    BOOL own = SoulClassImplements(c, sel);
    if (own) {
        SoulInstallMethodHook(c, sel, (IMP)SoulHookRecallCellLayout, (IMP *)&gOrigRecallCellLayout);
        if (!gOrigRecallCellLayout) return;
    } else {
        if (!class_addMethod(c, sel, (IMP)SoulHookRecallCellLayout, "v@:")) return;
        gOrigRecallCellLayout = NULL;
    }
    gRecallCellLayoutClass = c;
    gAntiRecallCellL = YES;
    SoulLog(@"anti-recall: cell layout hook installed own=%d", own);
}

static void SoulInstallRecallBadgeHook(void) {
    if (gAntiRecallBadge) return;
    Class c = objc_getClass("SOPCMessageDisplayCenter");
    if (!c) return;
    SoulInstallMethodHook(c, NSSelectorFromString(@"displayCenter:willDisplayCell:withLayout:"),
                          (IMP)SoulHookDisplayWillCell, (IMP *)&gOrigDisplayWillCell);
    SoulInstallMethodHook(c, NSSelectorFromString(@"displayCenter:onDisplayCell:withLayout:"),
                          (IMP)SoulHookDisplayOnCell, (IMP *)&gOrigDisplayOnCell);
    if (gOrigDisplayWillCell || gOrigDisplayOnCell) {
        gAntiRecallBadge = YES;
        SoulLog(@"anti-recall: badge hook installed (will=%d on=%d)",
                gOrigDisplayWillCell != NULL, gOrigDisplayOnCell != NULL);
    }
    SoulInstallRecallCellLayoutHook();
}

static void SoulRecallKickRefresh(id manager, id model) {
    id dc = nil;
    SEL dcSel = NSSelectorFromString(@"displayCenter");
    @try { if ([manager respondsToSelector:dcSel]) dc = ((id (*)(id, SEL))objc_msgSend)(manager, dcSel); }
    @catch (__unused NSException *e) {}
    if (dc && [dc respondsToSelector:NSSelectorFromString(@"reloadMsgLayout:")]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(dc, NSSelectorFromString(@"reloadMsgLayout:"), model); }
        @catch (__unused NSException *e) {}
    }
    if ([NSThread isMainThread]) SoulRefreshRecallBadges();
    else dispatch_async(dispatch_get_main_queue(), ^{ SoulRefreshRecallBadges(); });
}

static void SoulHookPCUpdateInChatRecall(id self, SEL _cmd, id model, id recalMsg) {
    if (SoulDef(kFxAntiRecall)) {
        NSString *mid = nil;
        @try { mid = [recalMsg valueForKey:@"msgId"]; } @catch (__unused NSException *e) {}
        SoulLog(@"anti-recall: private-chat recall blocked msgId=%@", mid ?: @"?");
        SoulRecallMarkBlocked(model);
        SoulRecallMarkBlocked(recalMsg);
        SoulRecallKickRefresh(self, model);
        return;
    }
    if (gOrigPCUpdateInChatRecall) gOrigPCUpdateInChatRecall(self, _cmd, model, recalMsg);
}

/* 群聊撤回 */
static void SoulHookGCRecallMsg(id self, SEL _cmd, id msg) {
    if (SoulDef(kFxAntiRecall)) {
        SoulLog(@"anti-recall: group-chat recall blocked");
        return;
    }
    if (gOrigGCRecallMsg) gOrigGCRecallMsg(self, _cmd, msg);
}

static void SoulInstallAntiRecallHooks(void) {
    if (!gOrigDMUpdateRecall) {
        Class dm = objc_getClass("SOIMDataManager");
        if (dm) {
            SoulInstallMethodHook(dm, NSSelectorFromString(@"updateC2CRecallMsgs:"), (IMP)SoulHookDMUpdateRecall, (IMP *)&gOrigDMUpdateRecall);
            SoulLog(@"anti-recall: SOIMDataManager hooked=%d", gOrigDMUpdateRecall != NULL);
        }
    }
    if (!gOrigDBUpdateRecall) {
        Class db = objc_getClass("SOIMDBManager");
        if (db) {
            SoulInstallMethodHook(db, NSSelectorFromString(@"updateC2CRecallMsgs:"), (IMP)SoulHookDBUpdateRecall, (IMP *)&gOrigDBUpdateRecall);
            SoulLog(@"anti-recall: SOIMDBManager hooked=%d", gOrigDBUpdateRecall != NULL);
        }
    }
    if (!gAntiRecallPC) {
        Class pc = objc_getClass("SOPrivateChatIMManager");
        if (pc) {
            SoulInstallMethodHook(pc, NSSelectorFromString(@"updateInChatMessageModel:withRecalMsg:"),
                                  (IMP)SoulHookPCUpdateInChatRecall, (IMP *)&gOrigPCUpdateInChatRecall);
            if (gOrigPCUpdateInChatRecall) { gAntiRecallPC = YES;
                SoulLog(@"anti-recall: SOPrivateChatIMManager updateInChatMessageModel hooked"); }
        } else {
            SoulLog(@"anti-recall: SOPrivateChatIMManager NOT FOUND");
        }
    }
    if (!gAntiRecallGC) {
        Class gc = objc_getClass("SOGCMessageManager");
        if (gc) {
            SoulInstallMethodHook(gc, NSSelectorFromString(@"handleRecallMessageWith:"),
                                  (IMP)SoulHookGCRecallMsg, (IMP *)&gOrigGCRecallMsg);
            if (gOrigGCRecallMsg) { gAntiRecallGC = YES;
                SoulLog(@"anti-recall: SOGCMessageManager handleRecallMessageWith hooked"); }
        }
    }
    SoulInstallRecallBadgeHook();
}

static void SoulInstallAntiRecallHooksRetry(int n) {
    SoulInstallAntiRecallHooks();
    if ((gOrigDMUpdateRecall && gOrigDBUpdateRecall && gAntiRecallPC && gAntiRecallGC && gAntiRecallBadge) || n <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulInstallAntiRecallHooksRetry(n - 1); });
}

#pragma mark - 禁止上报「正在输入」（sendStart/EndInputIMMessage）

static void (*gOrigSendStartInput)(id, SEL, id);
static void (*gOrigSendEndInput)(id, SEL, id);

static void SoulHookSendStartInput(id self, SEL _cmd, id to) {
    if (SoulDef(kFxBlockInput)) { SoulLog(@"block-input: sendStartInput suppressed to=%@", to); return; }
    if (gOrigSendStartInput) gOrigSendStartInput(self, _cmd, to);
}
static void SoulHookSendEndInput(id self, SEL _cmd, id to) {
    if (SoulDef(kFxBlockInput)) { return; }
    if (gOrigSendEndInput) gOrigSendEndInput(self, _cmd, to);
}

static void SoulInstallInputHooks(void) {
    Class sender = objc_getClass("SOPCMessageSender");
    if (!sender) { SoulLog(@"block-input: SOPCMessageSender NOT FOUND"); return; }
    SoulInstallMethodHook(sender, NSSelectorFromString(@"sendStartInputIMMessageTo:"), (IMP)SoulHookSendStartInput, (IMP *)&gOrigSendStartInput);
    SoulInstallMethodHook(sender, NSSelectorFromString(@"sendEndInputIMMessageTo:"), (IMP)SoulHookSendEndInput, (IMP *)&gOrigSendEndInput);
    SoulLog(@"block-input: input hooks installed");
}

#pragma mark - 限制解除（礼仪分 / 送礼聊天限制）

static BOOL (*gOrigSocMsgNeedLimit)(id, SEL, id);
static BOOL (*gOrigSocForbidCall)(id, SEL, id);
static BOOL (*gOrigSocSent24h)(id, SEL, id);
static BOOL (*gOrigSocCanNotSend)(id, SEL);
static BOOL (*gOrigSocForbidPic)(id, SEL);
static BOOL (*gOrigSocForbidCallProp)(id, SEL);
static BOOL (*gOrigSocCreateLimit)(id, SEL);
static BOOL SoulGiftLimitFree(void) {
    return SoulDef(kFxGiftFree);
}

static BOOL (*gOrigPayCanSendV2)(id, SEL, id);
static BOOL (*gOrigPayCanSendV3)(id, SEL, id);
static BOOL (*gOrigPayIsLimitV2)(id, SEL);
static BOOL (*gOrigPayIsLimitV3)(id, SEL);

static BOOL SoulHookSocMsgNeedLimit(id self, SEL _cmd, id msg) {
    if (SoulDef(kFxEtiquetteFree)) { SoulLog(@"etiquette: checkMsgIsNeedLimit -> NO"); return NO; }
    return gOrigSocMsgNeedLimit ? gOrigSocMsgNeedLimit(self, _cmd, msg) : NO;
}
static BOOL SoulHookSocForbidCall(id self, SEL _cmd, id view) {
    if (SoulDef(kFxEtiquetteFree)) return NO;
    return gOrigSocForbidCall ? gOrigSocForbidCall(self, _cmd, view) : NO;
}
static BOOL SoulHookSocSent24h(id self, SEL _cmd, id sid) {
    if (SoulDef(kFxEtiquetteFree)) return YES;
    return gOrigSocSent24h ? gOrigSocSent24h(self, _cmd, sid) : YES;
}
static BOOL SoulHookSocCanNotSend(id self, SEL _cmd) {
    if (SoulDef(kFxEtiquetteFree)) return NO;
    return gOrigSocCanNotSend ? gOrigSocCanNotSend(self, _cmd) : NO;
}
static BOOL SoulHookSocForbidPic(id self, SEL _cmd) {
    if (SoulDef(kFxEtiquetteFree)) return NO;
    return gOrigSocForbidPic ? gOrigSocForbidPic(self, _cmd) : NO;
}
static BOOL SoulHookSocForbidCallProp(id self, SEL _cmd) {
    if (SoulDef(kFxEtiquetteFree)) return NO;
    return gOrigSocForbidCallProp ? gOrigSocForbidCallProp(self, _cmd) : NO;
}
static BOOL SoulHookSocCreateLimit(id self, SEL _cmd) {
    if (SoulDef(kFxEtiquetteFree)) return NO;
    return gOrigSocCreateLimit ? gOrigSocCreateLimit(self, _cmd) : NO;
}
static BOOL SoulHookPayCanSendV2(id self, SEL _cmd, id a) {
    if (SoulGiftLimitFree()) { SoulLog(@"gift: canSend V2 -> YES"); return YES; }
    return gOrigPayCanSendV2 ? gOrigPayCanSendV2(self, _cmd, a) : YES;
}
static BOOL SoulHookPayCanSendV3(id self, SEL _cmd, id a) {
    if (SoulGiftLimitFree()) { SoulLog(@"gift: canSend V3 -> YES"); return YES; }
    return gOrigPayCanSendV3 ? gOrigPayCanSendV3(self, _cmd, a) : YES;
}
static BOOL SoulHookPayIsLimitV2(id self, SEL _cmd) {
    if (SoulGiftLimitFree()) return NO;
    return gOrigPayIsLimitV2 ? gOrigPayIsLimitV2(self, _cmd) : NO;
}
static BOOL SoulHookPayIsLimitV3(id self, SEL _cmd) {
    if (SoulGiftLimitFree()) return NO;
    return gOrigPayIsLimitV3 ? gOrigPayIsLimitV3(self, _cmd) : NO;
}

static BOOL gLimitSocDone = NO, gLimitGmDone = NO, gLimitPayDone = NO;

static void SoulInstallLimitHooks(void) {
    if (!gLimitSocDone) {
        Class soc = objc_getClass("SOPCSocialScoreLimitHandler");
        if (soc) {
            SoulInstallMethodHook(soc, NSSelectorFromString(@"checkMsgIsNeedLimit:"), (IMP)SoulHookSocMsgNeedLimit, (IMP *)&gOrigSocMsgNeedLimit);
            SoulInstallMethodHook(soc, NSSelectorFromString(@"checkIsforbidCallOn:"), (IMP)SoulHookSocForbidCall, (IMP *)&gOrigSocForbidCall);
            SoulInstallMethodHook(soc, NSSelectorFromString(@"checkUserHasSucceesSendMsgIn24Hours:"), (IMP)SoulHookSocSent24h, (IMP *)&gOrigSocSent24h);
            gLimitSocDone = YES;
            SoulLog(@"limit: social score handler hooked");
        }
    }
    if (!gLimitGmDone) {
        Class gm = objc_getClass("SOPCSocialGraceScoreModel");
        if (gm) {
            SoulInstallMethodHook(gm, NSSelectorFromString(@"canNotSendBeforeReply"), (IMP)SoulHookSocCanNotSend, (IMP *)&gOrigSocCanNotSend);
            SoulInstallMethodHook(gm, NSSelectorFromString(@"forbidPic"), (IMP)SoulHookSocForbidPic, (IMP *)&gOrigSocForbidPic);
            SoulInstallMethodHook(gm, NSSelectorFromString(@"forbidCall"), (IMP)SoulHookSocForbidCallProp, (IMP *)&gOrigSocForbidCallProp);
            SoulInstallMethodHook(gm, NSSelectorFromString(@"createSessionLimit"), (IMP)SoulHookSocCreateLimit, (IMP *)&gOrigSocCreateLimit);
            gLimitGmDone = YES;
            SoulLog(@"limit: social grace model hooked");
        }
    }
    if (!gLimitPayDone) {
        Class pay = objc_getClass("_TtC15SoulPrivateChat23SOPCLimitPaymentManager");
        if (pay) {
            SoulInstallMethodHook(pay, NSSelectorFromString(@"canSendMessage_limitPayment_V2:"), (IMP)SoulHookPayCanSendV2, (IMP *)&gOrigPayCanSendV2);
            SoulInstallMethodHook(pay, NSSelectorFromString(@"canSendMessage_limitPayment_V3:"), (IMP)SoulHookPayCanSendV3, (IMP *)&gOrigPayCanSendV3);
            SoulInstallMethodHook(pay, NSSelectorFromString(@"isLimitPaymentV2"), (IMP)SoulHookPayIsLimitV2, (IMP *)&gOrigPayIsLimitV2);
            SoulInstallMethodHook(pay, NSSelectorFromString(@"isLimitPaymentV3"), (IMP)SoulHookPayIsLimitV3, (IMP *)&gOrigPayIsLimitV3);
            gLimitPayDone = YES;
            SoulLog(@"limit: payment manager hooked");
        }
    }
}

static void SoulInstallLimitHooksRetry(int n) {
    if (gLimitSocDone && gLimitGmDone && gLimitPayDone) return;
    SoulInstallLimitHooks();
    if (gLimitSocDone && gLimitGmDone && gLimitPayDone) return;
    if (n <= 0) {
        SoulLog(@"limit: retries exhausted soc=%d gm=%d pay=%d", (int)gLimitSocDone, (int)gLimitGmDone, (int)gLimitPayDone);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulInstallLimitHooksRetry(n - 1); });
}

#pragma mark - 超2分钟也能撤回自己消息

/* 长按菜单里「撤回」只在 消息时间 距今 <= 120s 时才加入。
   addMenuItemsWithMsg:cell:recognizer: 里用 [msg timestamp]/1000 与 now 比较。
   做法：在构造菜单期间，把「自己发的」那条消息的 timestamp 临时伪装成当前时间。 */
static BOOL gOwnRecallFake = NO;
static __unsafe_unretained id gOwnRecallFakeMsg = nil;
static NSMutableSet *gOwnRecallHookedClasses = nil;

static long long (*gOrigMsgTimestamp)(id, SEL);
static long long SoulHookMsgTimestamp(id self, SEL _cmd) {
    if (gOwnRecallFake && self == gOwnRecallFakeMsg) {
        return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    }
    return gOrigMsgTimestamp ? gOrigMsgTimestamp(self, _cmd) : 0;
}

static void (*gOrigMenuAddItems)(id, SEL, id, id, id);
static void SoulHookMenuAddItems(id self, SEL _cmd, id msg, id cell, id recognizer) {
    BOOL mine = NO;
    if (msg) {
        SEL fm = NSSelectorFromString(@"fromMine");
        @try { if ([msg respondsToSelector:fm]) mine = ((BOOL (*)(id, SEL))objc_msgSend)(msg, fm); }
        @catch (__unused NSException *e) {}
    }
    if (!SoulDefOn(kFxOwnRecall, YES)) mine = NO;
    if (mine) {
        if (!gOwnRecallHookedClasses) gOwnRecallHookedClasses = [NSMutableSet set];
        Class mc = [msg class];
        NSString *cn = NSStringFromClass(mc);
        if (mc && cn && ![gOwnRecallHookedClasses containsObject:cn] &&
            class_getInstanceMethod(mc, NSSelectorFromString(@"timestamp"))) {
            SoulInstallMethodHook(mc, NSSelectorFromString(@"timestamp"),
                                  (IMP)SoulHookMsgTimestamp, (IMP *)&gOrigMsgTimestamp);
            [gOwnRecallHookedClasses addObject:cn];
            SoulLog(@"own-recall: timestamp hook installed on %@", cn);
        }
        gOwnRecallFakeMsg = msg;
        gOwnRecallFake = YES;
        if (gOrigMenuAddItems) gOrigMenuAddItems(self, _cmd, msg, cell, recognizer);
        gOwnRecallFake = NO;
        gOwnRecallFakeMsg = nil;
        SoulLog(@"own-recall: menu rebuilt with fresh time cls=%@", cn ?: @"?");
        return;
    }
    if (gOrigMenuAddItems) gOrigMenuAddItems(self, _cmd, msg, cell, recognizer);
}

static BOOL gOwnRecallMenuDone = NO;
static void SoulInstallOwnRecallHooks(void) {
    if (gOwnRecallMenuDone) return;
    Class mh = objc_getClass("SOPCMenuHandler");
    if (!mh) return;
    SoulInstallMethodHook(mh, NSSelectorFromString(@"addMenuItemsWithMsg:cell:recognizer:"),
                          (IMP)SoulHookMenuAddItems, (IMP *)&gOrigMenuAddItems);
    if (gOrigMenuAddItems) {
        gOwnRecallMenuDone = YES;
        SoulLog(@"own-recall: menu hook installed");
    }
}
static void SoulInstallOwnRecallHooksRetry(int n) {
    SoulInstallOwnRecallHooks();
    if (gOwnRecallMenuDone || n <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulInstallOwnRecallHooksRetry(n - 1); });
}

#pragma mark - 奇遇铃「送礼才能私聊」拦截：二进制补丁

#define kLoveBellInsnVaddr 0x100dce15cULL
#define kLoveBellOrigInsn  0x34000b48u
#define kLoveBellNewInsn   0x1400005au

static BOOL gLoveBellPatched = NO;
static uint32_t *gLoveBellInsn = NULL;

static void *SoulMainImageBase(void) {
    Dl_info di;
    Class c = objc_getClass("SOOtherHomePageFuncManager");
    if (c) {
        IMP imp = class_getMethodImplementation(c, NSSelectorFromString(@"initWithVC:"));
        if (imp && dladdr((void *)imp, &di) && di.dli_fbase) return di.dli_fbase;
    }
    return NULL;
}

static uint32_t *SoulLoveBellInsnAddr(void) {
    if (gLoveBellInsn) return gLoveBellInsn;
    void *base = SoulMainImageBase();
    if (!base) return NULL;
    gLoveBellInsn = (uint32_t *)((uint8_t *)base + (kLoveBellInsnVaddr - 0x100000000ULL));
    return gLoveBellInsn;
}

static BOOL SoulMakePageWritable(uint32_t *insn) {
    uintptr_t page = (uintptr_t)insn & ~(uintptr_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { SoulLog(@"lovebell-patch: vm_protect RW failed kr=%d", (int)kr); return NO; }
    return YES;
}

static void SoulMakePageExecutable(uint32_t *insn) {
    uintptr_t page = (uintptr_t)insn & ~(uintptr_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) SoulLog(@"lovebell-patch: vm_protect RX failed kr=%d", (int)kr);
}

static void SoulApplyLoveBellPatch(void) {
    if (gLoveBellPatched) return;
    uint32_t *insn = SoulLoveBellInsnAddr();
    if (!insn) { SoulLog(@"lovebell-patch: main image base not found"); return; }
    if (!SoulMakePageWritable(insn)) return;
    uint32_t orig = *insn;
    if (orig != kLoveBellOrigInsn) {
        SoulLog(@"lovebell-patch: unexpected insn 0x%08x (want 0x%08x), skip", orig, kLoveBellOrigInsn);
        SoulMakePageExecutable(insn);
        return;
    }
    uint32_t nv = kLoveBellNewInsn;
    memcpy(insn, &nv, 4);
    sys_icache_invalidate(insn, 4);
    SoulMakePageExecutable(insn);
    gLoveBellPatched = YES;
    SoulLog(@"lovebell-patch: applied at %p", insn);
}

static void SoulRevertLoveBellPatch(void) {
    if (!gLoveBellPatched || !gLoveBellInsn) return;
    if (!SoulMakePageWritable(gLoveBellInsn)) return;
    uint32_t ov = kLoveBellOrigInsn;
    memcpy(gLoveBellInsn, &ov, 4);
    sys_icache_invalidate(gLoveBellInsn, 4);
    SoulMakePageExecutable(gLoveBellInsn);
    gLoveBellPatched = NO;
    SoulLog(@"lovebell-patch: reverted");
}

static NSString *SoulSkipText(void) {
    NSString *s = [NSString stringWithContentsOfFile:SoulFXPath(@"skip.txt") encoding:NSUTF8StringEncoding error:NULL];
    if (!s.length) {
        NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/soul_skip.txt"];
        s = [NSString stringWithContentsOfFile:legacy encoding:NSUTF8StringEncoding error:NULL];
    }
    return s;
}
static BOOL SoulSkipGroup(NSString *g) {
    NSString *s = SoulSkipText();
    if (!s.length) return NO;
    NSArray *toks = [s componentsSeparatedByCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *tok in toks) if (tok.length && [tok isEqualToString:g]) return YES;
    return NO;
}

static void SoulSyncLoveBellPatch(void) {
    if (SoulDef(kFxGiftFree)) SoulApplyLoveBellPatch();
    else SoulRevertLoveBellPatch();
}

#pragma mark - 禁止上报状态（输入 / 查看主页）(kFxBlockInput)

static void (*gOrigSysHomepageSee)(id, SEL, BOOL);
static void SoulHookSysHomepageSee(id self, SEL _cmd, BOOL see) {
    if (SoulDef(kFxBlockInput)) {
        SoulLog(@"block-view: homepage-see send suppressed see=%d", (int)see);
        return;
    }
    if (gOrigSysHomepageSee) gOrigSysHomepageSee(self, _cmd, see);
}
static BOOL gBlockViewDone = NO;
static void SoulInstallBlockViewHooks(void) {
    if (gBlockViewDone) return;
    Class vc = objc_getClass("SOPrivateChatViewController");
    if (vc) {
        SoulInstallMethodHook(vc, NSSelectorFromString(@"sysToOtherCheckStrangerHomepageStateIsSee:"),
                             (IMP)SoulHookSysHomepageSee, (IMP *)&gOrigSysHomepageSee);
        gBlockViewDone = YES;
        SoulLog(@"block-view: homepage-see sender hooked");
    }
}
static void SoulInstallBlockViewHooksRetry(int n) {
    if (gBlockViewDone) return;
    SoulInstallBlockViewHooks();
    if (gBlockViewDone) return;
    if (n <= 0) { SoulLog(@"block-view: retries exhausted"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulInstallBlockViewHooksRetry(n - 1); });
}

#pragma mark - 新增批次（2026-10-08）：选择上限 / 开屏广告 / 关注列表 / 群撤回 / 已读 / 挚友 / 清通知 / 语音

// 通用重试安装：block 返回 YES 表示已装好；否则 0.5s 后重试，最多 n 次。
static void SoulRetryInstall(BOOL (^block)(void), int n) {
    if (block()) return;
    if (n <= 0) { SoulLog(@"install: retries exhausted"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulRetryInstall(block, n - 1); });
}

// —— B. 图片/视频选择数量上限解除 ——
static NSInteger (*gOrigAideMaxCount)(id, SEL);
static NSInteger SoulHookAideMaxCount(id self, SEL _cmd) {
    if (SoulDef(kFxPickerFree)) return 99;
    return gOrigAideMaxCount ? gOrigAideMaxCount(self, _cmd) : 9;
}

static NSInteger (*gOrigAlbumImgMax)(id, SEL);
static NSInteger SoulHookAlbumImgMax(id self, SEL _cmd) {
    if (SoulDef(kFxPickerFree)) return 99;
    return gOrigAlbumImgMax ? gOrigAlbumImgMax(self, _cmd) : 9;
}
static BOOL gPickerDone = NO;
static BOOL SoulInstallPickerHooks(void) {
    if (gPickerDone) return YES;
    Class aide = objc_getClass("SOAlbumPhotoJudgeSelectAide");
    if (aide) {
        SoulInstallMethodHook(aide, NSSelectorFromString(@"maxCount"), (IMP)SoulHookAideMaxCount, (IMP *)&gOrigAideMaxCount);
        SoulLog(@"picker: aide hooked");
    }
    Class alb = objc_getClass("_TtC10SOPhotoKit25SOPhotoAlbumConfiguration");
    if (alb) {
        SoulInstallMethodHook(alb, NSSelectorFromString(@"imageCountMaximum"), (IMP)SoulHookAlbumImgMax, (IMP *)&gOrigAlbumImgMax);
        SoulLog(@"picker: album config hooked");
    }
    if (aide || alb) { gPickerDone = YES; return YES; }
    return NO;
}

// —— C. 跳过开屏/启动广告 ——
static void (*gOrigShowSplash)(id, SEL, id, NSInteger, id);
static void SoulHookShowSplash(id self, SEL _cmd, id ad, NSInteger scene, id reqId) {
    if (SoulDef(kFxNoSplashAd)) { SoulLog(@"no-splash: showSpalshAd suppressed"); return; }
    if (gOrigShowSplash) gOrigShowSplash(self, _cmd, ad, scene, reqId);
}
static void (*gOrigShowLaunch)(id, SEL, NSInteger);
static void SoulHookShowLaunch(id self, SEL _cmd, NSInteger sceneAction) {
    if (SoulDef(kFxNoSplashAd)) { SoulLog(@"no-splash: showLaunchView suppressed"); return; }
    if (gOrigShowLaunch) gOrigShowLaunch(self, _cmd, sceneAction);
}
static BOOL gSplashDone = NO;
static BOOL SoulInstallSplashHooks(void) {
    if (gSplashDone) return YES;
    Class mgr = objc_getClass("SoulSplashAdManager");
    if (mgr) {
        SoulInstallMethodHook(mgr, NSSelectorFromString(@"showSpalshAd:scene:reqId:"), (IMP)SoulHookShowSplash, (IMP *)&gOrigShowSplash);
        SoulInstallMethodHook(mgr, NSSelectorFromString(@"showLaunchViewWithSceneAction:"), (IMP)SoulHookShowLaunch, (IMP *)&gOrigShowLaunch);
        gSplashDone = YES;
        SoulLog(@"no-splash: manager hooked");
        return YES;
    }
    return NO;
}

// —— D. 群聊防撤回 ——
static void (*gOrigGCHandleRecall)(id, SEL, id);
static void SoulHookGCHandleRecall(id self, SEL _cmd, id msg) {
    if (SoulDef(kFxAntiRecall)) { SoulLog(@"group-recall: blocked"); return; }
    if (gOrigGCHandleRecall) gOrigGCHandleRecall(self, _cmd, msg);
}
static BOOL gGroupRecallDone = NO;
static BOOL SoulInstallGroupRecallHooks(void) {
    if (gGroupRecallDone) return YES;
    Class mgr = objc_getClass("SOGCMessageManager");
    if (mgr) {
        SoulInstallMethodHook(mgr, NSSelectorFromString(@"handleRecallMessageWith:"), (IMP)SoulHookGCHandleRecall, (IMP *)&gOrigGCHandleRecall);
        gGroupRecallDone = YES;
        SoulLog(@"group-recall: hooked");
        return YES;
    }
    return NO;
}

// —— F. 禁止上报「已读」回执 ——
static BOOL (*gOrigCanSendIMRead)(id, SEL, id);
static BOOL SoulHookCanSendIMRead(id self, SEL _cmd, id arg) {
    if (SoulDef(kFxBlockRead)) { SoulLog(@"block-read: canSendIMRead -> NO"); return NO; }
    return gOrigCanSendIMRead ? gOrigCanSendIMRead(self, _cmd, arg) : YES;
}
static void (*gOrigSendSingleRead)(id, SEL, id, id);
static void SoulHookSendSingleRead(id self, SEL _cmd, id a, id b) {
    if (SoulDef(kFxBlockRead)) { SoulLog(@"block-read: single read suppressed"); return; }
    if (gOrigSendSingleRead) gOrigSendSingleRead(self, _cmd, a, b);
}
static void (*gOrigSendBgRead)(id, SEL, id, id);
static void SoulHookSendBgRead(id self, SEL _cmd, id a, id b) {
    if (SoulDef(kFxBlockRead)) { SoulLog(@"block-read: bg read suppressed"); return; }
    if (gOrigSendBgRead) gOrigSendBgRead(self, _cmd, a, b);
}
static BOOL gBlockReadDone = NO;
static BOOL SoulInstallBlockReadHooks(void) {
    if (gBlockReadDone) return YES;
    BOOL any = NO;
    Class mgr = objc_getClass("SOPrivateChatIMManager");
    if (mgr) {
        SoulInstallMethodHook(mgr, NSSelectorFromString(@"canSendIMRead:"), (IMP)SoulHookCanSendIMRead, (IMP *)&gOrigCanSendIMRead);
        SoulLog(@"block-read: manager hooked");
        any = YES;
    }
    Class snd = objc_getClass("SOPCMessageSender");
    if (snd) {
        SoulInstallMethodHook(snd, NSSelectorFromString(@"sendSingleReadIMMessage:to:"), (IMP)SoulHookSendSingleRead, (IMP *)&gOrigSendSingleRead);
        SoulInstallMethodHook(snd, NSSelectorFromString(@"sendBackGroundRead:to:"), (IMP)SoulHookSendBgRead, (IMP *)&gOrigSendBgRead);
        SoulLog(@"block-read: sender hooked");
        any = YES;
    }
    if (any) { gBlockReadDone = YES; return YES; }
    return NO;
}

// —— F2. 收到消息自动已读（best-effort，KVC 取 sessionId）——
static void (*gOrigDidReceiveMsgs)(id, SEL, id);
static void SoulHookDidReceiveMsgs(id self, SEL _cmd, id msgs) {
    if (gOrigDidReceiveMsgs) gOrigDidReceiveMsgs(self, _cmd, msgs);
    if (!SoulDef(kFxAutoRead)) return;
    @try {
        if (![msgs isKindOfClass:[NSArray class]]) return;
        NSMutableSet *sids = [NSMutableSet set];
        for (id m in (NSArray *)msgs) {
            id sid = nil;
            @try { sid = [m valueForKey:@"sessionId"]; } @catch (__unused NSException *e) {}
            if (!sid) { @try { sid = [m valueForKey:@"conversationId"]; } @catch (__unused NSException *e) {} }
            if (sid) [sids addObject:sid];
        }
        if (!sids.count) return;
        Class mgrCls = objc_getClass("SOPrivateChatIMManager");
        id mgr = nil;
        SEL sh = NSSelectorFromString(@"shareInstance");
        SEL sh2 = NSSelectorFromString(@"sharedInstance");
        if (mgrCls && [mgrCls respondsToSelector:sh]) mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sh);
        else if (mgrCls && [mgrCls respondsToSelector:sh2]) mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sh2);
        SEL rd = NSSelectorFromString(@"readAllMessagesWithSessionId:");
        if (mgr && [mgr respondsToSelector:rd]) {
            for (id sid in sids) ((void (*)(id, SEL, id))objc_msgSend)(mgr, rd, sid);
            SoulLog(@"auto-read: marked %lu session(s)", (unsigned long)sids.count);
        }
    } @catch (__unused NSException *e) {}
}
static BOOL gAutoReadDone = NO;
static BOOL SoulInstallAutoReadHooks(void) {
    if (gAutoReadDone) return YES;
    Class ad = objc_getClass("SOIMMsgAdapter");
    if (ad) {
        SoulInstallMethodHook(ad, NSSelectorFromString(@"didReceiveMessages:"), (IMP)SoulHookDidReceiveMsgs, (IMP *)&gOrigDidReceiveMsgs);
        gAutoReadDone = YES;
        SoulLog(@"auto-read: adapter hooked");
        return YES;
    }
    return NO;
}

// —— G. 禁止弹「挚友」邀请 ——
static void (*gOrigShowCloseFriendAlert)(id, SEL, id);
static void SoulHookShowCloseFriendAlert(id self, SEL _cmd, id arg) {
    if (SoulDef(kFxNoCloseFriend)) { SoulLog(@"no-closefriend: alert suppressed"); return; }
    if (gOrigShowCloseFriendAlert) gOrigShowCloseFriendAlert(self, _cmd, arg);
}
static BOOL gCloseFriendDone = NO;
static BOOL SoulInstallCloseFriendHooks(void) {
    if (gCloseFriendDone) return YES;
    Class vc = objc_getClass("AudioMatchChatViewController");
    if (vc) {
        SoulInstallMethodHook(vc, NSSelectorFromString(@"showAddCloseFriendAlertViewWith:"), (IMP)SoulHookShowCloseFriendAlert, (IMP *)&gOrigShowCloseFriendAlert);
        gCloseFriendDone = YES;
        SoulLog(@"no-closefriend: hooked");
        return YES;
    }
    return NO;
}

// —— E. 语音消息：跳过「解锁语音装扮」门槛（best-effort）——
static void (*gOrigUnlockVoiceWear)(id, SEL, id);
static void SoulHookUnlockVoiceWear(id self, SEL _cmd, id sender) {
    if (SoulDef(kFxVoiceUnlock)) {
        SoulLog(@"voice-unlock: auto-unlock");
        SEL h = NSSelectorFromString(@"hideUnlockVoiceContainerWithAnimation:");
        if ([self respondsToSelector:h]) ((void (*)(id, SEL, BOOL))objc_msgSend)(self, h, YES);
        return;
    }
    if (gOrigUnlockVoiceWear) gOrigUnlockVoiceWear(self, _cmd, sender);
}
static BOOL gVoiceDone = NO;
static BOOL SoulInstallVoiceHooks(void) {
    if (gVoiceDone) return YES;
    Class cell = objc_getClass("SOCPVoiceMessageCell");
    if (cell) {
        SoulInstallMethodHook(cell, NSSelectorFromString(@"unlockVoiceWearBtnClick:"), (IMP)SoulHookUnlockVoiceWear, (IMP *)&gOrigUnlockVoiceWear);
        gVoiceDone = YES;
        SoulLog(@"voice-unlock: hooked");
        return YES;
    }
    return NO;
}

// —— I. 去除青少年 / 未成年模式弹窗 ——
static void SoulRunBoolBlock(id block, BOOL value) {
    if (!block) return;
    @try { ((void (^)(BOOL))block)(value); }
    @catch (NSException *e) { SoulLog(@"teen: completion threw %@", e.reason); }
}

static void (*gOrigTeenYoungAlert)(id, SEL);
static void SoulHookTeenYoungAlert(id self, SEL _cmd) {
    if (SoulDef(kFxNoTeenPopup)) { SoulLog(@"teen: showYoungAlert suppressed"); return; }
    if (gOrigTeenYoungAlert) gOrigTeenYoungAlert(self, _cmd);
}

static void (*gOrigTeenYoungAlertDone)(id, SEL, id);
static void SoulHookTeenYoungAlertDone(id self, SEL _cmd, id done) {
    if (SoulDef(kFxNoTeenPopup)) {
        SoulLog(@"teen: showYoungAlertWithCompletion: suppressed");
        SoulRunBoolBlock(done, NO);
        return;
    }
    if (gOrigTeenYoungAlertDone) gOrigTeenYoungAlertDone(self, _cmd, done);
}

static void (*gOrigTeenYoungPopDone)(id, SEL, id);
static void SoulHookTeenYoungPopDone(id self, SEL _cmd, id done) {
    if (SoulDef(kFxNoTeenPopup)) {
        SoulLog(@"teen: showYoungPopViewWithCompletion: suppressed");
        SoulRunBoolBlock(done, NO);
        return;
    }
    if (gOrigTeenYoungPopDone) gOrigTeenYoungPopDone(self, _cmd, done);
}

static void (*gOrigTeenYoungPopDoneQ)(id, SEL, id, BOOL);
static void SoulHookTeenYoungPopDoneQ(id self, SEL _cmd, id done, BOOL useGlobalQ) {
    if (SoulDef(kFxNoTeenPopup)) {
        SoulLog(@"teen: showYoungPopViewWithCompletion:useGlobalQ: suppressed");
        SoulRunBoolBlock(done, NO);
        return;
    }
    if (gOrigTeenYoungPopDoneQ) gOrigTeenYoungPopDoneQ(self, _cmd, done, useGlobalQ);
}

static void (*gOrigTeenGuideDone)(id, SEL, id);
static void SoulHookTeenGuideDone(id self, SEL _cmd, id done) {
    if (SoulDef(kFxNoTeenPopup)) {
        SoulLog(@"teen: newTeenagerNotionGuide suppressed");
        SoulRunBoolBlock(done, NO);
        return;
    }
    if (gOrigTeenGuideDone) gOrigTeenGuideDone(self, _cmd, done);
}

static BOOL (*gOrigTeenChatAlert)(id, SEL);
static BOOL SoulHookTeenChatAlert(id self, SEL _cmd) {
    if (SoulDef(kFxNoTeenPopup)) {
        SoulLog(@"teen: private-chat teen alert suppressed");
        return NO;
    }
    return gOrigTeenChatAlert ? gOrigTeenChatAlert(self, _cmd) : NO;
}

static BOOL gTeenDone = NO;
static BOOL SoulInstallTeenHooks(void) {
    if (gTeenDone) return YES;
    Class square = objc_getClass("SOMainSquareViewController");
    if (square) {
        SoulInstallMethodHook(square, NSSelectorFromString(@"showYoungAlert"),
                              (IMP)SoulHookTeenYoungAlert, (IMP *)&gOrigTeenYoungAlert);
        SoulInstallMethodHook(square, NSSelectorFromString(@"showYoungAlertWithCompletion:"),
                              (IMP)SoulHookTeenYoungAlertDone, (IMP *)&gOrigTeenYoungAlertDone);
        SoulInstallMethodHook(square, NSSelectorFromString(@"showYoungPopViewWithCompletion:"),
                              (IMP)SoulHookTeenYoungPopDone, (IMP *)&gOrigTeenYoungPopDone);
        SoulInstallMethodHook(square, NSSelectorFromString(@"showYoungPopViewWithCompletion:useGlobalQ:"),
                              (IMP)SoulHookTeenYoungPopDoneQ, (IMP *)&gOrigTeenYoungPopDoneQ);
        SoulInstallMethodHook(square, NSSelectorFromString(@"showNewTeenagerNotionGuideWithCompletion:"),
                              (IMP)SoulHookTeenGuideDone, (IMP *)&gOrigTeenGuideDone);
    }
    Class chat = objc_getClass("SOPrivateChatViewController");
    if (chat) {
        SoulInstallMethodHook(chat, NSSelectorFromString(@"showTeenagerModeAlert"),
                              (IMP)SoulHookTeenChatAlert, (IMP *)&gOrigTeenChatAlert);
    }
    if (square || chat) {
        gTeenDone = YES;
        SoulLog(@"teen: hooks installed");
        return YES;
    }
    return NO;
}

// —— N. 去除广告（推荐流 / 广场 / 群聊 / 评论 / 搜索 / 横幅 / 悬浮广告） ——
static BOOL (*gOrigSquareAdEnabled)(id, SEL);
static BOOL SoulHookSquareAdEnabled(id self, SEL _cmd) {
    if (SoulDef(kFxNoAds)) return NO;
    return gOrigSquareAdEnabled ? gOrigSquareAdEnabled(self, _cmd) : NO;
}

static BOOL (*gOrigRecAdEnabled)(id, SEL);
static BOOL SoulHookRecAdEnabled(id self, SEL _cmd) {
    if (SoulDef(kFxNoAds)) return NO;
    return gOrigRecAdEnabled ? gOrigRecAdEnabled(self, _cmd) : NO;
}

static BOOL (*gOrigGCAdAutoDisplay)(id, SEL);
static BOOL SoulHookGCAdAutoDisplay(id self, SEL _cmd) {
    if (SoulDef(kFxNoAds)) return NO;
    return gOrigGCAdAutoDisplay ? gOrigGCAdAutoDisplay(self, _cmd) : NO;
}

static void (*gOrigCommentAdRequest)(id, SEL, id);
static void SoulHookCommentAdRequest(id self, SEL _cmd, id done) {
    if (SoulDef(kFxNoAds)) {
        SoulLog(@"ads: comment request skipped");
        if (done) {
            @try { ((void (^)(BOOL, id))done)(NO, nil); }
            @catch (NSException *e) { SoulLog(@"ads: comment completion threw %@", e.reason); }
        }
        return;
    }
    if (gOrigCommentAdRequest) gOrigCommentAdRequest(self, _cmd, done);
}

static void (*gOrigSearchAdRequest)(id, SEL, id, id, id);
static void SoulHookSearchAdRequest(id self, SEL _cmd, id request, id success, id failure) {
    if (SoulDef(kFxNoAds)) { SoulLog(@"ads: search request skipped"); return; }
    if (gOrigSearchAdRequest) gOrigSearchAdRequest(self, _cmd, request, success, failure);
}

static void (*gOrigBannerDidMove)(id, SEL);
static void SoulHookBannerDidMove(id self, SEL _cmd) {
    if (gOrigBannerDidMove) gOrigBannerDidMove(self, _cmd);
    if (SoulDef(kFxNoAds)) ((UIView *)self).hidden = YES;
}

static void (*gOrigSuspendShowAd)(id, SEL);
static void SoulHookSuspendShowAd(id self, SEL _cmd) {
    if (SoulDef(kFxNoAds)) { SoulLog(@"ads: suspend ad view suppressed"); return; }
    if (gOrigSuspendShowAd) gOrigSuspendShowAd(self, _cmd);
}

static void (*gOrigSuspendShowView)(id, SEL);
static void SoulHookSuspendShowView(id self, SEL _cmd) {
    if (SoulDef(kFxNoAds)) { SoulLog(@"ads: suspend view suppressed"); return; }
    if (gOrigSuspendShowView) gOrigSuspendShowView(self, _cmd);
}

static void (*gOrigSuspendFirstFloat)(id, SEL, id);
static void SoulHookSuspendFirstFloat(id self, SEL _cmd, id ad) {
    if (SoulDef(kFxNoAds)) { SoulLog(@"ads: first float ad suppressed"); return; }
    if (gOrigSuspendFirstFloat) gOrigSuspendFirstFloat(self, _cmd, ad);
}

static BOOL gAdsDone = NO;
static BOOL SoulInstallAdHooks(void) {
    if (gAdsDone) return YES;
    BOOL any = NO;
    Class square = objc_getClass("SoulAdSquareViewModel");
    if (square) {
        SoulInstallMethodHook(square, NSSelectorFromString(@"requestAdEnabed"),
                              (IMP)SoulHookSquareAdEnabled, (IMP *)&gOrigSquareAdEnabled);
        any = YES;
    }
    Class rec = objc_getClass("SORecommandSubViewModel");
    if (rec) {
        SoulInstallMethodHook(rec, NSSelectorFromString(@"requestAdEnabed"),
                              (IMP)SoulHookRecAdEnabled, (IMP *)&gOrigRecAdEnabled);
        any = YES;
    }
    Class gc = objc_getClass("SOGCViewController");
    if (gc) {
        SoulInstallMethodHook(gc, NSSelectorFromString(@"nativeAdEnableAutoDisplay"),
                              (IMP)SoulHookGCAdAutoDisplay, (IMP *)&gOrigGCAdAutoDisplay);
        any = YES;
    }
    Class comments = objc_getClass("SOPostCommentsViewModel");
    if (comments) {
        SoulInstallMethodHook(comments, NSSelectorFromString(@"requestAdData:"),
                              (IMP)SoulHookCommentAdRequest, (IMP *)&gOrigCommentAdRequest);
        any = YES;
    }
    Class search = objc_getClass("SOSearchVC");
    if (search) {
        SoulInstallMethodHook(search, NSSelectorFromString(@"requestAd:success:failure:"),
                              (IMP)SoulHookSearchAdRequest, (IMP *)&gOrigSearchAdRequest);
        any = YES;
    }
    Class banner = objc_getClass("SoulBannerAdBaseView");
    if (banner) {
        SoulInstallMethodHook(banner, NSSelectorFromString(@"didMoveToWindow"),
                              (IMP)SoulHookBannerDidMove, (IMP *)&gOrigBannerDidMove);
        any = YES;
    }
    Class suspend = objc_getClass("SOSuspendAdManager");
    if (suspend) {
        SoulInstallMethodHook(suspend, NSSelectorFromString(@"showAdView"),
                              (IMP)SoulHookSuspendShowAd, (IMP *)&gOrigSuspendShowAd);
        SoulInstallMethodHook(suspend, NSSelectorFromString(@"showSuspendView"),
                              (IMP)SoulHookSuspendShowView, (IMP *)&gOrigSuspendShowView);
        SoulInstallMethodHook(suspend, NSSelectorFromString(@"tryShowFirsFloatViewWithNativeAd:"),
                              (IMP)SoulHookSuspendFirstFloat, (IMP *)&gOrigSuspendFirstFloat);
        any = YES;
    }
    if (any) {
        gAdsDone = YES;
        SoulLog(@"ads: hooks installed");
    }
    return any;
}

// —— P. 语音消息自动转文字（复用 cell 自带转写入口） ——
static NSMutableSet<NSString *> *gVoiceAutoPending = nil;
static dispatch_once_t gVoiceAutoOnce;

static id SoulValueForKey(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void SoulVoiceAutoRemove(NSString *mid) {
    if (!mid.length) return;
    @synchronized (gVoiceAutoPending) { [gVoiceAutoPending removeObject:mid]; }
}

static void SoulVoiceAutoRetry(id cell, id layout, NSString *mid, NSInteger attempt) {
    NSTimeInterval delay = attempt == 0 ? 0.12 : 0.25;
    __weak id weakCell = cell;
    __weak id weakLayout = layout;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *c = weakCell;
        id l = weakLayout;
        if (!c || !SoulDef(kFxAutoVoiceText)) { SoulVoiceAutoRemove(mid); return; }
        if (!c.window) {
            if (attempt < 8) SoulVoiceAutoRetry(c, l, mid, attempt + 1);
            else SoulVoiceAutoRemove(mid);
            return;
        }
        id msg = SoulValueForKey(l, @"message");
        if (!msg) msg = l;
        NSString *text = SoulValueForKey(msg, @"audioText");
        if ([text isKindOfClass:[NSString class]] && text.length) {
            SoulVoiceAutoRemove(mid);
            return;
        }
        SEL action = NSSelectorFromString(@"convertAudioBtnAction:");
        if (![c respondsToSelector:action]) {
            SoulVoiceAutoRemove(mid);
            SoulLog(@"voice-text: no action cell=%@", NSStringFromClass([c class]));
            return;
        }
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(c, action, nil);
            SoulLog(@"voice-text: requested msg=%@", mid);
        } @catch (NSException *e) {
            SoulLog(@"voice-text: action threw %@", e.reason);
            SoulVoiceAutoRemove(mid);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id msg2 = SoulValueForKey(weakLayout, @"message");
            if (!msg2) msg2 = weakLayout;
            NSString *text2 = SoulValueForKey(msg2, @"audioText");
            if (![text2 isKindOfClass:[NSString class]] || !text2.length) SoulVoiceAutoRemove(mid);
        });
    });
}

static void SoulMaybeAutoVoiceText(id cell, id layout) {
    if (!SoulDef(kFxAutoVoiceText)) return;
    Class audioCell = objc_getClass("SOChatAudioMessageTableViewCell");
    if (!audioCell || ![cell isKindOfClass:audioCell]) return;
    id msg = SoulValueForKey(layout, @"message");
    if (!msg) msg = layout;
    if (!msg) return;
    NSString *text = SoulValueForKey(msg, @"audioText");
    if ([text isKindOfClass:[NSString class]] && text.length) return;
    NSString *mid = [SoulValueForKey(msg, @"msgId") description];
    if (!mid.length) return;
    dispatch_once(&gVoiceAutoOnce, ^{ gVoiceAutoPending = [NSMutableSet set]; });
    @synchronized (gVoiceAutoPending) {
        if ([gVoiceAutoPending containsObject:mid]) return;
        if (gVoiceAutoPending.count > 300) [gVoiceAutoPending removeAllObjects];
        [gVoiceAutoPending addObject:mid];
    }
    SoulVoiceAutoRetry(cell, layout, mid, 0);
}

static void (*gOrigAudioUpdateUI)(id, SEL, id);
static void SoulHookAudioUpdateUI(id self, SEL _cmd, id model) {
    if (gOrigAudioUpdateUI) gOrigAudioUpdateUI(self, _cmd, model);
    SoulMaybeAutoVoiceText(self, model);
}

static BOOL gAutoVoiceDone = NO;
static BOOL SoulInstallAutoVoiceHooks(void) {
    if (gAutoVoiceDone) return YES;
    Class cell = objc_getClass("SOChatAudioMessageTableViewCell");
    if (cell) {
        SoulInstallMethodHook(cell, NSSelectorFromString(@"updateSubclassingUIWithChatMessageModel:"),
                              (IMP)SoulHookAudioUpdateUI, (IMP *)&gOrigAudioUpdateUI);
        gAutoVoiceDone = YES;
        SoulLog(@"voice-text: audio-cell hook installed");
        return YES;
    }
    return NO;
}

// —— H. 回前台清除已送达通知（系统级，无类依赖）——
static void SoulInstallClearNotif(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (!SoulDef(kFxClearNotif)) return;
        [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
        SoulLog(@"clear-notif: delivered notifications cleared");
    }];
}
__attribute__((constructor))
static void SoulTweakInit(void) {
    if (!SoulSkipGroup(@"dice")) {
        Class sender = objc_getClass("SOPCMessageSender");
        if (sender) {
            SoulInstallMethodHook(sender, NSSelectorFromString(@"sendRollDiceIMMessage:to:"),
                                  (IMP)SoulHookSendDice, (IMP *)&gOrigSendRollDice);
            SoulInstallMethodHook(sender, NSSelectorFromString(@"sendFingerIMMessage:to:"),
                                  (IMP)SoulHookSendFinger, (IMP *)&gOrigSendFinger);
            SoulInstallInputHooks();
        }
    }
    if (!SoulSkipGroup(@"web")) {
        Class webvc = objc_getClass("SOWebViewController");
        if (webvc) {
            SoulInstallMethodHook(webvc, NSSelectorFromString(@"viewDidAppear:"),
                                  (IMP)SoulHookWebDidAppear, (IMP *)&gOrigWebDidAppear);
        }
    }
    if (!SoulSkipGroup(@"snap")) { SoulInstallSnapHooksRetry(12); SoulInstallSnapProbes(); SoulInstallSnapMultiHooks(); }
    if (!SoulSkipGroup(@"wm")) { SoulInstallWatermarkHooks(); SoulInstallVideoWatermarkHooks(); }
    if (!SoulSkipGroup(@"bgm")) SoulInstallBgmHooks();
    if (!SoulSkipGroup(@"net")) SoulInstallNetHooks();
    if (!SoulSkipGroup(@"share")) SoulInstallShareHooks();
    if (!SoulSkipGroup(@"blockview")) SoulInstallBlockViewHooksRetry(24);
    if (!SoulSkipGroup(@"recall")) SoulInstallAntiRecallHooksRetry(20);
    if (!SoulSkipGroup(@"limit")) SoulInstallLimitHooksRetry(24);
    if (!SoulSkipGroup(@"ownrecall")) SoulInstallOwnRecallHooksRetry(24);
    if (!SoulSkipGroup(@"picker")) SoulRetryInstall(^BOOL{ return SoulInstallPickerHooks(); }, 12);
    if (!SoulSkipGroup(@"splash")) SoulRetryInstall(^BOOL{ return SoulInstallSplashHooks(); }, 12);
    if (!SoulSkipGroup(@"grouprecall")) SoulRetryInstall(^BOOL{ return SoulInstallGroupRecallHooks(); }, 12);
    if (!SoulSkipGroup(@"blockread")) SoulRetryInstall(^BOOL{ return SoulInstallBlockReadHooks(); }, 12);
    if (!SoulSkipGroup(@"autoread")) SoulRetryInstall(^BOOL{ return SoulInstallAutoReadHooks(); }, 12);
    if (!SoulSkipGroup(@"closefriend")) SoulRetryInstall(^BOOL{ return SoulInstallCloseFriendHooks(); }, 12);
    if (!SoulSkipGroup(@"voice")) SoulRetryInstall(^BOOL{ return SoulInstallVoiceHooks(); }, 12);
    if (!SoulSkipGroup(@"autovoice")) SoulRetryInstall(^BOOL{ return SoulInstallAutoVoiceHooks(); }, 24);
    if (!SoulSkipGroup(@"teen")) SoulRetryInstall(^BOOL{ return SoulInstallTeenHooks(); }, 24);
    if (!SoulSkipGroup(@"ads")) SoulRetryInstall(^BOOL{ return SoulInstallAdHooks(); }, 24);
    SoulInstallClearNotif();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulSyncLoveBellPatch(); });
    SoulLog(@"skip=%d", (int)(SoulSkipText().length > 0));
    SoulLog(@"loaded v18. dice=%d snapUnlock=%d teenOff=%d adsOff=%d autoVoice=%d",
            (int)SoulDiceOn(), (int)SoulDef(kFxSnapUnlock),
            (int)SoulDef(kFxNoTeenPopup), (int)SoulDef(kFxNoAds),
            (int)SoulDef(kFxAutoVoiceText));
}
