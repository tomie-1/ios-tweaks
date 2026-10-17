//
//  KGYouthLiteTweak.m — 酷狗概念版（com.kugou.kgyouth）精简
//
//  只做三件事，全部基于 App 自己的属性/方法：
//   1. 播放页（YouthAlbumPlayPageController）隐藏推广元素：
//      watchVideoAdButton / listenFreeButton / listenFreeLoginButton / channelInfoView，
//      并让 showWatchVideoToVipTip 不弹提示；
//   2. 双指长按任意位置 → 调 YouthNewBarView 自己的 hideNormalUI / showNormalUI，精简底栏；
//   3. 跳过开屏：KGSplashAndGuideViewManager -checkCanShowSplash 返回 NO。
//
//  刻意不做的事：不调用 playControl / clickPlayOrPause:，因此不会触发任何自动播放；
//  不改"看视频领 VIP"的业务逻辑；不做大专辑面板。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSMutableString *gLog;
static void KYLog(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!gLog) gLog = [NSMutableString string];
        [gLog appendFormat:@"%@\n", line];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kgyouthlite.log"];
        [gLog writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

static NSString *const kEnabledKey = @"com.tomie.kgyouthlite.enabled";

static BOOL kyEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
    return v ? [v boolValue] : YES;
}

#pragma mark - 播放页推广元素

static void kyHidePromos(id vc) {
    if (!vc) return;
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"watchVideoAdButton", @"listenFreeButton",
                 @"listenFreeLoginButton", @"channelInfoView"];
    });
    for (NSString *k in keys) {
        @try {
            id v = [vc valueForKey:k];
            if ([v isKindOfClass:[UIView class]]) {
                ((UIView *)v).hidden = YES;
                KYLog(@"[hide] %@ -> %@ hidden", k, NSStringFromClass([v class]));
            } else {
                KYLog(@"[hide] %@ -> %@", k, v ? NSStringFromClass([v class]) : @"(nil)");
            }
        } @catch (NSException *e) { KYLog(@"[hide] %@ 异常 %@", k, e.name); }
    }
}

static IMP o_viewDidLoad, o_refreshVipUI, o_refreshActive, o_showTip, o_refreshPlayState, o_refreshTopStatusBar;
static IMP o_checkSplash, o_showSplash;

static void h_viewDidLoad(id self, SEL _cmd) {
    ((void (*)(id, SEL))o_viewDidLoad)(self, _cmd);
    kyHidePromos(self);
}
static void h_refreshVipUI(id self, SEL _cmd) {
    ((void (*)(id, SEL))o_refreshVipUI)(self, _cmd);
    kyHidePromos(self);
}
static void h_refreshActive(id self, SEL _cmd, BOOL active) {
    ((void (*)(id, SEL, BOOL))o_refreshActive)(self, _cmd, active);
    kyHidePromos(self);          // 仅隐藏推广；不碰 playControl / clickPlayOrPause:
}
static void h_refreshPlayState(id self, SEL _cmd) {
    ((void (*)(id, SEL))o_refreshPlayState)(self, _cmd);
    kyHidePromos(self);
}
static void h_refreshTopStatusBar(id self, SEL _cmd) {
    ((void (*)(id, SEL))o_refreshTopStatusBar)(self, _cmd);
    kyHidePromos(self);
}

static void h_showTip(id self, SEL _cmd) { /* 不弹“看视频领 VIP”提示 */ }

static BOOL h_checkSplash(id self, SEL _cmd) { return NO; }
static void h_showSplash(id self, SEL _cmd, id opt) { /* 不展示开屏 */ }

#pragma mark - 双指长按：底栏精简

