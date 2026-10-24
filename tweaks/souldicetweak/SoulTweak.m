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
static NSString * const kFxBlockRead     = @"soulfx_block_read";
static NSString * const kFxAutoRead      = @"soulfx_auto_read";
static NSString * const kFxNoCloseFriend = @"soulfx_no_close_friend";
static NSString * const kFxClearNotif    = @"soulfx_clear_notif";
static NSString * const kFxVoiceUnlock   = @"soulfx_voice_unlock";

// —— 2026-10-24 新增 ——
static NSString * const kFxNoTeenPopup   = @"soulfx_no_teen_popup";
static NSString * const kFxMsgTime       = @"soulfx_msg_time";
static NSString * const kFxMsgTimeFmt    = @"soulfx_msg_time_format";
static NSString * const kFxNoScreenshot  = @"soulfx_no_screenshot_notify";
static NSString * const kFxNoAds         = @"soulfx_no_ads";
static NSString * const kFxAutoVoiceText = @"soulfx_auto_voice_text";
static NSString * const kFxMenuTools     = @"soulfx_menu_tools";

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
/* 落盘前先在锁内取快照，磁盘 I/O 放在锁外，避免 hook 线程卡在配置锁上。 */
static void SoulCfgPersist(void) {
    NSDictionary *snap = nil;
    [gSoulCfgLock lock];
    snap = [gSoulCfg copy];
    [gSoulCfgLock unlock];
    if (snap) [snap writeToFile:SoulFXPath(@"config.plist") atomically:YES];
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
static void SoulRetryInstall(BOOL (^block)(void), int n);

static void SoulSetDef(NSString *key, BOOL on) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    gSoulCfg[key] = @(on);
    [gSoulCfgLock unlock];
    SoulCfgPersist();
    SoulLog(@"toggle %@ -> %d", key, (int)on);
    if ([key isEqualToString:kFxGiftFree]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SoulSyncLoveBellPatch(); });
    }
}
static void SoulSetCfgString(NSString *key, NSString *val) {
    SoulCfgLoad();
    [gSoulCfgLock lock];
    if (val) gSoulCfg[key] = val; else [gSoulCfg removeObjectForKey:key];
    [gSoulCfgLock unlock];
    SoulCfgPersist();
}
static BOOL SoulDiceOn(void) { return SoulDef(kDiceEnabledKey); }

// 面板数据：一个分组 = 二级页面；行分「开关」和「选项」两种。
typedef NS_ENUM(NSInteger, SoulFxRowKind) {
    SoulFxRowKindSwitch = 0,
    SoulFxRowKindChoice = 1,
};

@interface SoulFxRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) BOOL defaultOn;
@property (nonatomic, assign) SoulFxRowKind kind;
@end

@implementation SoulFxRow
+ (instancetype)switchRow:(NSString *)title key:(NSString *)key def:(BOOL)def {
    SoulFxRow *r = [SoulFxRow new];
    r.title = title;
    r.key = key;
    r.defaultOn = def;
    r.kind = SoulFxRowKindSwitch;
    return r;
}
+ (instancetype)choiceRow:(NSString *)title key:(NSString *)key {
    SoulFxRow *r = [SoulFxRow new];
    r.title = title;
    r.key = key;
    r.kind = SoulFxRowKindChoice;
    return r;
}
@end

@interface SoulFxGroup : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSArray<SoulFxRow *> *rows;
@end

@implementation SoulFxGroup
@end

static SoulFxGroup *SoulFxGroupMake(NSString *title, NSString *summary, NSArray<SoulFxRow *> *rows) {
    SoulFxGroup *g = [SoulFxGroup new];
    g.title = title;
    g.summary = summary;
    g.rows = rows;
    return g;
}

static NSArray<NSArray<NSString *> *> *SoulTimeFormatOptions(void) {
    return @[
        @[@"时:分", @"HH:mm"],
        @[@"时:分:秒", @"HH:mm:ss"],
        @[@"完整", @"yyyy-MM-dd HH:mm"],
    ];
}

static NSArray<SoulFxGroup *> *SoulFxGroups(void) {
    return @[
        SoulFxGroupMake(@"聊天与消息", @"骰子、撤回、截图、语音、菜单", @[
            [SoulFxRow switchRow:@"自定义骰子 / 猜拳" key:kDiceEnabledKey def:NO],
            [SoulFxRow switchRow:@"防撤回（私聊 / 群聊）" key:kFxAntiRecall def:NO],
            [SoulFxRow switchRow:@"超 2 分钟也能撤回自己的消息" key:kFxOwnRecall def:YES],
            [SoulFxRow switchRow:@"禁止上报状态（输入 / 查看主页）" key:kFxBlockInput def:NO],
            [SoulFxRow switchRow:@"禁止上报「已读」回执" key:kFxBlockRead def:NO],
            [SoulFxRow switchRow:@"收到消息自动已读" key:kFxAutoRead def:NO],
            [SoulFxRow switchRow:@"禁止弹「挚友」邀请" key:kFxNoCloseFriend def:NO],
            [SoulFxRow switchRow:@"回前台自动清除通知" key:kFxClearNotif def:NO],
            [SoulFxRow switchRow:@"去除青少年弹窗" key:kFxNoTeenPopup def:NO],
            [SoulFxRow switchRow:@"截图不提醒对方" key:kFxNoScreenshot def:NO],
            [SoulFxRow switchRow:@"语音消息自动转文字" key:kFxAutoVoiceText def:NO],
            [SoulFxRow switchRow:@"长按菜单增强（复制文本 / 保存语音）" key:kFxMenuTools def:NO],
        ]),
        SoulFxGroupMake(@"图片 / 视频 / 分享", @"阅后即焚、水印、分享、选择数量", @[
            [SoulFxRow switchRow:@"阅后即焚解锁（截屏 / 多次查看）" key:kFxSnapUnlock def:NO],
            [SoulFxRow switchRow:@"保存 / 分享：无水印 + 无限制" key:kFxSaveNoWM def:NO],
            [SoulFxRow switchRow:@"去除主页分享限制（隐私防护）" key:kFxShareHome def:NO],
            [SoulFxRow switchRow:@"解除图片 / 视频选择数量上限" key:kFxPickerFree def:NO],
        ]),
        SoulFxGroupMake(@"限制与体验", @"送礼、礼仪分、广告、语音", @[
            [SoulFxRow switchRow:@"去除送礼限制（聊天 / 奇遇铃）" key:kFxGiftFree def:NO],
            [SoulFxRow switchRow:@"去除礼仪分限制" key:kFxEtiquetteFree def:NO],
            [SoulFxRow switchRow:@"关闭匹配背景音乐" key:kFxMuteMatchBgm def:NO],
            [SoulFxRow switchRow:@"跳过开屏 / 启动广告" key:kFxNoSplashAd def:NO],
            [SoulFxRow switchRow:@"语音消息解锁装扮" key:kFxVoiceUnlock def:NO],
            [SoulFxRow switchRow:@"去除广告（信息流 / 搜索 / 评论 / 聊天）" key:kFxNoAds def:NO],
        ]),
        SoulFxGroupMake(@"消息时间", @"每条消息单独显示发送时间", @[
            [SoulFxRow switchRow:@"每条消息显示时间" key:kFxMsgTime def:NO],
            [SoulFxRow choiceRow:@"时间格式" key:kFxMsgTimeFmt],
        ]),
        SoulFxGroupMake(@"调试", @"请求与功能排查", @[
            [SoulFxRow switchRow:@"调试日志（请求日志 + 落盘）" key:kFxDebugLog def:NO],
        ]),
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

/* 幂等：同一 (类, 选择器) 只挂一次，重复调用返回 YES，但不会把已有 hook 记成「原实现」。
   若该类本身没实现（方法是从父类继承来的），必须用 class_addMethod 挂到本类；
   直接 method_setImplementation 会改到父类的实现，波及整个 App。 */
static NSMutableSet<NSString *> *gSoulHookedKeys = nil;

static BOOL SoulInstallMethodHook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSoulHookedKeys = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%s#%s", class_getName(cls), sel_getName(sel)];
    @synchronized (gSoulHookedKeys) {
        if ([gSoulHookedKeys containsObject:key]) return YES;
        if (orig) *orig = cur;
        if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
            method_setImplementation(m, newImp);
        }
        [gSoulHookedKeys addObject:key];
    }
    return YES;
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

#pragma mark - 设置面板（分组 → 开关 / 选项）

static void SoulHidePanel(void);

static UIColor *SoulFxCardBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithRed:0.07 green:0.07 blue:0.08 alpha:1.0]
            : [UIColor systemGroupedBackgroundColor];
    }];
}

