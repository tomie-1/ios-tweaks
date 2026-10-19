//
//  TFDevicesTweak.m — TestFlight 设备管理
//  从 App 自己的 sessionContext.deviceManager 取设备列表（含 tvOS 等其它平台），
//  列出名称/型号/平台，并可逐个移除（走 TFDeviceManager -removeDevices:completionBlock:）。
//
//  说明：只调用 App 自己的对象与接口，不改它的界面；调用前都做 exists/类型编码检查。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 日志

static NSMutableString *gLog;
static NSString *docPath(NSString *n) {
    return [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:n]];
}
static void LOGS(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!gLog) gLog = [NSMutableString string];
        [gLog appendFormat:@"%@\n", s];
        [gLog writeToFile:docPath(@"tfdevices.log") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

#pragma mark - 安全的动态调用（按方法返回类型决定怎么调，避免把 int 当对象）

static SEL tfSel(NSString *n) { return NSSelectorFromString(n); }

static id idSafe(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = tfSel(selName);
    if (![obj respondsToSelector:s]) return nil;
    Method m = class_getInstanceMethod([obj class], s);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || enc[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, s); } @catch (NSException *e) { return nil; }
}
static NSString *strSafe(id obj, NSString *selName) {
    @try { id v = idSafe(obj, selName); return v ? [v description] : @""; } @catch (NSException *e) { return @""; }
}
static NSInteger intSafe(id obj, NSString *selName) {
    if (!obj) return -1;
    SEL s = tfSel(selName);
    if (![obj respondsToSelector:s]) return -1;
    Method m = class_getInstanceMethod([obj class], s);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc) return -1;
    if (enc[0] == 'q' || enc[0] == 'Q' || enc[0] == 'l' || enc[0] == 'L' || enc[0] == 'i' || enc[0] == 'I' || enc[0] == 'B' || enc[0] == 'c')
        @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, s); } @catch (NSException *e) { return -1; }
    return -1;
}

#pragma mark - 捕获 App 的会话与设备管理器

static id gAppList, gSession, gDeviceMgr;
static NSArray *gDevices;
static BOOL gSkipAsync;

@interface OASAppList : NSObject
- (instancetype)initWithSessionContext:(id)ctx;
- (instancetype)initWithAppCatalogManager:(id)mgr;
- (id)sessionContext;
@end

static IMP gOrigInitCtx, gOrigInitMgr;
static id tf_initCtx(id self, SEL _cmd, id ctx) {
    id r = ((id (*)(id, SEL, id))gOrigInitCtx)(self, _cmd, ctx);
    if (r) gAppList = r;
    return r;
}
static id tf_initMgr(id self, SEL _cmd, id mgr) {
    id r = ((id (*)(id, SEL, id))gOrigInitMgr)(self, _cmd, mgr);
    if (r) gAppList = r;
    return r;
}

static void dumpMethods(NSString *clsName, int limit) {
    Class c = objc_getClass(clsName.UTF8String);
    if (!c) { LOGS(@"[api] 没有类 %@", clsName); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    LOGS(@"[api] %@ 实例方法 %u 个", clsName, n);
    for (unsigned int i = 0; i < n && (int)i < limit; i++)
        LOGS(@"[api]   - %s  %s", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]) ?: "?");
    if (ms) free(ms);
    unsigned int cn = 0;
    Method *cms = class_copyMethodList(object_getClass(c), &cn);
    if (cn) {
        LOGS(@"[api] %@ 类方法 %u 个", clsName, cn);
        for (unsigned int i = 0; i < cn && (int)i < 12; i++)
            LOGS(@"[api]   + %s  %s", sel_getName(method_getName(cms[i])), method_getTypeEncoding(cms[i]) ?: "?");
    }
    if (cms) free(cms);
}

static NSArray *candidateSelectors(void) {
    return @[@"devices", @"allDevices", @"deviceList", @"cachedDevices", @"currentDevice",
             @"registeredDevices", @"otherDevices", @"deviceInfos", @"managedDevices"];
}