static UIView *kyFindView(UIView *root, NSString *clsName, int depth) {
    if (!root || depth > 40) return nil;
    Class want = NSClassFromString(clsName);
    if (want && [root isKindOfClass:want]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = kyFindView(sub, clsName, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIWindow *kyKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

@interface KYToggle : NSObject
@end

@implementation KYToggle
- (void)onTwoFingerLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIWindow *w = kyKeyWindow();
    UIView *bar = kyFindView(w, @"YouthNewBarView", 0);
    KYLog(@"[bar] 查找 YouthNewBarView -> %@", bar ? NSStringFromClass([bar class]) : @"(nil)");
    if (!bar) return;
    static BOOL hidden = NO;
    hidden = !hidden;
    SEL sel = NSSelectorFromString(hidden ? @"hideNormalUI" : @"showNormalUI");
    KYLog(@"[bar] 调用 %@", hidden ? @"hideNormalUI" : @"showNormalUI");
    if ([bar respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(bar, sel);
        UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
        [fg notificationOccurred:hidden ? UINotificationFeedbackTypeSuccess
                                       : UINotificationFeedbackTypeWarning];
    }
}
@end

static KYToggle *gToggle;

static void kyInstallGesture(void) {
    UIWindow *w = kyKeyWindow();
    if (!w || !gToggle) return;
    for (UIGestureRecognizer *g in w.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]] &&
            ((UILongPressGestureRecognizer *)g).numberOfTouchesRequired == 2 &&
            g.delegate == (id)gToggle) return;      // 已安装
    }
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gToggle action:@selector(onTwoFingerLongPress:)];
    lp.numberOfTouchesRequired = 2;
    lp.minimumPressDuration = 0.45;
    lp.cancelsTouchesInView = NO;
    [w addGestureRecognizer:lp];
}

#pragma mark - 安装

__attribute__((constructor)) static void kgyouthlite_init(void) {
    @try {
        // 杀掉通知（不在 App 外弹提示）
        (void)0;
    } @catch (NSException *e) {}

    KYLog(@"=== KGYouthLite 加载 %@ ===", [[NSBundle mainBundle] bundleIdentifier]);
    if (!kyEnabled()) { KYLog(@"[init] 开关关闭"); return; }

    Class pc = objc_getClass("YouthAlbumPlayPageController");
    Method m;
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("viewDidLoad")))) {
        o_viewDidLoad = method_getImplementation(m); method_setImplementation(m, (IMP)h_viewDidLoad);
    }
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("refreshVipUI")))) {
        o_refreshVipUI = method_getImplementation(m); method_setImplementation(m, (IMP)h_refreshVipUI);
    }
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("refreshActiveStatus:")))) {
        o_refreshActive = method_getImplementation(m); method_setImplementation(m, (IMP)h_refreshActive);
    }
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("refreshPlayState")))) {
        o_refreshPlayState = method_getImplementation(m); method_setImplementation(m, (IMP)h_refreshPlayState);
    }
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("refreshTopStatusBar")))) {
        o_refreshTopStatusBar = method_getImplementation(m); method_setImplementation(m, (IMP)h_refreshTopStatusBar);
    }
    if (pc && (m = class_getInstanceMethod(pc, sel_registerName("showWatchVideoToVipTip")))) {
        o_showTip = method_getImplementation(m); method_setImplementation(m, (IMP)h_showTip);
    }

    Class sm = objc_getClass("KGSplashAndGuideViewManager");
    if (sm && (m = class_getInstanceMethod(sm, sel_registerName("checkCanShowSplash")))) {
        o_checkSplash = method_getImplementation(m); method_setImplementation(m, (IMP)h_checkSplash);
    }
    if (sm && (m = class_getInstanceMethod(sm, sel_registerName("showSplashOrGuideViewWithLaunchOption:")))) {
        o_showSplash = method_getImplementation(m); method_setImplementation(m, (IMP)h_showSplash);
    }

    KYLog(@"[init] 安装完成: 播放页=%@ 开屏=%@", pc ? @"有" : @"无", sm ? @"有" : @"无");
    gToggle = [[KYToggle alloc] init];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"UIWindowDidBecomeKeyNotification"
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ kyInstallGesture(); });
    }];
}