@interface SoulFxGroupVC : UITableViewController
- (instancetype)initWithGroup:(SoulFxGroup *)group;
@end

@interface SoulFxChoiceVC : UITableViewController
- (instancetype)initWithRow:(SoulFxRow *)row;
@end

@interface SoulFxRootVC : UITableViewController
@end

@implementation SoulFxRootVC {
    NSArray<SoulFxGroup *> *_groups;
}
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _groups = SoulFxGroups();
        self.title = @"Soul 助手";
        self.tableView.estimatedRowHeight = 58;
        self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(soulDone)];
}
- (void)soulDone { SoulHidePanel(); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_groups.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"soulfx-group";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    SoulFxGroup *group = _groups[indexPath.row];
    cell.textLabel.text = group.title;
    cell.detailTextLabel.text = group.summary;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SoulFxGroup *group = _groups[indexPath.row];
    SoulFxGroupVC *vc = [[SoulFxGroupVC alloc] initWithGroup:group];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

@implementation SoulFxGroupVC {
    SoulFxGroup *_group;
}
- (instancetype)initWithGroup:(SoulFxGroup *)group {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _group = group;
        self.title = group.title;
        self.tableView.estimatedRowHeight = 50;
        self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    return self;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_group.rows.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SoulFxRow *row = _group.rows[indexPath.row];
    if (row.kind == SoulFxRowKindChoice) {
        static NSString *tid = @"soulfx-choice";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:tid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:tid];
            cell.textLabel.font = [UIFont systemFontOfSize:16];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
        cell.textLabel.text = row.title;
        NSString *val = SoulCfgString(row.key);
        cell.detailTextLabel.text = val.length ? val : @"HH:mm";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    static NSString *sid = @"soulfx-switch";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
    UISwitch *sw = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.textLabel.numberOfLines = 2;
        sw = [[UISwitch alloc] init];
        sw.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [sw addTarget:self action:@selector(soulSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        sw = (UISwitch *)cell.accessoryView;
    }
    sw.tag = indexPath.row;
    sw.onTintColor = SoulAccent();
    sw.on = SoulDefOn(row.key, row.defaultOn);
    cell.textLabel.text = row.title;
    return cell;
}
- (void)soulSwitchChanged:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)_group.rows.count) return;
    SoulSetDef(_group.rows[sw.tag].key, sw.on);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SoulFxRow *row = _group.rows[indexPath.row];
    if (row.kind != SoulFxRowKindChoice) return;
    SoulFxChoiceVC *vc = [[SoulFxChoiceVC alloc] initWithRow:row];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

@interface SoulFxTextVC : UIViewController <UITextFieldDelegate>
- (instancetype)initWithRow:(SoulFxRow *)row;
@end

@implementation SoulFxTextVC {
    SoulFxRow *_row;
    UITextField *_field;
}
- (instancetype)initWithRow:(SoulFxRow *)row {
    if ((self = [super init])) {
        _row = row;
        self.title = row.title;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(soulSave)];
    _field = [[UITextField alloc] init];
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.backgroundColor = SoulFxCardBackground();
    _field.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    _field.placeholder = @"HH:mm";
    _field.text = SoulCfgString(_row.key) ?: @"";
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.returnKeyType = UIReturnKeyDone;
    _field.delegate = self;
    [self.view addSubview:_field];
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.text = @"NSDateFormatter 格式，例如 HH:mm、HH:mm:ss、MM-dd HH:mm。留空保存恢复 HH:mm。";
    [self.view addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [_field.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [_field.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_field.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_field.heightAnchor constraintEqualToConstant:46],
        [hint.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:_field.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:_field.trailingAnchor],
    ]];
}
- (void)soulSave {
    NSString *val = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (val.length > 40) val = [val substringToIndex:40];
    SoulSetCfgString(_row.key, val.length ? val : nil);
    [self.navigationController popViewControllerAnimated:YES];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self soulSave];
    return YES;
}
@end

@implementation SoulFxChoiceVC {
    SoulFxRow *_row;
}
- (instancetype)initWithRow:(SoulFxRow *)row {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _row = row;
        self.title = row.title;
        self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    return self;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1 + (NSInteger)SoulTimeFormatOptions().count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *current = SoulCfgString(_row.key);
    if (!current.length) current = @"HH:mm";
    static NSString *cid = @"soulfx-format";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    if (indexPath.row == 0) {
        cell.textLabel.text = @"自定义格式";
        cell.detailTextLabel.text = current;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.tintColor = SoulAccent();
        return cell;
    }
    NSArray<NSString *> *opt = SoulTimeFormatOptions()[indexPath.row - 1];
    cell.textLabel.text = opt[0];
    cell.detailTextLabel.text = opt[1];
    cell.accessoryType = [current isEqualToString:opt[1]] ? UITableViewCellAccessoryCheckmark
                                                          : UITableViewCellAccessoryNone;
    cell.tintColor = SoulAccent();
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        SoulFxTextVC *vc = [[SoulFxTextVC alloc] initWithRow:_row];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    NSArray<NSString *> *opt = SoulTimeFormatOptions()[indexPath.row - 1];
    SoulSetCfgString(_row.key, opt[1]);
    [tableView reloadData];
    SoulLog(@"msg-time: format -> %@", opt[1]);
}
@end

static UINavigationController *gSoulPanelNav = nil;
static BOOL gSoulPanelTransitioning = NO;

static void SoulHidePanel(void) {
    UINavigationController *nav = gSoulPanelNav;
    gSoulPanelNav = nil;
    if (!nav) return;
    UIViewController *presenter = nav.presentingViewController;
    gSoulPanelTransitioning = YES;
    if (presenter) {
        [presenter dismissViewControllerAnimated:YES completion:^{ gSoulPanelTransitioning = NO; }];
    } else {
        gSoulPanelTransitioning = NO;
    }
}

static void SoulTogglePanel(void) {
    if (gSoulPanelTransitioning) return;
    if (gSoulPanelNav) { SoulHidePanel(); return; }
    UIViewController *top = SoulTopViewController();
    if (!top) { SoulLog(@"toggle: no top view controller"); return; }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SoulFxRootVC new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    nav.navigationBar.tintColor = SoulAccent();
    gSoulPanelNav = nav;
    gSoulPanelTransitioning = YES;
    [top presentViewController:nav animated:YES completion:^{ gSoulPanelTransitioning = NO; }];
}

#pragma mark - 设置页入口图标

static const void *kSoulEntryInstalledKey = &kSoulEntryInstalledKey;

static UILabel *SoulFindWidestLabel(UIView *root, UILabel *best) {
    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)root;
        if (l.text.length && !l.hidden && l.alpha > 0.05 && CGRectGetWidth(l.bounds) > 30) {
            if (!best || CGRectGetWidth(l.bounds) > CGRectGetWidth(best.bounds)) best = l;
        }
    }
    for (UIView *sub in root.subviews) best = SoulFindWidestLabel(sub, best);
    return best;
}

static void SoulInstallEntry(UIViewController *vc) {
    if (!vc) return;
    if (objc_getAssociatedObject(vc, kSoulEntryInstalledKey)) return;
    objc_setAssociatedObject(vc, kSoulEntryInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:cfg] forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = SoulAccent();
    btn.layer.cornerRadius = 24;
    [btn addTarget:vc action:@selector(soulEntryTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *nav = nil;
    SEL navSel = NSSelectorFromString(@"navView");
    if ([vc respondsToSelector:navSel]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(vc, navSel);
        if ([v isKindOfClass:[UIView class]]) nav = v;
    }
    [vc.view addSubview:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.widthAnchor constraintEqualToConstant:48],
        [btn.heightAnchor constraintEqualToConstant:48],
        [btn.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-18],
        [btn.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-28],
    ]];
    btn.layer.cornerRadius = 24;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.22;
    btn.layer.shadowRadius = 8;
    btn.layer.shadowOffset = CGSizeMake(0, 3);
    UIImageSymbolConfiguration *bigCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    [btn setImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:bigCfg] forState:UIControlStateNormal];
}

@implementation UIViewController (SoulEntry)
- (void)soulEntryTapped:(id)sender { SoulTogglePanel(); }
@end

#pragma mark - 长按底部「自己」打开面板

static NSString *SoulFirstLabelText(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    for (UIView *sub in view.subviews) {
        NSString *s = SoulFirstLabelText(sub);
        if (s.length) return s;
    }
    return nil;
}

@interface SoulTabPressTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UITabBarController *tabBarController;
+ (instancetype)shared;
- (void)longPressed:(UILongPressGestureRecognizer *)g;
@end