static void logDevices(NSArray *devs, NSString *src) {
    LOGS(@"[dev] 来自 %@，设备数 %lu", src, (unsigned long)devs.count);
    int i = 0;
    for (id d in devs) {
        LOGS(@"[dev] #%d 类=%@ name=%@ deviceName=%@ model=%@ deviceModel=%@ platform=%@ os=%@ udid=%@ identifier=%@",
             i++, NSStringFromClass([d class]),
             strSafe(d, @"name"), strSafe(d, @"deviceName"), strSafe(d, @"model"), strSafe(d, @"deviceModel"),
             strSafe(d, @"platform"), strSafe(d, @"osVersion"), strSafe(d, @"udid"), strSafe(d, @"identifier"));
        LOGS(@"[dev]     ints: platform=%ld type=%ld state=%ld deviceClass=%ld",
             (long)intSafe(d, @"platform"), (long)intSafe(d, @"deviceType"),
             (long)intSafe(d, @"state"), (long)intSafe(d, @"deviceClass"));
        if (i == 1) dumpMethods(NSStringFromClass([d class]), 60);
    }
}

#pragma mark - 取设备列表

static void reloadDevices(void (^done)(void)) {
    @try {
        if (!gSession) gSession = idSafe(gAppList, @"sessionContext");
        if (!gDeviceMgr) gDeviceMgr = idSafe(gSession, @"deviceManager");
        LOGS(@"[dev] appList=%@ session=%@ deviceManager=%@ (%@)",
             NSStringFromClass([gAppList class]), NSStringFromClass([gSession class]),
             NSStringFromClass([gDeviceMgr class]),
             gDeviceMgr ? NSStringFromClass([gDeviceMgr class]) : @"nil");
        if (!gDeviceMgr) { if (done) done(); return; }

        static BOOL dumped = NO;
        if (!dumped) {
            dumped = YES;
            dumpMethods(@"TFDeviceManager", 80);
            dumpMethods(@"TFCurrentDevice", 40);
        }

        // 1) 同步 getter
        for (NSString *sel in candidateSelectors()) {
            id v = idSafe(gDeviceMgr, sel);
            if (!v) continue;
            NSArray *arr = [v isKindOfClass:[NSArray class]] ? v : @[v];
            LOGS(@"[dev] 试 %@ → %@ (%lu)", sel, NSStringFromClass([v class]),
                 (unsigned long)([v isKindOfClass:[NSArray class]] ? [v count] : 1));
            if (arr.count) { gDevices = arr; logDevices(arr, sel); if (done) done(); return; }
        }
        // 2) 异步式刷新：回调签名未知，这里只传一个“无参 block”做完成通知（多传的参数会被忽略，安全）
        if (!gSkipAsync) {
            for (NSString *sel in @[@"fetchDevicesWithCompletion:", @"refreshDevicesWithCompletion:",
                                    @"getDevicesWithCompletion:", @"loadDevicesWithCompletion:",
                                    @"fetchAllDevicesWithCompletion:", @"refreshWithCompletion:"]) {
                SEL s2 = tfSel(sel);
                if (![gDeviceMgr respondsToSelector:s2]) continue;
                LOGS(@"[dev] 试异步 %@（等待回调后重读同步 getter）", sel);
                gSkipAsync = YES;
                ((void (*)(id, SEL, id))objc_msgSend)(gDeviceMgr, s2, ^{
                    LOGS(@"[dev] 异步完成: %@", sel);
                    dispatch_async(dispatch_get_main_queue(), ^{ reloadDevices(done); });
                });
                return;
            }
        }
        LOGS(@"[dev] 没能拿到设备列表（见上面的方法清单）");
        if (done) done();
    } @catch (NSException *e) { LOGS(@"[dev] ex %@ %@", e.name, e.reason); if (done) done(); }
}

static void removeDevice(id dev, void (^done)(BOOL ok, NSString *msg)) {
    @try {
        SEL s = tfSel(@"removeDevices:completionBlock:");
        if (!gDeviceMgr || ![gDeviceMgr respondsToSelector:s]) {
            LOGS(@"[rm] 没有 removeDevices:completionBlock:");
            if (done) done(NO, @"接口不可用");
            return;
        }
        LOGS(@"[rm] 移除 %@ (%@)", strSafe(dev, @"name") ?: strSafe(dev, @"deviceName"), NSStringFromClass([dev class]));
        ((void (*)(id, SEL, id, id))objc_msgSend)(gDeviceMgr, s, @[dev], ^{
            LOGS(@"[rm] 完成回调");
            if (done) done(YES, nil);
        });
    } @catch (NSException *e) { LOGS(@"[rm] ex %@ %@", e.name, e.reason); if (done) done(NO, e.reason); }
}

