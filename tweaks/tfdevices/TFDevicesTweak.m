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
static BOOL gSpoof;                  // 是否启用伪装
static NSString *gSpoofModel, *gSpoofProductType, *gSpoofSystemVersion, *gSpoofBuildVersion;
static NSString *spoofPath(void) { return docPath(@"tfspoof.plist"); }
static void loadSpoofConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:spoofPath()];
    gSpoof = [d[@"Enabled"] boolValue];
    gSpoofModel = d[@"Model"] ?: @"iPad Pro (11-inch) (4th generation)";
    gSpoofProductType = d[@"ProductType"] ?: @"iPad13,4";
    gSpoofSystemVersion = d[@"SystemVersion"] ?: @"18.5";
    gSpoofBuildVersion = d[@"BuildVersion"] ?: @"22F76";
    LOGS(@"[spoof] 配置: enabled=%d model=%@ productType=%@ os=%@ build=%@",
         gSpoof, gSpoofModel, gSpoofProductType, gSpoofSystemVersion, gSpoofBuildVersion);
}
static void saveSpoofConfig(void) {
    NSDictionary *d = @{@"Enabled": @(gSpoof), @"Model": gSpoofModel ?: @"",
                        @"ProductType": gSpoofProductType ?: @"",
                        @"SystemVersion": gSpoofSystemVersion ?: @"",
                        @"BuildVersion": gSpoofBuildVersion ?: @""};
    [d writeToFile:spoofPath() atomically:YES];
    LOGS(@"[spoof] 已保存 enabled=%d", gSpoof);
}
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

// TFCurrentDevice 全是类方法：先记录原值，再按开关返回伪装值
static Class tfCurrentDeviceClass(void) { return objc_getClass("TFCurrentDevice"); }

static id cdStrValue(NSString *selName) {
    Class c = tfCurrentDeviceClass();
    if (!c) return nil;
    SEL s = tfSel(selName);
    if (![c respondsToSelector:s]) return nil;
    Method m = class_getClassMethod(c, s);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || enc[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(c, s); } @catch (NSException *e) { return nil; }
}
static long cdIntValue(NSString *selName) {
    Class c = tfCurrentDeviceClass();
    if (!c) return -999;
    SEL s = tfSel(selName);
    if (![c respondsToSelector:s]) return -999;
    @try { return ((long (*)(id, SEL))objc_msgSend)(c, s); } @catch (NSException *e) { return -999; }
}
static void logCurrentDevice(void) {
    LOGS(@"[self] productType=%@ model=%@ systemVersion=%@ build=%@ UDID=%@ GUID=%@",
         cdStrValue(@"productType"), cdStrValue(@"model"), cdStrValue(@"systemVersion"),
         cdStrValue(@"buildVersion"), cdStrValue(@"UDID"), cdStrValue(@"GUID"));
    LOGS(@"[self] compatibleProductType=%@ variants=%@ thinned=%@ arch=%@ platform(long)=%ld iosCompat=%ld",
         cdStrValue(@"compatibleProductType"), cdStrValue(@"compatibleAppVariants"),
         cdStrValue(@"thinnedAppVariantId"), cdStrValue(@"deviceArchitecture"),
         cdIntValue(@"platform"), cdIntValue(@"supportsIOSAppCompatibility"));
}

// 类方法 hook：返回对象
static IMP oSoftwareVersion, oModel, oProductType, oCompatibleProductType, oBuildVersion;
static IMP oPlatform, oIOSCompat;

static id hSystemVersion(id self, SEL _cmd) {
    if (gSpoof && gSpoofSystemVersion.length) return gSpoofSystemVersion;
    return ((id (*)(id, SEL))oSoftwareVersion)(self, _cmd);
}
static id hModel(id self, SEL _cmd) {
    if (gSpoof && gSpoofModel.length) return gSpoofModel;
    return ((id (*)(id, SEL))oModel)(self, _cmd);
}
static id hProductType(id self, SEL _cmd) {
    if (gSpoof && gSpoofProductType.length) return gSpoofProductType;
    return ((id (*)(id, SEL))oProductType)(self, _cmd);
}
static id hCompatibleProductType(id self, SEL _cmd) {
    if (gSpoof && gSpoofProductType.length) return gSpoofProductType;
    return ((id (*)(id, SEL))oCompatibleProductType)(self, _cmd);
}
static id hBuildVersion(id self, SEL _cmd) {
    if (gSpoof && gSpoofBuildVersion.length) return gSpoofBuildVersion;
    return ((id (*)(id, SEL))oBuildVersion)(self, _cmd);
}
static long hPlatform(id self, SEL _cmd) {
    return ((long (*)(id, SEL))oPlatform)(self, _cmd);   // 平台枚举先不动，避免把 iOS 报成 tvOS
}
static BOOL hIOSCompat(id self, SEL _cmd) {
    if (gSpoof) return YES;
    return ((BOOL (*)(id, SEL))oIOSCompat)(self, _cmd);
}