@implementation SoulTabPressTarget
+ (instancetype)shared {
    static SoulTabPressTarget *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [SoulTabPressTarget new]; });
    return t;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITabBarController *tbc = self.tabBarController;
    if (!tbc) return;
    CGPoint p = [g locationInView:tbc.tabBar];
    UIView *deepest = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:tbc.tabBar];
    while (queue.count) {
        UIView *v = queue.lastObject;
        [queue removeLastObject];
        CGPoint local = [v convertPoint:p fromView:tbc.tabBar];
        if (CGRectContainsPoint(v.bounds, local)) {
            deepest = v;
            for (UIView *sub in v.subviews) [queue addObject:sub];
        }
    }
    UIView *hit = deepest ?: tbc.tabBar;
    NSInteger count = (NSInteger)tbc.tabBar.items.count;
    if (count <= 0) return;
    CGFloat slot = tbc.tabBar.bounds.size.width / (CGFloat)count;
    NSInteger index = (NSInteger)(p.x / MAX(slot, 1.0));
    index = MIN(MAX(index, 0), count - 1);
    NSString *title = tbc.tabBar.items[index].title;
    if (!title.length) title = SoulFirstLabelText(hit);
    SoulLog(@"tab long-press index=%ld title=%@", (long)index, title ?: @"?");
    if (![title containsString:@"自己"] && ![title containsString:@"我的"]) return;

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    UIView *btn = hit;
    btn.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [UIView animateWithDuration:0.16 animations:^{ btn.transform = CGAffineTransformIdentity; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulTogglePanel(); });
}
@end

static void (*gOrigTabDidAppear)(id, SEL, BOOL);
static void SoulHookTabDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigTabDidAppear) gOrigTabDidAppear(self, _cmd, animated);
    if (![self isKindOfClass:[UITabBarController class]]) return;
    UITabBarController *tbc = (UITabBarController *)self;
    UITapGestureRecognizer *existing = nil;
    for (UIGestureRecognizer *gr in tbc.tabBar.gestureRecognizers) {
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]] &&
            gr.delegate == (id)[SoulTabPressTarget shared]) { existing = (UITapGestureRecognizer *)gr; }
    }
    if (existing) return;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[SoulTabPressTarget shared]
                                                      action:@selector(longPressed:)];
    lp.minimumPressDuration = 0.55;
    lp.cancelsTouchesInView = NO;
    lp.delegate = [SoulTabPressTarget shared];
    [tbc.tabBar addGestureRecognizer:lp];
    [SoulTabPressTarget shared].tabBarController = tbc;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (UITabBarItem *item in tbc.tabBar.items) [titles addObject:item.title ?: @"?"];
    SoulLog(@"tab: long-press installed %@ titles=%@", NSStringFromClass([tbc class]), titles);
}

static BOOL SoulInstallTabHooks(void) {
    static BOOL done = NO;
    if (done) return YES;
    Class cls = objc_getClass("NewTabBarController");
    if (!cls) return NO;
    if (SoulInstallMethodHook(cls, NSSelectorFromString(@"viewDidAppear:"),
                              (IMP)SoulHookTabDidAppear, (IMP *)&gOrigTabDidAppear)) {
        done = YES;
        SoulLog(@"tab: hook installed");
    }
    return done;
}

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
    if (SoulDef(kFxSnapUnlock)) { SoulLog(@"snap didTakeScreenshot swallowed"); return; }
    if (gOrigSnapDidTakeScreenshot) gOrigSnapDidTakeScreenshot(self, _cmd);
}
static void SoulSnapScreenCaptureChanged(id self, SEL _cmd) {
    if (SoulDef(kFxSnapUnlock)) { SoulLog(@"snap screenCaptureStatusChanged swallowed"); return; }
    if (gOrigSnapScreenCaptureChanged) gOrigSnapScreenCaptureChanged(self, _cmd);
}
static void SoulSnapWillResignActive(id self, SEL _cmd) {
    if (SoulDef(kFxSnapUnlock)) { SoulLog(@"snap willResignActive swallowed"); return; }
    if (gOrigSnapWillResignActive) gOrigSnapWillResignActive(self, _cmd);
}

static BOOL SoulInstallSnapHooks(void) {
    if (gSnapHooksInstalled) return YES;
    Class cls = objc_getClass("_TtC15SoulPrivateChat23SOChatSnapshotPreviewVC");
    if (!cls) cls = objc_getClass("SOChatSnapshotPreviewVC");
    if (!cls) return NO;
    BOOL ok = NO;
    ok |= SoulInstallMethodHook(cls, NSSelectorFromString(@"didTakeScreenshot"),
                                (IMP)SoulSnapDidTakeScreenshot, (IMP *)&gOrigSnapDidTakeScreenshot);
    ok |= SoulInstallMethodHook(cls, NSSelectorFromString(@"screenCaptureStatusChanged"),
                                (IMP)SoulSnapScreenCaptureChanged, (IMP *)&gOrigSnapScreenCaptureChanged);
    ok |= SoulInstallMethodHook(cls, NSSelectorFromString(@"willResignActive"),
                                (IMP)SoulSnapWillResignActive, (IMP *)&gOrigSnapWillResignActive);
    if (ok) {
        gSnapHooksInstalled = YES;
        SoulLog(@"snap hooks installed on %@", NSStringFromClass(cls));
    }
    return ok;
}

static void SoulInstallSnapHooksRetry(int n) {
    if (gSnapHooksInstalled) return;
    if (SoulInstallSnapHooks()) return;
    if (n <= 0) { SoulLog(@"snap hooks not installed after retries"); return; }
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
    if (!req || !SoulDef(kFxDebugLog)) return;
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
        BOOL wantResp = SoulDef(kFxDebugLog) &&
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
        SoulRecallMarkBlocked(msg);
        if ([NSThread isMainThread]) SoulRefreshRecallBadges();
        else dispatch_async(dispatch_get_main_queue(), ^{ SoulRefreshRecallBadges(); });
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
            BOOL a = SoulInstallMethodHook(soc, NSSelectorFromString(@"checkMsgIsNeedLimit:"), (IMP)SoulHookSocMsgNeedLimit, (IMP *)&gOrigSocMsgNeedLimit);
            BOOL b = SoulInstallMethodHook(soc, NSSelectorFromString(@"checkIsforbidCallOn:"), (IMP)SoulHookSocForbidCall, (IMP *)&gOrigSocForbidCall);
            BOOL c = SoulInstallMethodHook(soc, NSSelectorFromString(@"checkUserHasSucceesSendMsgIn24Hours:"), (IMP)SoulHookSocSent24h, (IMP *)&gOrigSocSent24h);
            if (a || b || c) { gLimitSocDone = YES; SoulLog(@"limit: social score handler hooked"); }
        }
    }
    if (!gLimitGmDone) {
        Class gm = objc_getClass("SOPCSocialGraceScoreModel");
        if (gm) {
            BOOL a = SoulInstallMethodHook(gm, NSSelectorFromString(@"canNotSendBeforeReply"), (IMP)SoulHookSocCanNotSend, (IMP *)&gOrigSocCanNotSend);
            BOOL b = SoulInstallMethodHook(gm, NSSelectorFromString(@"forbidPic"), (IMP)SoulHookSocForbidPic, (IMP *)&gOrigSocForbidPic);
            BOOL c = SoulInstallMethodHook(gm, NSSelectorFromString(@"forbidCall"), (IMP)SoulHookSocForbidCallProp, (IMP *)&gOrigSocForbidCallProp);
            BOOL d = SoulInstallMethodHook(gm, NSSelectorFromString(@"createSessionLimit"), (IMP)SoulHookSocCreateLimit, (IMP *)&gOrigSocCreateLimit);
            if (a || b || c || d) { gLimitGmDone = YES; SoulLog(@"limit: social grace model hooked"); }
        }
    }
    if (!gLimitPayDone) {
        Class pay = objc_getClass("_TtC15SoulPrivateChat23SOPCLimitPaymentManager");
        if (pay) {
            BOOL a = SoulInstallMethodHook(pay, NSSelectorFromString(@"canSendMessage_limitPayment_V2:"), (IMP)SoulHookPayCanSendV2, (IMP *)&gOrigPayCanSendV2);
            BOOL b = SoulInstallMethodHook(pay, NSSelectorFromString(@"canSendMessage_limitPayment_V3:"), (IMP)SoulHookPayCanSendV3, (IMP *)&gOrigPayCanSendV3);
            BOOL c = SoulInstallMethodHook(pay, NSSelectorFromString(@"isLimitPaymentV2"), (IMP)SoulHookPayIsLimitV2, (IMP *)&gOrigPayIsLimitV2);
            BOOL d = SoulInstallMethodHook(pay, NSSelectorFromString(@"isLimitPaymentV3"), (IMP)SoulHookPayIsLimitV3, (IMP *)&gOrigPayIsLimitV3);
            if (a || b || c || d) { gLimitPayDone = YES; SoulLog(@"limit: payment manager hooked"); }
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

/* 每个消息类各自挂一层 timestamp，原实现按类名分别保存；
   共用一份 IMP 会导致第二次安装把 hook 自身记成原实现而死循环。 */
static NSMutableDictionary<NSString *, NSValue *> *gMsgTimestampOrig = nil;

static IMP SoulMsgTimestampOriginal(id obj) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        NSValue *v = nil;
        @synchronized (gMsgTimestampOrig) { v = gMsgTimestampOrig[NSStringFromClass(c)]; }
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

static long long SoulHookMsgTimestamp(id self, SEL _cmd) {
    if (gOwnRecallFake && self == gOwnRecallFakeMsg) {
        return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    }
    IMP orig = SoulMsgTimestampOriginal(self);
    return orig ? ((long long (*)(id, SEL))orig)(self, _cmd) : 0;
}

static void SoulAppendMenuItems(id handler, id msg, id cell);

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
        if (!gMsgTimestampOrig) gMsgTimestampOrig = [NSMutableDictionary dictionary];
        Class mc = [msg class];
        NSString *cn = NSStringFromClass(mc);
        if (mc && cn && ![gOwnRecallHookedClasses containsObject:cn]) {
            SEL tsSel = NSSelectorFromString(@"timestamp");
            Method tsMethod = class_getInstanceMethod(mc, tsSel);
            IMP current = tsMethod ? method_getImplementation(tsMethod) : NULL;
            if (current == (IMP)SoulHookMsgTimestamp) {
                SoulLog(@"own-recall: timestamp already hooked via superclass for %@", cn);
            } else if (current) {
                IMP orig = NULL;
                if (SoulInstallMethodHook(mc, tsSel, (IMP)SoulHookMsgTimestamp, &orig) && orig) {
                    @synchronized (gMsgTimestampOrig) {
                        gMsgTimestampOrig[cn] = [NSValue valueWithPointer:orig];
                    }
                    SoulLog(@"own-recall: timestamp hook installed on %@", cn);
                }
            }
            [gOwnRecallHookedClasses addObject:cn];
        }
        gOwnRecallFakeMsg = msg;
        gOwnRecallFake = YES;
        @try {
            if (gOrigMenuAddItems) gOrigMenuAddItems(self, _cmd, msg, cell, recognizer);
        } @finally {
            gOwnRecallFake = NO;
            gOwnRecallFakeMsg = nil;
        }
        SoulAppendMenuItems(self, msg, cell);
        SoulLog(@"own-recall: menu rebuilt with fresh time cls=%@", cn ?: @"?");
        return;
    }
    if (gOrigMenuAddItems) gOrigMenuAddItems(self, _cmd, msg, cell, recognizer);
    SoulAppendMenuItems(self, msg, cell);
}