#pragma mark - UI

static NSString *deviceTitle(id d) {
    NSString *s = strSafe(d, @"name");
    if (!s.length) s = strSafe(d, @"deviceName");
    if (!s.length) s = strSafe(d, @"model");
    if (!s.length) s = strSafe(d, @"deviceModel");
    return s.length ? s : NSStringFromClass([d class]);
}
static NSString *deviceSubtitle(id d) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *model = strSafe(d, @"model");
    if (!model.length) model = strSafe(d, @"deviceModel");
    if (model.length) [parts addObject:model];
    NSString *plat = strSafe(d, @"platform");
    if (plat.length) [parts addObject:plat];
    NSString *os = strSafe(d, @"osVersion");
    if (os.length) [parts addObject:os];
    NSString *udid = strSafe(d, @"udid");
    if (!udid.length) udid = strSafe(d, @"identifier");
    if (udid.length) [parts addObject:[udid substringToIndex:MIN((NSUInteger)12, udid.length)]];
    NSInteger p = intSafe(d, @"platform");
    if (p >= 0) [parts addObject:[NSString stringWithFormat:@"platform=%ld", (long)p]];
    return [parts componentsJoinedByString:@" · "];
}

@interface TFDevCell : UITableViewCell
@property (nonatomic, strong) UILabel *mainLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIButton *removeButton;
@end
@implementation TFDevCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (!self) return nil;
    _mainLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 240, 20)];
    _mainLabel.font = [UIFont systemFontOfSize:16];
    _subLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, 260, 16)];
    _subLabel.font = [UIFont systemFontOfSize:12];
    _subLabel.textColor = UIColor.secondaryLabelColor;
    _subLabel.numberOfLines = 2;
    _removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _removeButton.frame = CGRectMake(0, 0, 64, 32);
    [_removeButton setTitle:@"移除" forState:UIControlStateNormal];
    [_removeButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.contentView addSubview:_mainLabel];
    [self.contentView addSubview:_subLabel];
    self.accessoryView = _removeButton;
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    self.mainLabel.frame = CGRectMake(16, 10, w - 100, 20);
    self.subLabel.frame = CGRectMake(16, 32, w - 100, 32);
}
@end

@interface TFDevVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation TFDevVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(refresh)];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 68;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];
    [self refresh];
}

- (void)refresh {
    gDevices = nil;
    self.items = @[];
    [self.table reloadData];
    __weak TFDevVC *ws = self;
    reloadDevices(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            TFDevVC *me = ws;
            if (!me) return;
            me.items = gDevices ?: @[];
            me.title = me.items.count ? [NSString stringWithFormat:@"设备 (%lu)", (unsigned long)me.items.count] : @"设备";
            [me.table reloadData];
            if (!me.items.count) {
                me.title = @"设备（未取到）";
            }
        });
    });
}