static void installSpoofHooks(void) {
    Class c = tfCurrentDeviceClass();
    if (!c) { LOGS(@"[spoof] 没有 TFCurrentDevice"); return; }
    Method m;
    if ((m = class_getClassMethod(c, sel_registerName("systemVersion")))) { oSoftwareVersion = method_getImplementation(m); method_setImplementation(m, (IMP)hSystemVersion); }
    if ((m = class_getClassMethod(c, sel_registerName("model")))) { oModel = method_getImplementation(m); method_setImplementation(m, (IMP)hModel); }
    if ((m = class_getClassMethod(c, sel_registerName("productType")))) { oProductType = method_getImplementation(m); method_setImplementation(m, (IMP)hProductType); }
    if ((m = class_getClassMethod(c, sel_registerName("compatibleProductType")))) { oCompatibleProductType = method_getImplementation(m); method_setImplementation(m, (IMP)hCompatibleProductType); }
    if ((m = class_getClassMethod(c, sel_registerName("buildVersion")))) { oBuildVersion = method_getImplementation(m); method_setImplementation(m, (IMP)hBuildVersion); }
    if ((m = class_getClassMethod(c, sel_registerName("platform")))) { oPlatform = method_getImplementation(m); method_setImplementation(m, (IMP)hPlatform); }
    if ((m = class_getClassMethod(c, sel_registerName("supportsIOSAppCompatibility")))) { oIOSCompat = method_getImplementation(m); method_setImplementation(m, (IMP)hIOSCompat); }
    LOGS(@"[spoof] hook 完成");
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

        // 唯一的同步入口没有，只能走 loadDevicesWithCompletionBlock:
        SEL ls = tfSel(@"loadDevicesWithCompletionBlock:");
        if ([gDeviceMgr respondsToSelector:ls]) {
            LOGS(@"[dev] 调 loadDevicesWithCompletionBlock:");
            ((void (*)(id, SEL, id))objc_msgSend)(gDeviceMgr, ls, ^(id a, id b) {
                uintptr_t pa = (uintptr_t)a;
                BOOL looksObject = (pa > 0x100000000ULL && (pa & 0x7) == 0);
                LOGS(@"[dev] 回调 a=%p(%@) b=%p", a, looksObject ? NSStringFromClass([a class]) : @"非对象", b);
                if (looksObject) {
                    @try {
                        NSArray *arr = nil;
                        if ([a isKindOfClass:[NSArray class]]) arr = a;
                        else if ([a respondsToSelector:tfSel(@"devices")]) arr = idSafe(a, @"devices");
                        if (arr.count) { gDevices = arr; logDevices(arr, @"loadDevices"); }
                    } @catch (NSException *e) { LOGS(@"[dev] 解析 ex %@", e.name); }
                }
                dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(); });
            });
            return;
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
@property (nonatomic, strong) UIBarButtonItem *spoofItem;
@end

@implementation TFDevVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    self.spoofItem = [[UIBarButtonItem alloc] initWithTitle:(gSpoof ? @"伪装中" : @"伪装")
                                                     style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(toggleSpoof)];
    self.navigationItem.rightBarButtonItems = @[self.spoofItem, refreshItem];
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

- (void)toggleSpoof {
    gSpoof = !gSpoof;
    saveSpoofConfig();
    self.spoofItem.title = gSpoof ? @"伪装中" : @"伪装";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(gSpoof ? @"已开启伪装" : @"已关闭伪装")
                         message:(gSpoof
                                  ? [NSString stringWithFormat:@"现在向服务器上报：\n型号 %@\n机型 %@\n系统 %@ (%@)\n\n需要重启 TestFlight 才会重新拉取列表。",
                                     gSpoofModel, gSpoofProductType, gSpoofSystemVersion, gSpoofBuildVersion]
                                  : @"已恢复真实设备信息，重启 TestFlight 生效。")
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
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
        loadSpoofConfig();
        logCurrentDevice();
        installSpoofHooks();
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