static BOOL gOwnRecallMenuDone = NO;
static void SoulInstallOwnRecallHooks(void) {
    if (gOwnRecallMenuDone) return;
    Class mh = objc_getClass("SOPCMenuHandler");
    if (!mh) return;
    if (SoulInstallMethodHook(mh, NSSelectorFromString(@"addMenuItemsWithMsg:cell:recognizer:"),
                              (IMP)SoulHookMenuAddItems, (IMP *)&gOrigMenuAddItems) && gOrigMenuAddItems) {
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
    /* 保留 EXECUTE：改写期间其他线程可能正在执行同一页。 */
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { SoulLog(@"lovebell-patch: vm_protect RWX failed kr=%d", (int)kr); return NO; }
    return YES;
}

static BOOL SoulMakePageExecutable(uint32_t *insn) {
    uintptr_t page = (uintptr_t)insn & ~(uintptr_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        SoulLog(@"lovebell-patch: vm_protect RX failed kr=%d (page stays writable)", (int)kr);
        return NO;
    }
    return YES;
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
    if (vc && SoulInstallMethodHook(vc, NSSelectorFromString(@"sysToOtherCheckStrangerHomepageStateIsSee:"),
                                    (IMP)SoulHookSysHomepageSee, (IMP *)&gOrigSysHomepageSee)) {
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
    BOOL ok = NO;
    Class aide = objc_getClass("SOAlbumPhotoJudgeSelectAide");
    if (aide && SoulInstallMethodHook(aide, NSSelectorFromString(@"maxCount"),
                                      (IMP)SoulHookAideMaxCount, (IMP *)&gOrigAideMaxCount)) {
        ok = YES;
        SoulLog(@"picker: aide hooked");
    }
    Class alb = objc_getClass("_TtC10SOPhotoKit25SOPhotoAlbumConfiguration");
    if (alb && SoulInstallMethodHook(alb, NSSelectorFromString(@"imageCountMaximum"),
                                     (IMP)SoulHookAlbumImgMax, (IMP *)&gOrigAlbumImgMax)) {
        ok = YES;
        SoulLog(@"picker: album config hooked");
    }
    if (ok) { gPickerDone = YES; return YES; }
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
        BOOL a = SoulInstallMethodHook(mgr, NSSelectorFromString(@"showSpalshAd:scene:reqId:"), (IMP)SoulHookShowSplash, (IMP *)&gOrigShowSplash);
        BOOL b = SoulInstallMethodHook(mgr, NSSelectorFromString(@"showLaunchViewWithSceneAction:"), (IMP)SoulHookShowLaunch, (IMP *)&gOrigShowLaunch);
        if (a || b) {
            gSplashDone = YES;
            SoulLog(@"no-splash: manager hooked (ad=%d launch=%d)", a, b);
            return YES;
        }
    }
    return NO;
}

// —— D. 群聊防撤回并入上方 anti-recall（同一 selector，只挂一次）——

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
    if (mgr && SoulInstallMethodHook(mgr, NSSelectorFromString(@"canSendIMRead:"),
                                     (IMP)SoulHookCanSendIMRead, (IMP *)&gOrigCanSendIMRead)) {
        SoulLog(@"block-read: manager hooked");
        any = YES;
    }
    Class snd = objc_getClass("SOPCMessageSender");
    if (snd) {
        any |= SoulInstallMethodHook(snd, NSSelectorFromString(@"sendSingleReadIMMessage:to:"), (IMP)SoulHookSendSingleRead, (IMP *)&gOrigSendSingleRead);
        any |= SoulInstallMethodHook(snd, NSSelectorFromString(@"sendBackGroundRead:to:"), (IMP)SoulHookSendBgRead, (IMP *)&gOrigSendBgRead);
        if (any) SoulLog(@"block-read: sender hooked");
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
    if (ad && SoulInstallMethodHook(ad, NSSelectorFromString(@"didReceiveMessages:"),
                                    (IMP)SoulHookDidReceiveMsgs, (IMP *)&gOrigDidReceiveMsgs)) {
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
    if (vc && SoulInstallMethodHook(vc, NSSelectorFromString(@"showAddCloseFriendAlertViewWith:"),
                                    (IMP)SoulHookShowCloseFriendAlert, (IMP *)&gOrigShowCloseFriendAlert)) {
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
    if (cell && SoulInstallMethodHook(cell, NSSelectorFromString(@"unlockVoiceWearBtnClick:"),
                                      (IMP)SoulHookUnlockVoiceWear, (IMP *)&gOrigUnlockVoiceWear)) {
        gVoiceDone = YES;
        SoulLog(@"voice-unlock: hooked");
        return YES;
    }
    return NO;
}

// —— L. 通用 block 调用 ——
static void SoulRunBlock(id block, id arg) {
    if (!block) return;
    void (^cb)(id) = block;
    cb(arg);
}

static void SoulToast(NSString *message) {
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = SoulTopViewController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

// —— M. 截图不提醒对方（SOPCScreenshotAuditManager）——
static void (*gOrigScreenshotHandle)(id, SEL);
static void SoulHookScreenshotHandle(id self, SEL _cmd) {
    if (SoulDef(kFxNoScreenshot)) {
        SoulLog(@"screenshot: audit suppressed");
        return;
    }
    if (gOrigScreenshotHandle) gOrigScreenshotHandle(self, _cmd);
}

static BOOL SoulInstallScreenshotHooks(void) {
    static BOOL done = NO;
    if (done) return YES;
    Class cls = objc_getClass("_TtC15SoulPrivateChat26SOPCScreenshotAuditManager");
    if (!cls) return NO;
    if (SoulInstallMethodHook(cls, NSSelectorFromString(@"handleScreenshot"),
                              (IMP)SoulHookScreenshotHandle, (IMP *)&gOrigScreenshotHandle)) {
        done = YES;
        SoulLog(@"screenshot: audit hook installed");
    }
    return done;
}

// —— N. 去广告（信息流 / 推荐 / 评论 / 搜索 / 群聊 / 横幅）——
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
        SoulLog(@"ads: comment ad request skipped");
        SoulRunBlock(done, nil);
        return;
    }
    if (gOrigCommentAdRequest) gOrigCommentAdRequest(self, _cmd, done);
}

static void (*gOrigSearchAdRequest)(id, SEL, id, id, id);
static void SoulHookSearchAdRequest(id self, SEL _cmd, id request, id success, id failure) {
    if (SoulDef(kFxNoAds)) {
        SoulLog(@"ads: search ad request skipped");
        SoulRunBlock(success, nil);
        return;
    }
    if (gOrigSearchAdRequest) gOrigSearchAdRequest(self, _cmd, request, success, failure);
}

static void (*gOrigBannerDidMove)(id, SEL);
static void SoulHookBannerDidMove(id self, SEL _cmd) {
    if (gOrigBannerDidMove) gOrigBannerDidMove(self, _cmd);
    if (SoulDef(kFxNoAds)) ((UIView *)self).hidden = YES;
}

static BOOL SoulInstallAdHooks(void) {
    static BOOL done = NO;
    if (done) return YES;
    BOOL ok = NO;
    Class square = objc_getClass("SoulAdSquareViewModel");
    if (square) {
        ok |= SoulInstallMethodHook(square, NSSelectorFromString(@"requestAdEnabed"),
                                    (IMP)SoulHookSquareAdEnabled, (IMP *)&gOrigSquareAdEnabled);
    }
    Class rec = objc_getClass("SORecommandSubViewModel");
    if (rec) {
        ok |= SoulInstallMethodHook(rec, NSSelectorFromString(@"requestAdEnabed"),
                                    (IMP)SoulHookRecAdEnabled, (IMP *)&gOrigRecAdEnabled);
    }
    Class gc = objc_getClass("SOGCViewController");
    if (gc) {
        ok |= SoulInstallMethodHook(gc, NSSelectorFromString(@"nativeAdEnableAutoDisplay"),
                                    (IMP)SoulHookGCAdAutoDisplay, (IMP *)&gOrigGCAdAutoDisplay);
    }
    Class pc = objc_getClass("SOPostCommentsViewModel");
    if (pc) {
        ok |= SoulInstallMethodHook(pc, NSSelectorFromString(@"requestAdData:"),
                                    (IMP)SoulHookCommentAdRequest, (IMP *)&gOrigCommentAdRequest);
    }
    Class search = objc_getClass("SOSearchVC");
    if (search) {
        ok |= SoulInstallMethodHook(search, NSSelectorFromString(@"requestAd:success:failure:"),
                                    (IMP)SoulHookSearchAdRequest, (IMP *)&gOrigSearchAdRequest);
    }
    Class banner = objc_getClass("SoulBannerAdBaseView");
    if (banner) {
        ok |= SoulInstallMethodHook(banner, NSSelectorFromString(@"didMoveToWindow"),
                                    (IMP)SoulHookBannerDidMove, (IMP *)&gOrigBannerDidMove);
    }
    if (ok) {
        done = YES;
        SoulLog(@"ads: hooks installed");
    }
    return ok;
}

// —— O. 长按菜单增强（复制文本 / 复制转写 / 保存语音）——
@interface SoulMenuTools : NSObject
@property (nonatomic, weak) id msg;
@property (nonatomic, weak) id cell;
+ (instancetype)shared;
- (void)soulCopyText;
- (void)soulCopyVoiceText;
- (void)soulSaveVoice;
@end

@implementation SoulMenuTools
+ (instancetype)shared {
    static SoulMenuTools *tools = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tools = [SoulMenuTools new]; });
    return tools;
}
- (void)soulCopyText {
    NSString *text = nil;
    @try { text = [self.msg valueForKey:@"bubbleText"]; } @catch (__unused NSException *e) {}
    if (![text isKindOfClass:[NSString class]] || !text.length) { SoulToast(@"没有可复制的文本"); return; }
    [UIPasteboard generalPasteboard].string = text;
    SoulLog(@"menu: copied text len=%lu", (unsigned long)text.length);
}
- (void)soulCopyVoiceText {
    NSString *text = nil;
    @try { text = [self.msg valueForKey:@"audioText"]; } @catch (__unused NSException *e) {}
    if (![text isKindOfClass:[NSString class]] || !text.length) { SoulToast(@"这条语音还没有转写文字"); return; }
    [UIPasteboard generalPasteboard].string = text;
    SoulLog(@"menu: copied voice text len=%lu", (unsigned long)text.length);
}
- (void)soulSaveVoice {
    id voice = nil;
    @try { voice = [self.msg valueForKey:@"voiceIMModel"]; } @catch (__unused NSException *e) {}
    NSString *url = nil;
    SEL urlSel = NSSelectorFromString(@"remoteURL");
    if (voice && [voice respondsToSelector:urlSel]) {
        id u = ((id (*)(id, SEL))objc_msgSend)(voice, urlSel);
        if ([u isKindOfClass:[NSURL class]]) url = [(NSURL *)u absoluteString];
        else if ([u isKindOfClass:[NSString class]]) url = u;
    }
    if (!url.length) { SoulToast(@"没有找到语音地址"); return; }
    NSString *mid = nil;
    @try { mid = [[self.msg valueForKey:@"msgId"] description]; } @catch (__unused NSException *e) {}
    if (!mid.length) mid = [NSString stringWithFormat:@"voice-%lld",
                            (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)];
    NSString *ext = [url.pathExtension lowercaseString];
    if (!ext.length) ext = @"m4a";
    NSString *dir = [SoulFXDir() stringByAppendingPathComponent:@"voice"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:[mid stringByAppendingPathExtension:ext]];
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { SoulToast(@"语音地址无效"); return; }
    SoulLog(@"menu: saving voice %@", url);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:u
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length && [data writeToFile:path atomically:YES]) {
            SoulLog(@"menu: voice saved %@", path);
            SoulToast([NSString stringWithFormat:@"语音已保存\n%@", path]);
        } else {
            SoulToast([NSString stringWithFormat:@"保存失败：%@", error.localizedDescription ?: @"未知错误"]);
        }
    }];
    [task resume];
}
@end