- (void)close { if (self.onClose) self.onClose(); [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TFDevCell *c = [tv dequeueReusableCellWithIdentifier:@"d"];
    if (!c) c = [[TFDevCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
    id d = self.items[ip.row];
    c.mainLabel.text = deviceTitle(d);
    c.subLabel.text = deviceSubtitle(d);
    c.removeButton.tag = ip.row;
    [c.removeButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [c.removeButton addTarget:self action:@selector(removeTapped:) forControlEvents:UIControlEventTouchUpInside];
    return c;
}

- (void)removeTapped:(UIButton *)b {
    NSInteger row = b.tag;
    if (row < 0 || row >= (NSInteger)self.items.count) return;
    id d = self.items[row];
    NSString *title = deviceTitle(d);
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"移除设备"
                         message:[NSString stringWithFormat:@"把「%@」从你的 TestFlight 测试设备里移除？\n%@",
                                                            title, deviceSubtitle(d)]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TFDevVC *ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        removeDevice(d, ^(BOOL ok, NSString *msg) {
            dispatch_async(dispatch_get_main_queue(), ^{
                TFDevVC *me = ws;
                UIAlertController *r = [UIAlertController
                    alertControllerWithTitle:(ok ? @"已移除" : @"移除失败")
                                     message:(ok ? @"已从设备列表移除，服务器稍后会同步。" : (msg ?: @""))
                              preferredStyle:UIAlertControllerStyleAlert];
                [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [me presentViewController:r animated:YES completion:nil];
                [me refresh];
            });
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

#pragma mark - 入口按钮

static UIButton *gButton;
static __weak UIWindow *gHostWindow;

static UIWindow *keyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (!w.hidden) return w;
    }
    return nil;
}

static UIView *findLabel(UIView *root, NSString *text, int depth) {
    if (!root || depth > 14) return nil;
    if ([root isKindOfClass:[UILabel class]] && [((UILabel *)root).text containsString:text]) return root;
    NSString *al = root.accessibilityLabel;
    if (al.length && [al containsString:text]) return root;
    for (UIView *sub in root.subviews) { UIView *r = findLabel(sub, text, depth + 1); if (r) return r; }
    return nil;
}

static void presentDevices(void) {
    @try {
        UIWindow *w = gHostWindow ?: keyWindow();
        UIViewController *host = w.rootViewController;
        if (!host) return;
        TFDevVC *vc = [[TFDevVC alloc] init];
        vc.onClose = ^{ if (gButton) gButton.hidden = NO; };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        if (gButton) gButton.hidden = YES;
        [host presentViewController:nav animated:YES completion:nil];
        LOGS(@"[ui] 已弹出设备页");
    } @catch (NSException *e) { LOGS(@"[ui] ex %@", e.name); }
}

static void placeButton(UIWindow *w) {
    if (!gButton.superview) [w addSubview:gButton];
    [w bringSubviewToFront:gButton];
    CGRect bb = gButton.bounds;
    UIView *anchor = findLabel(w, @"兑换", 0);
    if (anchor && anchor.window == w) {
        CGRect rf = [anchor convertRect:anchor.bounds toView:w];
        // 放在「批量」左边：兑换左边 - 批量宽 - 间距 - 本按钮宽
        CGFloat x = rf.origin.x - 10 - 64 - 8 - bb.size.width;
        gButton.frame = CGRectMake(MAX(8, x), rf.origin.y + (rf.size.height - bb.size.height) / 2.0 + 6,
                                   bb.size.width, bb.size.height);
    } else {
        CGFloat top = w.safeAreaInsets.top;
        gButton.frame = CGRectMake(w.bounds.size.width - 70 - 64 - 16, top + 6, bb.size.width, bb.size.height);
    }
}

static void attachButton(void) {
    @try {
        UIWindow *w = keyWindow();
        if (!w) return;
        if (!gButton) {
            gButton = [UIButton buttonWithType:UIButtonTypeSystem];
            gButton.frame = CGRectMake(0, 0, 64, 34);
            [gButton setTitle:@"设备" forState:UIControlStateNormal];
            gButton.titleLabel.font = [UIFont systemFontOfSize:17];
            [gButton setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
            [gButton addAction:[UIAction actionWithHandler:^(UIAction *a) { presentDevices(); }]
                    forControlEvents:UIControlEventTouchUpInside];
        }
        if (!w.rootViewController.presentedViewController) gButton.hidden = NO;
        gHostWindow = w;
        placeButton(w);
    } @catch (NSException *e) { LOGS(@"[ui] ex %@", e.name); }
}

__attribute__((constructor)) static void tfdevices_init(void) {
    @try {
        LOGS(@"=== TFDevices loaded in %@ ===", [NSBundle mainBundle].bundleIdentifier);
        Class c = objc_getClass("OASAppList");
        if (c) {
            Method m;
            if ((m = class_getInstanceMethod(c, sel_registerName("initWithSessionContext:")))) {
                gOrigInitCtx = method_getImplementation(m);
                method_setImplementation(m, (IMP)tf_initCtx);
            }
            if ((m = class_getInstanceMethod(c, sel_registerName("initWithAppCatalogManager:")))) {
                gOrigInitMgr = method_getImplementation(m);
                method_setImplementation(m, (IMP)tf_initMgr);
            }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            attachButton();
        });
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                  (uint64_t)(3 * NSEC_PER_SEC), (uint64_t)(NSEC_PER_SEC / 2));
        dispatch_source_set_event_handler(t, ^{ attachButton(); });
        dispatch_resume(t);
    } @catch (NSException *e) { LOGS(@"[init] ex %@", e.name); }
}