static id SoulMenuItem(Class cls, NSString *title, id target, SEL action) {
    if (!cls) return nil;
    return ((id (*)(id, SEL, id, id, SEL))objc_msgSend)([cls alloc],
        NSSelectorFromString(@"initWithTitle:target:action:"), title, target, action);
}

static void SoulAppendMenuItems(id handler, id msg, id cell) {
    if (!SoulDef(kFxMenuTools) || !msg || !handler) return;
    Class itemCls = objc_getClass("GMenuItem");
    SEL mcSel = NSSelectorFromString(@"menuController");
    if (!itemCls || ![handler respondsToSelector:mcSel]) return;
    id mc = ((id (*)(id, SEL))objc_msgSend)(handler, mcSel);
    if (!mc) return;
    NSMutableArray *items = [NSMutableArray array];
    SEL itemsSel = NSSelectorFromString(@"menuItems");
    if ([mc respondsToSelector:itemsSel]) {
        id cur = ((id (*)(id, SEL))objc_msgSend)(mc, itemsSel);
        if ([cur isKindOfClass:[NSArray class]]) [items addObjectsFromArray:(NSArray *)cur];
    }
    SoulMenuTools *tools = [SoulMenuTools shared];
    tools.msg = msg;
    tools.cell = cell;
    NSString *bubble = nil;
    NSString *audio = nil;
    id voice = nil;
    @try { bubble = [msg valueForKey:@"bubbleText"]; } @catch (__unused NSException *e) {}
    @try { audio = [msg valueForKey:@"audioText"]; } @catch (__unused NSException *e) {}
    @try { voice = [msg valueForKey:@"voiceIMModel"]; } @catch (__unused NSException *e) {}
    BOOL added = NO;
    if ([bubble isKindOfClass:[NSString class]] && [(NSString *)bubble length]) {
        id item = SoulMenuItem(itemCls, @"复制文本", tools, @selector(soulCopyText));
        if (item) { [items addObject:item]; added = YES; }
    } else if ([audio isKindOfClass:[NSString class]] && [(NSString *)audio length]) {
        id item = SoulMenuItem(itemCls, @"复制转写文字", tools, @selector(soulCopyVoiceText));
        if (item) { [items addObject:item]; added = YES; }
    }
    if (voice) {
        id item = SoulMenuItem(itemCls, @"保存语音", tools, @selector(soulSaveVoice));
        if (item) { [items addObject:item]; added = YES; }
    }
    SEL setSel = NSSelectorFromString(@"setMenuItems:");
    if (added && [mc respondsToSelector:setSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(mc, setSel, items);
        SoulLog(@"menu: appended custom items total=%lu", (unsigned long)items.count);
    }
}

// —— P. 语音消息自动转文字（复用 cell 自带转写按钮）——
static NSMutableSet<NSString *> *gVoiceTextTried = nil;

static void SoulMaybeAutoVoiceText(id cell, id layout) {
    if (!SoulDef(kFxAutoVoiceText)) return;
    NSString *className = NSStringFromClass([cell class]);
    if (![className containsString:@"Audio"]) return;
    id msg = nil;
    SEL msgSel = NSSelectorFromString(@"message");
    if (layout && [layout respondsToSelector:msgSel]) {
        msg = ((id (*)(id, SEL))objc_msgSend)(layout, msgSel);
    }
    if (!msg) return;
    NSString *existing = nil;
    @try { existing = [msg valueForKey:@"audioText"]; } @catch (__unused NSException *e) {}
    if ([existing isKindOfClass:[NSString class]] && existing.length) return;
    NSString *mid = nil;
    @try { mid = [[msg valueForKey:@"msgId"] description]; } @catch (__unused NSException *e) {}
    if (!mid.length) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gVoiceTextTried = [NSMutableSet set]; });
    @synchronized (gVoiceTextTried) {
        if ([gVoiceTextTried containsObject:mid]) return;
        if (gVoiceTextTried.count > 300) [gVoiceTextTried removeAllObjects];
        [gVoiceTextTried addObject:mid];
    }
    SEL btnSel = NSSelectorFromString(@"convertVoiceBtn");
    if (![cell respondsToSelector:btnSel]) return;
    id btn = ((id (*)(id, SEL))objc_msgSend)(cell, btnSel);
    if (![btn isKindOfClass:[UIControl class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SoulDef(kFxAutoVoiceText)) return;
        [(UIControl *)btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        SoulLog(@"voice-text: auto convert msg=%@", mid);
    });
}

// —— I. 每条消息显示时间（按 cell 类分别 hook）——
static const void *kSoulMsgTimeLabelKey = &kSoulMsgTimeLabelKey;

static NSString *SoulMsgTimePattern(void) {
    NSString *fmt = SoulCfgString(kFxMsgTimeFmt);
    return fmt.length ? fmt : @"HH:mm";
}

static NSString *SoulMsgTimeText(long long ms) {
    static NSDateFormatter *formatter = nil;
    static NSString *pattern = nil;
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.timeZone = [NSTimeZone localTimeZone];
        lock = [NSLock new];
    });
    NSString *pat = SoulMsgTimePattern();
    [lock lock];
    if (![pattern isEqualToString:pat]) {
        formatter.dateFormat = pat;
        pattern = [pat copy];
    }
    NSString *text = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)ms / 1000.0]];
    [lock unlock];
    return text ?: @"";
}

static long long SoulMsgTimestamp(id msg) {
    static int missLogged = 0;
    long long ms = 0;
    NSArray<NSString *> *names = @[@"timestamp", @"sendTime", @"msgTime", @"createTime", @"time"];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![msg respondsToSelector:sel]) continue;
        @try {
            NSMethodSignature *sig = [msg methodSignatureForSelector:sel];
            const char *type = sig.methodReturnType;
            if (!type) continue;
            if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'i' || type[0] == 'I') {
                ms = ((long long (*)(id, SEL))objc_msgSend)(msg, sel);
            } else if (type[0] == 'd' || type[0] == 'f') {
                double d = ((double (*)(id, SEL))objc_msgSend)(msg, sel);
                ms = (long long)(d > 100000000000.0 ? d : d * 1000.0);
            } else if (type[0] == '@') {
                id v = ((id (*)(id, SEL))objc_msgSend)(msg, sel);
                if ([v isKindOfClass:[NSNumber class]]) ms = [v longLongValue];
                else if ([v isKindOfClass:[NSString class]]) ms = [v longLongValue];
                else if ([v isKindOfClass:[NSDate class]]) ms = (long long)([(NSDate *)v timeIntervalSince1970] * 1000.0);
            }
        } @catch (__unused NSException *e) {}
        if (ms > 0) break;
    }
    if (ms > 0 && ms < 100000000000LL) ms *= 1000;
    if (ms <= 0 && missLogged < 4) {
        missLogged++;
        NSMutableArray *have = [NSMutableArray array];
        for (NSString *name in names) if ([msg respondsToSelector:NSSelectorFromString(name)]) [have addObject:name];
        SoulLog(@"msg-time: no timestamp cls=%@ selectors=%@", NSStringFromClass([msg class]), have);
    }
    return ms;
}

static void SoulMsgTimePlace(id cell, double height, double width) {
    UILabel *label = objc_getAssociatedObject(cell, kSoulMsgTimeLabelKey);
    if (!label || label.hidden) return;
    UIView *view = (UIView *)cell;
    if (width < 1) width = view.bounds.size.width;
    if (width < 1) width = UIScreen.mainScreen.bounds.size.width;
    if (height < 20) height = view.bounds.size.height;
    if (height < 20) height = 60;

    const CGFloat h = 11;
    CGFloat maxW = MAX(40.0, width - 24.0);
    CGSize fit = [label sizeThatFits:CGSizeMake(maxW, h)];
    CGFloat lw = MIN(MAX(fit.width + 2.0, 40.0), maxW);

    SEL bs = NSSelectorFromString(@"bubbleView");
    UIView *bubble = nil;
    if ([cell respondsToSelector:bs]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(cell, bs);
        if ([v isKindOfClass:[UIView class]]) bubble = v;
    }
    CGRect bf = CGRectZero;
    if (bubble) bf = [bubble convertRect:bubble.bounds toView:view];

    BOOL hasBadge = ([cell viewWithTag:kSoulRecallBadgeTag] != nil);
    CGFloat y = 0;
    if (bf.size.height > 0) {
        if (hasBadge) {
            y = bf.origin.y - h - 1;
        } else {
            y = CGRectGetMaxY(bf) + 1;
            if (y + h > height - 1) y = bf.origin.y - h - 1;
        }
    } else {
        y = height - h - 1;
    }
    y = MAX(0, MIN(y, height - h - 1));

    CGFloat x = (label.tag == 1) ? (width - lw - 14) : 14;
    if (bf.size.width > 0) {
        x = (label.tag == 1) ? (CGRectGetMaxX(bf) - lw) : bf.origin.x;
    }
    x = MAX(6, MIN(x, width - lw - 6));
    label.frame = CGRectMake(x, y, lw, h);
    label.textAlignment = (label.tag == 1) ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

static void SoulApplyMsgTime(id cell, id layout) {
    UILabel *label = objc_getAssociatedObject(cell, kSoulMsgTimeLabelKey);
    if (!SoulDef(kFxMsgTime)) { label.hidden = YES; return; }

    id candidates[3] = {layout, nil, nil};
    if (layout && [layout respondsToSelector:NSSelectorFromString(@"message")]) {
        candidates[1] = ((id (*)(id, SEL))objc_msgSend)(layout, NSSelectorFromString(@"message"));
    }
    if (layout && [layout respondsToSelector:NSSelectorFromString(@"item")]) {
        candidates[2] = ((id (*)(id, SEL))objc_msgSend)(layout, NSSelectorFromString(@"item"));
    }
    id msg = nil;
    long long ms = 0;
    for (int i = 0; i < 3; i++) {
        if (!candidates[i]) continue;
        long long t = SoulMsgTimestamp(candidates[i]);
        if (t > 0) { msg = candidates[i]; ms = t; break; }
    }
    if (!msg) {
        static int nilLogged = 0;
        if (nilLogged < 3) {
            nilLogged++;
            SoulLog(@"msg-time: no timestamp layout=%@ message=%@",
                    NSStringFromClass([layout class]),
                    candidates[1] ? NSStringFromClass([candidates[1] class]) : @"nil");
        }
        label.hidden = YES;
        return;
    }
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = [UIFont systemFontOfSize:9.5];
        label.textColor = [UIColor secondaryLabelColor];
        label.userInteractionEnabled = NO;
        [cell addSubview:label];
        objc_setAssociatedObject(cell, kSoulMsgTimeLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL mine = NO;
    SEL fm = NSSelectorFromString(@"fromMine");
    @try {
        if ([msg respondsToSelector:fm]) mine = ((BOOL (*)(id, SEL))objc_msgSend)(msg, fm);
    } @catch (__unused NSException *e) {}
    label.tag = mine ? 1 : 0;
    label.text = SoulMsgTimeText(ms);
    label.hidden = NO;
    double h = 0;
    SEL hSel = NSSelectorFromString(@"cellHeight");
    if (layout && [layout respondsToSelector:hSel]) {
        h = ((double (*)(id, SEL))objc_msgSend)(layout, hSel);
    }
    if (h < 20) h = ((UIView *)cell).bounds.size.height;
    if (h < 20) h = 60;
    SoulMsgTimePlace(cell, h, ((UIView *)cell).bounds.size.width);
    static int shownLogged = 0;
    if (shownLogged < 3) {
        shownLogged++;
        SoulLog(@"msg-time: label %@ cls=%@ frame=%@", label.text,
                NSStringFromClass([msg class]), NSStringFromCGRect(label.frame));
    }
}

/* 每个 cell 类一份 hook 函数、一份原实现槽：
   子类实现里调 [super ...] 会进入父类的 hook，各自调用自己的原实现，不会递归爆栈。 */
static IMP gMsgCfgOrig[12] = {0};
static IMP gMsgPrepOrig[12] = {0};
static int gMsgCfgCount = 0;
static int gMsgPrepCount = 0;
static void *gMsgCfgHooks[12] = {0};
static void *gMsgPrepHooks[12] = {0};

static void SoulMaybeAutoVoiceText(id cell, id layout);

#define SOUL_MSG_CFG_HOOK(N) \
static void SoulMsgCfgHook##N(id self, SEL _cmd, id layout) { \
    IMP orig = gMsgCfgOrig[N]; \
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, layout); \
    SoulApplyMsgTime(self, layout); \
    SoulMaybeAutoVoiceText(self, layout); \
}
SOUL_MSG_CFG_HOOK(0)  SOUL_MSG_CFG_HOOK(1)  SOUL_MSG_CFG_HOOK(2)
SOUL_MSG_CFG_HOOK(3)  SOUL_MSG_CFG_HOOK(4)  SOUL_MSG_CFG_HOOK(5)
SOUL_MSG_CFG_HOOK(6)  SOUL_MSG_CFG_HOOK(7)  SOUL_MSG_CFG_HOOK(8)
SOUL_MSG_CFG_HOOK(9)  SOUL_MSG_CFG_HOOK(10) SOUL_MSG_CFG_HOOK(11)

#define SOUL_MSG_PREP_HOOK(N) \
static void SoulMsgPrepHook##N(id self, SEL _cmd, id cell, id layout) { \
    IMP orig = gMsgPrepOrig[N]; \
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, cell, layout); \
    id target = [cell isKindOfClass:[UIView class]] ? cell : self; \
    SoulApplyMsgTime(target, layout); \
    SoulMaybeAutoVoiceText(target, layout); \
}
SOUL_MSG_PREP_HOOK(0)  SOUL_MSG_PREP_HOOK(1)  SOUL_MSG_PREP_HOOK(2)
SOUL_MSG_PREP_HOOK(3)  SOUL_MSG_PREP_HOOK(4)  SOUL_MSG_PREP_HOOK(5)
SOUL_MSG_PREP_HOOK(6)  SOUL_MSG_PREP_HOOK(7)  SOUL_MSG_PREP_HOOK(8)
SOUL_MSG_PREP_HOOK(9)  SOUL_MSG_PREP_HOOK(10) SOUL_MSG_PREP_HOOK(11)

static BOOL SoulIsOneOfHooks(IMP imp, void **hooks, int count) {
    for (int i = 0; i < count; i++) if (hooks[i] == (void *)imp) return YES;
    return NO;
}

static BOOL SoulAssignMsgHook(NSString *className, NSString *selName, void **hooks,
                              IMP *origSlots, int *counter, int maxCount) {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (SoulIsOneOfHooks(method_getImplementation(m), hooks, *counter)) return YES;
    if (*counter >= maxCount) return NO;
    int idx = (*counter)++;
    IMP orig = NULL;
    if (!SoulInstallMethodHook(cls, sel, (IMP)hooks[idx], &orig) || !orig) return NO;
    origSlots[idx] = orig;
    return YES;
}

static double (*gOrigMsgCellHeight)(id, SEL);
static double SoulHookMsgCellHeight(id self, SEL _cmd) {
    double h = gOrigMsgCellHeight ? gOrigMsgCellHeight(self, _cmd) : 0;
    return h + (SoulDef(kFxMsgTime) ? 13.0 : 0.0);
}

static BOOL SoulInstallMsgTimeHooks(void) {
    static BOOL done = NO;
    if (done) return YES;
    Class layout = objc_getClass("SODCMsgLayout");
    if (!layout) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMsgCfgHooks[0] = SoulMsgCfgHook0;   gMsgCfgHooks[1] = SoulMsgCfgHook1;
        gMsgCfgHooks[2] = SoulMsgCfgHook2;   gMsgCfgHooks[3] = SoulMsgCfgHook3;
        gMsgCfgHooks[4] = SoulMsgCfgHook4;   gMsgCfgHooks[5] = SoulMsgCfgHook5;
        gMsgCfgHooks[6] = SoulMsgCfgHook6;   gMsgCfgHooks[7] = SoulMsgCfgHook7;
        gMsgCfgHooks[8] = SoulMsgCfgHook8;   gMsgCfgHooks[9] = SoulMsgCfgHook9;
        gMsgCfgHooks[10] = SoulMsgCfgHook10; gMsgCfgHooks[11] = SoulMsgCfgHook11;
        gMsgPrepHooks[0] = SoulMsgPrepHook0;   gMsgPrepHooks[1] = SoulMsgPrepHook1;
        gMsgPrepHooks[2] = SoulMsgPrepHook2;   gMsgPrepHooks[3] = SoulMsgPrepHook3;
        gMsgPrepHooks[4] = SoulMsgPrepHook4;   gMsgPrepHooks[5] = SoulMsgPrepHook5;
        gMsgPrepHooks[6] = SoulMsgPrepHook6;   gMsgPrepHooks[7] = SoulMsgPrepHook7;
        gMsgPrepHooks[8] = SoulMsgPrepHook8;   gMsgPrepHooks[9] = SoulMsgPrepHook9;
        gMsgPrepHooks[10] = SoulMsgPrepHook10; gMsgPrepHooks[11] = SoulMsgPrepHook11;
    });
    NSArray<NSString *> *configClasses = @[
        @"SODCMsgCell",
        @"SOPrivateChatTableViewCell",
        @"SOCRBaseAvatarMessageCell",
        @"SOChatRoomBaseMessageCell",
        @"SOGCMsgBaseCell",
        @"SOChatPhotoExchangeCell",
        @"SOChatRoomRoomLevelCell",
        @"SOLittleAssistantNoticeCell",
    ];
    NSArray<NSString *> *prepareClasses = @[
        @"SODCMsgCell",
        @"SOPrivateChatTableViewCell",
        @"SOCRBaseAvatarMessageCell",
        @"SOChatRoomBaseMessageCell",
        @"SOGCMsgBaseCell",
        @"SOChatSystemHintMessageTableViewCell",
        @"SOChatUserBackMetionTableViewCell",
        @"SODiceGameMessageTableViewCell",
        @"SOMetaPopMessageCell",
        @"SOPCQuestionCell",
        @"SOPCSignalDetailCell",
    ];
    BOOL any = NO;
    for (NSString *name in configClasses) {
        any |= SoulAssignMsgHook(name, @"configWithMsgLayout:", gMsgCfgHooks, gMsgCfgOrig, &gMsgCfgCount, 12);
    }
    for (NSString *name in prepareClasses) {
        any |= SoulAssignMsgHook(name, @"prepareCell:withMsgLayout:", gMsgPrepHooks, gMsgPrepOrig, &gMsgPrepCount, 12);
    }
    any |= SoulInstallMethodHook(layout, NSSelectorFromString(@"cellHeight"),
                                 (IMP)SoulHookMsgCellHeight, (IMP *)&gOrigMsgCellHeight);
    if (any) {
        done = YES;
        SoulLog(@"msg-time: hooks installed config=%d prepare=%d height=%d",
                gMsgCfgCount, gMsgPrepCount, gOrigMsgCellHeight != NULL);
    }
    return any;
}

// —— J. 青少年弹窗（SOMainSquareViewController / SOPrivateChatViewController）——
static BOOL SoulTeenOff(void) { return SoulDef(kFxNoTeenPopup); }

static void (*gOrigTeenYoungAlert)(id, SEL);
static void SoulHookTeenYoungAlert(id self, SEL _cmd) {
    if (SoulTeenOff()) { SoulLog(@"teen: showYoungAlert suppressed"); return; }
    if (gOrigTeenYoungAlert) gOrigTeenYoungAlert(self, _cmd);
}

static void (*gOrigTeenYoungAlertDone)(id, SEL, id);
static void SoulHookTeenYoungAlertDone(id self, SEL _cmd, id done) {
    if (!SoulTeenOff()) {
        if (gOrigTeenYoungAlertDone) gOrigTeenYoungAlertDone(self, _cmd, done);
        return;
    }
    SoulLog(@"teen: showYoungAlertWithCompletion: suppressed");
    SoulRunBlock(done, nil);
}

static void (*gOrigTeenYoungPopDone)(id, SEL, id);
static void SoulHookTeenYoungPopDone(id self, SEL _cmd, id done) {
    if (!SoulTeenOff()) {
        if (gOrigTeenYoungPopDone) gOrigTeenYoungPopDone(self, _cmd, done);
        return;
    }
    SoulLog(@"teen: showYoungPopViewWithCompletion: suppressed");
    SoulRunBlock(done, nil);
}

static void (*gOrigTeenYoungPopDoneQ)(id, SEL, id, BOOL);
static void SoulHookTeenYoungPopDoneQ(id self, SEL _cmd, id done, BOOL useGlobalQ) {
    if (!SoulTeenOff()) {
        if (gOrigTeenYoungPopDoneQ) gOrigTeenYoungPopDoneQ(self, _cmd, done, useGlobalQ);
        return;
    }
    SoulLog(@"teen: showYoungPopViewWithCompletion:useGlobalQ: suppressed");
    SoulRunBlock(done, nil);
}

static void (*gOrigTeenNotion)(id, SEL, id, id, id);
static void SoulHookTeenNotion(id self, SEL _cmd, id arg1, id arg2, id closeHandler) {
    if (!SoulTeenOff()) {
        if (gOrigTeenNotion) gOrigTeenNotion(self, _cmd, arg1, arg2, closeHandler);
        return;
    }
    SoulLog(@"teen: teenager notion popup suppressed");
    SoulRunBlock(closeHandler, nil);
}

static void (*gOrigTeenGuideDone)(id, SEL, id);
static void SoulHookTeenGuideDone(id self, SEL _cmd, id done) {
    if (!SoulTeenOff()) {
        if (gOrigTeenGuideDone) gOrigTeenGuideDone(self, _cmd, done);
        return;
    }
    SoulLog(@"teen: newTeenagerNotionGuide suppressed");
    SoulRunBlock(done, nil);
}

static void (*gOrigTeenQueueYoungAlert)(id, SEL, id, id, id);
static void SoulHookTeenQueueYoungAlert(id self, SEL _cmd, id arg1, id arg2, id closeHandler) {
    if (!SoulTeenOff()) {
        if (gOrigTeenQueueYoungAlert) gOrigTeenQueueYoungAlert(self, _cmd, arg1, arg2, closeHandler);
        return;
    }
    SoulLog(@"teen: queued young alert suppressed");
    SoulRunBlock(closeHandler, nil);
}

static void (*gOrigTeenQueueAnswer)(id, SEL, id, id, id);
static void SoulHookTeenQueueAnswer(id self, SEL _cmd, id answerDone, id arg2, id closeHandler) {
    if (!SoulTeenOff()) {
        if (gOrigTeenQueueAnswer) gOrigTeenQueueAnswer(self, _cmd, answerDone, arg2, closeHandler);
        return;
    }
    SoulLog(@"teen: queued young answer page suppressed");
    SoulRunBlock(closeHandler, nil);
}

static BOOL (*gOrigTeenChatAlert)(id, SEL);
static BOOL SoulHookTeenChatAlert(id self, SEL _cmd) {
    if (SoulTeenOff()) { SoulLog(@"teen: private-chat teen alert suppressed"); return NO; }
    return gOrigTeenChatAlert ? gOrigTeenChatAlert(self, _cmd) : NO;
}

static BOOL SoulInstallTeenHooks(void) {
    static BOOL done = NO;
    if (done) return YES;
    BOOL ok = NO;
    Class sq = objc_getClass("SOMainSquareViewController");
    if (sq) {
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"showYoungAlert"),
                                    (IMP)SoulHookTeenYoungAlert, (IMP *)&gOrigTeenYoungAlert);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"showYoungAlertWithCompletion:"),
                                    (IMP)SoulHookTeenYoungAlertDone, (IMP *)&gOrigTeenYoungAlertDone);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"showYoungPopViewWithCompletion:"),
                                    (IMP)SoulHookTeenYoungPopDone, (IMP *)&gOrigTeenYoungPopDone);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"showYoungPopViewWithCompletion:useGlobalQ:"),
                                    (IMP)SoulHookTeenYoungPopDoneQ, (IMP *)&gOrigTeenYoungPopDoneQ);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"globalQueueShowTeenagerNotionPopupView:alertItem:closeHandler:"),
                                    (IMP)SoulHookTeenNotion, (IMP *)&gOrigTeenNotion);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"showNewTeenagerNotionGuideWithCompletion:"),
                                    (IMP)SoulHookTeenGuideDone, (IMP *)&gOrigTeenGuideDone);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"globalAlertQueueShowYoungAlert:alertItem:closeHandler:"),
                                    (IMP)SoulHookTeenQueueYoungAlert, (IMP *)&gOrigTeenQueueYoungAlert);
        ok |= SoulInstallMethodHook(sq, NSSelectorFromString(@"globalAlertQueueShowYoungAnwserPageWithCompletion:alertItem:closeHandler:"),
                                    (IMP)SoulHookTeenQueueAnswer, (IMP *)&gOrigTeenQueueAnswer);
    }
    Class pc = objc_getClass("SOPrivateChatViewController");
    if (pc) {
        ok |= SoulInstallMethodHook(pc, NSSelectorFromString(@"showTeenagerModeAlert"),
                                    (IMP)SoulHookTeenChatAlert, (IMP *)&gOrigTeenChatAlert);
    }
    if (ok) {
        done = YES;
        SoulLog(@"teen: hooks installed (notice=%d chat=%d)",
                gOrigTeenNotion != NULL, gOrigTeenChatAlert != NULL);
    }
    return ok;
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
    if (!SoulSkipGroup(@"blockread")) SoulRetryInstall(^BOOL{ return SoulInstallBlockReadHooks(); }, 12);
    if (!SoulSkipGroup(@"autoread")) SoulRetryInstall(^BOOL{ return SoulInstallAutoReadHooks(); }, 12);
    if (!SoulSkipGroup(@"closefriend")) SoulRetryInstall(^BOOL{ return SoulInstallCloseFriendHooks(); }, 12);
    if (!SoulSkipGroup(@"voice")) SoulRetryInstall(^BOOL{ return SoulInstallVoiceHooks(); }, 12);
    if (!SoulSkipGroup(@"msgtime") || !SoulSkipGroup(@"autovoice")) SoulRetryInstall(^BOOL{ return SoulInstallMsgTimeHooks(); }, 24);
    if (!SoulSkipGroup(@"teen")) SoulRetryInstall(^BOOL{ return SoulInstallTeenHooks(); }, 24);
    if (!SoulSkipGroup(@"screenshot")) SoulRetryInstall(^BOOL{ return SoulInstallScreenshotHooks(); }, 15);
    if (!SoulSkipGroup(@"ads")) SoulRetryInstall(^BOOL{ return SoulInstallAdHooks(); }, 15);
    SoulRetryInstall(^BOOL{ return SoulInstallTabHooks(); }, 24);
    SoulInstallClearNotif();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SoulSyncLoveBellPatch(); });
    SoulLog(@"skip=%d", (int)(SoulSkipText().length > 0));
    SoulLog(@"loaded v26. dice=%d snapUnlock=%d msgTime=%d teenOff=%d adsOff=%d",
            (int)SoulDiceOn(), (int)SoulDef(kFxSnapUnlock),
            (int)SoulDef(kFxMsgTime), (int)SoulDef(kFxNoTeenPopup),
            (int)SoulDef(kFxNoAds));
}
