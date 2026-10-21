// TFTool —— TestFlight 批量“停止测试”
// 设计：不改 App 的窗口层级，只在 App 现有窗口上挂一个小按钮；
//       点开以 modal 方式呈现自建的多选列表；执行时调用 TestFlight 内部退订接口。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 日志

static NSMutableString *gLog;
static NSString *docPath(NSString *name) {
    return [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]];
}
static void LOG(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!gLog) gLog = [NSMutableString string];
        [gLog appendFormat:@"%@\n", s];
        [gLog writeToFile:docPath(@"tftool.log") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

#pragma mark - 动态调用

static id call0(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [obj performSelector:s];
#pragma clang diagnostic pop
}
static BOOL boolOf(id obj, NSString *selName) {
    if (!obj) return NO;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
}
static NSUInteger uintOf(id obj, NSString *selName) {
    if (!obj) return 0;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(obj, s);
}

static NSString *strOf(id obj, NSString *selName) {
    @try { id v = call0(obj, selName); return v ? [v description] : @""; } @catch (NSException *e) { return @""; }
}

#pragma mark - 目标类声明

@interface OASAppContext : NSObject
- (instancetype)initWithAppStub:(id)stub andSessionContext:(id)ctx;
- (void)unsubscribe;
- (void)unsubscribeWithCompletion:(void (^)(void))completion;
- (NSString *)name;
- (NSString *)bundleID;
@end

@interface OASInviteManager : NSObject
- (instancetype)initWithAppCatalogManager:(id)cm networkManager:(id)nm;
- (void)unsubscribeFromApp:(id)app;
- (void)unsubscribeFromApp:(id)app withCompletion:(void (^)(void))completion;
@end

@interface OASIconURLImageView : UIView
- (instancetype)initWithFrame:(CGRect)frame;
- (void)setBuild:(id)build variant:(id)variant;
- (void)setURL:(NSURL *)url;
- (void)setIconType:(NSUInteger)type;
- (void)setIconFrameType:(NSUInteger)type;
- (void)refresh;
@end

@interface OASAppList : NSObject
- (instancetype)initWithSessionContext:(id)ctx;
- (instancetype)initWithAppCatalogManager:(id)mgr;
- (NSArray *)sections;
- (NSArray *)_getFullSections;
- (NSArray *)appsInSection:(NSUInteger)section;
- (id)sessionContext;
- (id)catalogManager;
- (void)refresh;
@end

#pragma mark - 运行时捕获与 hook

static NSMutableArray *gLists;
static OASInviteManager *gInviteMgr;
static NSMutableString *gDumped;

static IMP gOrigInitWithSessionContext, gOrigInitWithAppCatalogManager, gOrigSections, gOrigAppsInSection;
static IMP gOrigInviteInit;
static IMP gOrigUnsubWC, gOrigUnsubPlain, gOrigMgrUnsubWC, gOrigMgrUnsubPlain, gOrigCtxInitStub;

static void tftoolRememberList(id list) {
    @try {
        if (!list) return;
        if (!gLists) gLists = [NSMutableArray array];
        if (![gLists containsObject:list]) {
            [gLists addObject:list];
            LOG(@"[capture] OASAppList %@ %p", NSStringFromClass([list class]), list);
        }
    } @catch (NSException *e) {}
}
static id tftoolNewestList(void) { return [gLists lastObject]; }

static id tftool_initWithSessionContext(id self, SEL _cmd, id ctx) {
    id r = ((id (*)(id, SEL, id))gOrigInitWithSessionContext)(self, _cmd, ctx);
    tftoolRememberList(r);
    return r;
}
static id tftool_initWithAppCatalogManager(id self, SEL _cmd, id mgr) {
    id r = ((id (*)(id, SEL, id))gOrigInitWithAppCatalogManager)(self, _cmd, mgr);
    tftoolRememberList(r);
    return r;
}
static NSArray *tftool_sections(id self, SEL _cmd) {
    NSArray *r = ((NSArray *(*)(id, SEL))gOrigSections)(self, _cmd);
    tftoolRememberList(self);
    return r;
}
static NSArray *tftool_appsInSection(id self, SEL _cmd, NSUInteger section) {
    NSArray *r = ((NSArray *(*)(id, SEL, NSUInteger))gOrigAppsInSection)(self, _cmd, section);
    tftoolRememberList(self);
    return r;
}
static id tftool_initInviteManager(id self, SEL _cmd, id a1, id a2) {
    id r = ((id (*)(id, SEL, id, id))gOrigInviteInit)(self, _cmd, a1, a2);
    if (r) { gInviteMgr = (OASInviteManager *)r; LOG(@"[capture] OASInviteManager %p", r); }
    return r;
}
// 诊断：记录 App 自身“停止测试”走的路径（原样放行）
static void tftool_unsubWC(id self, SEL _cmd, void (^c)(void)) {
    LOG(@"[manual] OASAppContext %p unsubscribeWithCompletion: name=%@ bundle=%@", self, strOf(self, @"name"), strOf(self, @"bundleID"));
    ((void (*)(id, SEL, id))gOrigUnsubWC)(self, _cmd, c);
}
static void tftool_unsubPlain(id self, SEL _cmd) {
    LOG(@"[manual] OASAppContext %p unsubscribe name=%@ bundle=%@", self, strOf(self, @"name"), strOf(self, @"bundleID"));
    ((void (*)(id, SEL))gOrigUnsubPlain)(self, _cmd);
}
static void tftool_mgrUnsubWC(id self, SEL _cmd, id app, void (^c)(void)) {
    LOG(@"[manual] OASInviteManager %p unsubscribeFromApp:%@ bundle=%@ withCompletion:", self, strOf(app, @"name"), strOf(app, @"bundleID"));
    ((void (*)(id, SEL, id, id))gOrigMgrUnsubWC)(self, _cmd, app, c);
}
static void tftool_mgrUnsubPlain(id self, SEL _cmd, id app) {
    LOG(@"[manual] OASInviteManager %p unsubscribeFromApp:%@ bundle=%@", self, strOf(app, @"name"), strOf(app, @"bundleID"));
    ((void (*)(id, SEL, id))gOrigMgrUnsubPlain)(self, _cmd, app);
}
// 注：不再 hook OASAppContext 的初始化（列表每行都会创建，写日志太重）

static NSSet *gInstalledBundleIDs;                 // 设备上已安装（任意版本）
static NSMutableSet *gBetaInstalledBundleIDs;      // TestFlight 测试版已安装
static NSMutableDictionary<NSString *, UIImage *> *gNativeIcons;   // 原生图标服务交回的图（URL -> image）
static IMP gOrigIconDone;
static void tftool_iconDone(id self, SEL _cmd, id url, NSUInteger type, id img, id err) {
    @try {
        if (img && [img isKindOfClass:[UIImage class]]) {
            if (!gNativeIcons) gNativeIcons = [NSMutableDictionary dictionary];
            NSString *key = [url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : [url description];
            if (key.length && !gNativeIcons[key]) {   // 回调的图最优先，先到先得
                gNativeIcons[key] = img;
                static NSInteger n = 0;
                if (n++ < 4) {
                    CGSize sz = ((UIImage *)img).size;
                    LOG(@"[icon] 服务返回 %@ 尺寸=%.0fx%.0f (缩放%.1f) type=%lu", key, sz.width, sz.height,
                        ((UIImage *)img).scale, (unsigned long)type);
                }
            }
        }
    } @catch (NSException *e) {}
    ((void (*)(id, SEL, id, NSUInteger, id, id))gOrigIconDone)(self, _cmd, url, type, img, err);
}

static void tftoolInstallHooks(void) {
    Class c = objc_getClass("OASAppList"), ic = objc_getClass("OASInviteManager"), ac = objc_getClass("OASAppContext");
    Method m;
    if (c && (m = class_getInstanceMethod(c, sel_registerName("initWithSessionContext:")))) {
        gOrigInitWithSessionContext = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_initWithSessionContext); }
    if (c && (m = class_getInstanceMethod(c, sel_registerName("initWithAppCatalogManager:")))) {
        gOrigInitWithAppCatalogManager = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_initWithAppCatalogManager); }
    if (c && (m = class_getInstanceMethod(c, sel_registerName("sections")))) {
        gOrigSections = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_sections); }
    if (c && (m = class_getInstanceMethod(c, sel_registerName("appsInSection:")))) {
        gOrigAppsInSection = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_appsInSection); }
    if (ic && (m = class_getInstanceMethod(ic, sel_registerName("initWithAppCatalogManager:networkManager:")))) {
        gOrigInviteInit = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_initInviteManager); }
    if (ac && (m = class_getInstanceMethod(ac, sel_registerName("unsubscribeWithCompletion:")))) {
        gOrigUnsubWC = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_unsubWC); }
    if (ac && (m = class_getInstanceMethod(ac, sel_registerName("unsubscribe")))) {
        gOrigUnsubPlain = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_unsubPlain); }
    if (ic && (m = class_getInstanceMethod(ic, sel_registerName("unsubscribeFromApp:withCompletion:")))) {
        gOrigMgrUnsubWC = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_mgrUnsubWC); }
    if (ic && (m = class_getInstanceMethod(ic, sel_registerName("unsubscribeFromApp:")))) {
        gOrigMgrUnsubPlain = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_mgrUnsubPlain); }
    Class iv = objc_getClass("OASIconURLImageView");
    if (iv && (m = class_getInstanceMethod(iv, sel_registerName("taskCompletedForURL:iconType:withImage:error:")))) {
        gOrigIconDone = method_getImplementation(m); method_setImplementation(m, (IMP)tftool_iconDone); }
    LOG(@"[init] hook 完成: list=%d/%d ctx=%d mgr=%d",
        gOrigInitWithSessionContext != NULL, gOrigSections != NULL, gOrigUnsubWC != NULL, gOrigInviteInit != NULL);
}

#pragma mark - 数据

static NSArray *tftoolSnapshotItems(id list) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSArray *secs = nil;
        @try { secs = [list sections]; } @catch (NSException *e) {}
        if (![secs isKindOfClass:[NSArray class]]) { @try { secs = [list _getFullSections]; } @catch (NSException *e) {} }
        for (NSUInteger i = 0; i < [secs count]; i++) {
            NSArray *items = nil;
            @try { items = [list appsInSection:i]; } @catch (NSException *e) {}
            for (id it in items) if (it) [out addObject:it];
        }
    } @catch (NSException *e) { LOG(@"[snapshot] ex %@", e.name); }
    return out;
}
static id tftoolSessionContext(void);   // 前置声明

// 用 App 自己的本地化表取标题（跟随系统语言）
static NSString *tftoolLocalized(NSString *key) {
    if (!key.length) return nil;
    @try {
        Class c = objc_getClass("OASAppList");
        NSBundle *b = c ? [NSBundle bundleForClass:c] : [NSBundle mainBundle];
        NSString *v = [b localizedStringForKey:key value:@"" table:@"OASLocalizable"];
        if (v.length && ![v isEqualToString:key]) return v;
        // 兜底：直接在 bundle 里找 OASLocalizable.strings
        NSString *path = [b pathForResource:@"OASLocalizable" ofType:@"strings"];
        if (path) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (d[key]) return d[key];
        }
    } @catch (NSException *e) {}
    return nil;
}

// 不兼容分组到底是“哪个平台专属”：拿 App 自己的说明文案去比对自己的本地化模板
static NSString *tftoolIncompatibleGroupKey(id app) {
    @try {
        Class ctxCls = objc_getClass("OASAppContext");
        id sc = tftoolSessionContext();
        if (!ctxCls || !sc) return nil;
        id ctx = [[ctxCls alloc] initWithAppStub:app andSessionContext:sc];
        NSString *msg = strOf(ctx, @"incompatibleFullMessage");
        NSString *name = strOf(app, @"name");
        if (!msg.length || !name.length) return nil;
        NSArray *pairs = @[
            @[@"APP_LIST_GROUP_NAME_NEEDS_ATV",             @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_ATV_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_IOS",             @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_IOS_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_IPAD",            @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_IPAD_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_MAC",             @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_MACOS_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_VISIONOS",        @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_VISIONOS_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_WATCH",           @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_WATCHOS_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_WATCH_OS_UPDATE", @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_WATCHOS_UPDATE_FORMAT"],
            @[@"APP_LIST_GROUP_NAME_NEEDS_OS_UPDATE",       @"AC_INCOMPAT_FULL_MESSAGE_NEEDS_OS_UPDATE"],
        ];
        NSRange nl = [msg rangeOfString:@"\n"];
        NSString *msgLine = (nl.location == NSNotFound) ? msg : [msg substringToIndex:nl.location];
        for (NSArray *pr in pairs) {
            NSString *tmpl = tftoolLocalized(pr[1]);
            if (!tmpl.length) continue;
            NSRange tnl = [tmpl rangeOfString:@"\n"];
            NSString *tmplLine = (tnl.location == NSNotFound) ? tmpl : [tmpl substringToIndex:tnl.location];
            NSRange ph = [tmplLine rangeOfString:@"%@"];
            NSString *expect = tmplLine;
            if (ph.location != NSNotFound)
                expect = [tmplLine stringByReplacingCharactersInRange:ph withString:name];
            if ([expect isEqualToString:msgLine]) {
                LOG(@"[section] 平台判定 → %@", pr[0]);
                return pr[0];
            }
        }
        LOG(@"[section] 平台判定未命中，文案=%@", msg);
    } @catch (NSException *e) { LOG(@"[section] 判定 ex %@", e.name); }
    return nil;
}

// 分组标题：优先按组内 App 的数据判定，其次按 sectionType
static NSString *tftoolSectionTitle(id sec, NSArray *apps, NSUInteger idx) {
    NSUInteger type = uintOf(sec, @"sectionType");
    BOOL allPrev = apps.count > 0;
    BOOL anyEligible = NO;
    for (id a in apps) {
        if (!boolOf(a, @"previouslyTested")) allPrev = NO;
        if (boolOf(a, @"isEligibleForInstallOrUpdate")) anyEligible = YES;
    }
    NSString *key = nil;
    if (allPrev && apps.count) {
        key = apps.count > 1 ? @"APP_LIST_GROUP_NAME_PREVIOUSLY_TESTED_MANY" : @"APP_LIST_GROUP_NAME_PREVIOUSLY_TESTED_ONE";
    } else if (apps.count && (type & 8)) {
        key = @"APP_LIST_GROUP_NAME_NEEDS_OS_UPDATE";          // type 含 8：要求 OS 更新
    } else if (apps.count && (type & 4)) {
        key = tftoolIncompatibleGroupKey(apps.firstObject);   // 优先精确到平台（Apple TV 专属 App 等）
        if (!key) key = apps.count > 1 ? @"APP_LIST_GROUP_NAME_INCOMPATIBLE_MANY"
                                       : @"APP_LIST_GROUP_NAME_INCOMPATIBLE_ONE";
    }
    LOG(@"[section] idx=%lu type=%lu count=%lu prev=%d eligible=%d key=%@",
        (unsigned long)idx, (unsigned long)type, (unsigned long)apps.count, allPrev, anyEligible, key ?: @"(主分组)");
    return key ? tftoolLocalized(key) : nil;
}

// 返回 @[ @{@"title":NSString, @"apps":NSArray} ]
static NSArray *tftoolCollectSections(void) {
    id list = tftoolNewestList();
    if (!list) { LOG(@"[collect] 尚未捕获到 OASAppList"); return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSArray *secs = nil;
        @try { secs = [list sections]; } @catch (NSException *e) {}
        if (![secs isKindOfClass:[NSArray class]]) { @try { secs = [list _getFullSections]; } @catch (NSException *e) {} }
        for (NSUInteger i = 0; i < [secs count]; i++) {
            id sec = secs[i];
            NSArray *items = nil;
            @try { items = [list appsInSection:i]; } @catch (NSException *e) {}
            if (![items isKindOfClass:[NSArray class]]) items = @[];
            NSString *title = tftoolSectionTitle(sec, items, i);
            [out addObject:@{@"title": title ?: @"", @"apps": items}];
        }
        NSUInteger total = 0;
        for (NSDictionary *sec in out) total += [sec[@"apps"] count];
        LOG(@"[collect] 分组=%lu 条目=%lu 组标题=%@", (unsigned long)[out count], (unsigned long)total,
            [[out valueForKey:@"title"] componentsJoinedByString:@" | "]);
    } @catch (NSException *e) { LOG(@"[collect] ex %@", e.name); }
    return out;
}

static NSArray *tftoolFlatten(NSArray *sections) {
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *sec in sections) [all addObjectsFromArray:sec[@"apps"]];
    return all;
}

static NSArray *tftoolCollectApps(void) {
    id list = tftoolNewestList();
    if (!list) { LOG(@"[collect] 尚未捕获到 OASAppList"); return @[]; }
    NSArray *items = tftoolSnapshotItems(list);
    LOG(@"[collect] 条目数=%lu 首个类型=%@", (unsigned long)[items count],
        [items count] ? NSStringFromClass([[items firstObject] class]) : @"-");
    if (!gDumped && [items count]) {
        gDumped = [NSMutableString string];
        int n = 0;
        for (id it in items) {
            if (n++ >= 40) break;
            [gDumped appendFormat:@"[%d] %@ name=%@ bundle=%@ appID=%@ ctx=%d mgr=%d\n", n,
                NSStringFromClass([it class]), strOf(it, @"name"), strOf(it, @"bundleID"), strOf(it, @"appID"),
                [it respondsToSelector:NSSelectorFromString(@"unsubscribeWithCompletion:")],
                [it respondsToSelector:NSSelectorFromString(@"unsubscribeFromApp:withCompletion:")]];
        }
        [gDumped writeToFile:docPath(@"tftool-dump.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return items;
}

static id tftoolSessionContext(void) {
    @try { return call0(tftoolNewestList(), @"sessionContext"); } @catch (NSException *e) { return nil; }
}
static id tftoolInviteManager(void) {
    if (gInviteMgr) return gInviteMgr;
    @try {
        id m = call0(tftoolSessionContext(), @"inviteManager");
        if (m) { gInviteMgr = (OASInviteManager *)m; LOG(@"[mgr] 由 sessionContext 取得 %p", m); return m; }
        id cm = call0(tftoolNewestList(), @"catalogManager");
        if (!cm) cm = call0(tftoolSessionContext(), @"catalogManager");
        Class cls = objc_getClass("OASInviteManager");
        if (cm && cls) {
            id nm = call0(cm, @"networkManager");
            typedef id (*InitMgrFn)(id, SEL, id, id);
            m = ((InitMgrFn)objc_msgSend)([cls alloc], sel_registerName("initWithAppCatalogManager:networkManager:"), cm, nm);
            if (m) { gInviteMgr = (OASInviteManager *)m; LOG(@"[mgr] 自建 %p (cm=%p nm=%p)", m, cm, nm); return m; }
        }
        LOG(@"[mgr] 拿不到 OASInviteManager (cm=%p)", cm);
    } @catch (NSException *e) { LOG(@"[mgr] ex %@ %@", e.name, e.reason); }
    return nil;
}

static BOOL tftoolStopOne(id app, void (^done)(void), NSString **hint) {
    @try {
        Class ctxCls = objc_getClass("OASAppContext");
        id sc = tftoolSessionContext();
        if (ctxCls && sc) {
            id ctx = [[ctxCls alloc] initWithAppStub:app andSessionContext:sc];
            if (ctx && [ctx respondsToSelector:NSSelectorFromString(@"unsubscribeWithCompletion:")]) {
                LOG(@"[stop] 路径A OASAppContext %p", ctx);
                [ctx unsubscribeWithCompletion:done];
                if (hint) *hint = @"ctx-block";
                return YES;
            }
            if (ctx && [ctx respondsToSelector:NSSelectorFromString(@"unsubscribe")]) {
                LOG(@"[stop] 路径A(plain) OASAppContext %p", ctx);
                [ctx unsubscribe];
                if (hint) *hint = @"ctx-plain";
                return YES;
            }
            LOG(@"[stop] 上下文不可用 ctx=%p sc=%p", ctx, sc);
        }
        id mgr = tftoolInviteManager();
        if (mgr && [mgr respondsToSelector:NSSelectorFromString(@"unsubscribeFromApp:withCompletion:")]) {
            LOG(@"[stop] 路径B OASInviteManager %p", mgr);
            [mgr unsubscribeFromApp:app withCompletion:done];
            if (hint) *hint = @"mgr-block";
            return YES;
        }
        if (mgr && [mgr respondsToSelector:NSSelectorFromString(@"unsubscribeFromApp:")]) {
            [mgr unsubscribeFromApp:app];
            if (hint) *hint = @"mgr-plain";
            return YES;
        }
        LOG(@"[stop] 两条路都不通 ctxCls=%p sc=%p mgr=%p", ctxCls, sc, mgr);
    } @catch (NSException *e) { LOG(@"[stop] ex %@ %@", e.name, e.reason); }
    return NO;
}

#pragma mark - 图标

static NSMutableDictionary<NSString *, UIImage *> *gIcons;      // URL -> image
static NSMutableDictionary<NSString *, NSString *> *gIconURLs;   // appID -> URL string

// 备用：App 内部的图标 URL 接口（不一定可用，仅兜底）
static NSURL *tftoolIconURLPrivate(id app) {
    @try {
        Class ctxCls = objc_getClass("OASAppContext");
        id sc = tftoolSessionContext();
        if (!ctxCls || !sc) return nil;
        id ctx = [[ctxCls alloc] initWithAppStub:app andSessionContext:sc];
        SEL sel = NSSelectorFromString(@"iconURLForType:");
        if (ctx && [ctx respondsToSelector:sel]) {
            typedef id (*Fn)(id, SEL, NSUInteger);
            id u = ((Fn)objc_msgSend)(ctx, sel, (NSUInteger)0);
            if ([u isKindOfClass:[NSURL class]]) return u;
            if ([u isKindOfClass:[NSString class]]) return [NSURL URLWithString:u];
        }
    } @catch (NSException *e) {}
    return nil;
}

static UIImage *tftoolCachedIcon(id app) {
    NSString *key = strOf(app, @"appID");
    NSString *urlStr = key.length ? gIconURLs[key] : nil;
    if (urlStr) return gIcons[urlStr];
    return nil;
}

static void tftoolLoadIconForApp(id app, UITableViewCell *cell, void (^reloadRow)(void)) {
    NSString *appID = strOf(app, @"appID");
    NSString *urlStr = appID.length ? gIconURLs[appID] : nil;
    NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : tftoolIconURLPrivate(app);
    if (!url) return;
    NSString *u = url.absoluteString;
    if (!gIcons) gIcons = [NSMutableDictionary dictionary];
    if (gIcons[u]) { cell.imageView.image = gIcons[u]; return; }
    __weak UITableViewCell *weakCell = cell;
    [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *img = (d && !e) ? [UIImage imageWithData:d] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) {
                gIcons[u] = img;
                if (weakCell) weakCell.imageView.image = img;
            } else {
                static NSInteger failCount = 0;
                if (failCount++ < 3) LOG(@"[icon] 下载失败 %@ err=%@", u, e);
            }
            if (reloadRow) reloadRow();
        });
    }];
}

// 主路径：用 App Store ID 批量查官方图标（一次请求搞定所有）
static void tftoolPrefetchIcons(NSArray *apps, NSArray *appIDs, void (^done)(void)) {
    if (!appIDs.count) { if (done) done(); return; }
    if (!gIconURLs) gIconURLs = [NSMutableDictionary dictionary];
    NSString *urlStr = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@",
                        [appIDs componentsJoinedByString:@","]];
    LOG(@"[icon] lookup %lu 个 appID", (unsigned long)appIDs.count);
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (done) done(); return; }
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger httpCode = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : -1;
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        LOG(@"[icon] lookup http=%ld results=%lu err=%@", (long)httpCode, (unsigned long)results.count, e);
        for (NSDictionary *it in results) {
            NSString *aid = it[@"trackId"] ? [it[@"trackId"] description] : nil;
            NSString *art = it[@"artworkUrl100"] ?: it[@"artworkUrl60"];
            if (aid.length && art.length) {
                gIconURLs[aid] = [art stringByReplacingOccurrencesOfString:@"100x100bb" withString:@"200x200bb"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(); });
    }];
}

#pragma mark - 多选列表（原生观感）

@interface TFAppCell : UITableViewCell
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconOverlay;
@property (nonatomic, copy) NSString *iconAppID;
@property (nonatomic, assign) BOOL iconFetching;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@end

@implementation TFAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    if (!self) return nil;
    CGFloat h = 76;
    _iconBox = [[UIView alloc] initWithFrame:CGRectMake(16, (h - 60) / 2, 60, 60)];
    _iconBox.layer.cornerRadius = 11;
    _iconBox.layer.borderWidth = 0.5;
    _iconBox.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.10].CGColor;
    _iconBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    _iconBox.clipsToBounds = YES;
    [self.contentView addSubview:_iconBox];

    Class ivCls = objc_getClass("OASIconURLImageView");
    if (ivCls) {
        id v = [[ivCls alloc] initWithFrame:_iconBox.bounds];   // 用 TestFlight 自己的图标视图（带它自己的缓存）
        _iconView = (UIView *)v;
    } else {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:_iconBox.bounds];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = iv;
    }
    _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_iconBox addSubview:_iconView];

    // 我们用同一张图自己渲染（正方形、居中、不留白边），避免原生视图在某些 App 上拉伸出怪形状
    _iconOverlay = [[UIImageView alloc] initWithFrame:_iconBox.bounds];
    _iconOverlay.contentMode = UIViewContentModeScaleAspectFit;
    _iconOverlay.clipsToBounds = YES;
    _iconOverlay.hidden = YES;
    _iconOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_iconBox addSubview:_iconOverlay];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(88, 17, self.contentView.bounds.size.width - 152, 21)];
    _nameLabel.font = [UIFont systemFontOfSize:17];
    _nameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.contentView addSubview:_nameLabel];

    _subLabel = [[UILabel alloc] initWithFrame:CGRectMake(88, 38, self.contentView.bounds.size.width - 152, 17)];
    _subLabel.font = [UIFont systemFontOfSize:13];
    _subLabel.textColor = UIColor.secondaryLabelColor;
    _subLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.contentView addSubview:_subLabel];

    _badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.contentView.bounds.size.width - 116, 25, 56, 20)];
    _badgeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _badgeLabel.textColor = [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:1.0];
    _badgeLabel.backgroundColor = [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:0.12];
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.layer.cornerRadius = 10;
    _badgeLabel.clipsToBounds = YES;
    _badgeLabel.text = @"已安装";
    _badgeLabel.hidden = YES;
    _badgeLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.contentView addSubview:_badgeLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    // 每次布局都按当前单元格高度把图标框垂直居中（否则复用时会被顶到上面去）
    CGRect box = self.iconBox.frame;
    box.origin.x = 16;
    box.origin.y = floor((h - box.size.height) / 2.0);
    self.iconBox.frame = box;
    self.iconView.frame = self.iconBox.bounds;
    self.iconOverlay.frame = self.iconBox.bounds;
    CGFloat labelX = (box.size.width > 0) ? CGRectGetMaxX(box) + 12 : 88;
    CGFloat limit = self.bounds.size.width - 116 - 8;         // 给“已安装”气泡留位
    self.nameLabel.frame = CGRectMake(labelX, 17, MAX(60, limit - labelX), 21);
    self.subLabel.frame = CGRectMake(labelX, 38, MAX(60, limit - labelX), 17);
    self.badgeLabel.frame = CGRectMake(self.bounds.size.width - 116, 25, 56, 20);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    if (!self.iconView.superview) { [self.iconBox addSubview:self.iconView]; [self.iconBox sendSubviewToBack:self.iconView]; }
    self.iconOverlay.hidden = YES;
    self.iconOverlay.image = nil;
    self.iconView.alpha = 1;
    self.iconBox.frame = CGRectMake(16, (76 - 60) / 2.0, 60, 60);
    self.iconBox.layer.cornerRadius = 11;
    self.iconBox.layer.borderWidth = 0.5;
    self.iconBox.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.10].CGColor;
    self.iconBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.iconView.frame = self.iconBox.bounds;
    self.iconOverlay.frame = self.iconBox.bounds;
    CGFloat w = self.contentView.bounds.size.width;
    self.nameLabel.frame = CGRectMake(88, 17, w - 198, 21);
    self.subLabel.frame = CGRectMake(88, 38, w - 198, 17);
    self.badgeLabel.frame = CGRectMake(self.bounds.size.width - 116, 25, 56, 20);
}

- (void)pollNativeIcon:(int)n {
    if (n > 12) return;
    @try {
        static NSInteger dbg = 0;
        if (n == 0 && dbg++ < 4) {
            SEL ds = NSSelectorFromString(@"URL");
            id du = [self.iconView respondsToSelector:ds] ? ((id (*)(id, SEL))objc_msgSend)(self.iconView, ds) : nil;
            LOG(@"[icon] 轮询开始 app=%@ 视图=%@ URL=%@ 缓存=%lu", self.nameLabel.text,
                NSStringFromClass([self.iconView class]), du ?: @"(nil)",
                (unsigned long)gNativeIcons.count);
        }
        SEL sel = NSSelectorFromString(@"URL");
        UIImage *img = nil;
        if ([self.iconView respondsToSelector:sel]) {
            id u = ((id (*)(id, SEL))objc_msgSend)(self.iconView, sel);
            NSString *key = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString] : [u description];
            if (key.length) img = gNativeIcons[key];
        }
        if (img) {
            // 统一正方形：60×60、iOS 图标圆角比例，图片填满方块居中裁切
            CGFloat side = 60.0, radius = 13.5;
            CGRect box = self.iconBox.frame;
            box.size = CGSizeMake(side, side);
            box.origin.x = 16;
            box.origin.y = floor((self.contentView.bounds.size.height - side) / 2.0);
            self.iconBox.frame = box;
            self.iconBox.layer.cornerRadius = radius;
            self.iconBox.layer.borderWidth = 0;
            self.iconBox.backgroundColor = UIColor.clearColor;
            self.iconBox.clipsToBounds = YES;
            self.iconView.frame = self.iconBox.bounds;
            self.iconOverlay.frame = self.iconBox.bounds;
            self.iconOverlay.image = img;
            self.iconOverlay.contentMode = UIViewContentModeScaleAspectFill;
            self.iconOverlay.clipsToBounds = YES;
            self.iconOverlay.hidden = NO;
            [self.iconBox bringSubviewToFront:self.iconOverlay];
            if (self.iconView.superview == self.iconBox) {
                [self.iconView removeFromSuperview];   // 只留自绘，排除原生视图观感干扰
            }
            CGFloat labelX = CGRectGetMaxX(box) + 12;
            CGRect nf = self.nameLabel.frame, sf = self.subLabel.frame;
            CGFloat limit2 = self.bounds.size.width - 116 - 8;
            nf.origin.x = labelX; nf.size.width = MAX(60, limit2 - labelX);
            sf.origin.x = labelX; sf.size.width = nf.size.width;
            self.nameLabel.frame = nf; self.subLabel.frame = sf;
            static NSInteger okCount = 0;
            if (okCount++ < 3) LOG(@"[icon] 正方形显示 %@ 图=%.0fx%.0f 框=%.0fx%.0f", self.nameLabel.text,
                                   img.size.width, img.size.height, side, side);
            return;
        }
        static NSInteger missCount = 0;
        if (n >= 12 && missCount++ < 3) {
            SEL us = NSSelectorFromString(@"URL");
            id u = [self.iconView respondsToSelector:us] ? ((id (*)(id, SEL))objc_msgSend)(self.iconView, us) : nil;
            LOG(@"[icon] 叠加层未拿到图，app=%@ 原生URL=%@", self.nameLabel.text, u ?: @"(nil)");
        }
    } @catch (NSException *e) {}
    __weak TFAppCell *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [ws pollNativeIcon:n + 1]; });
}

- (void)configureWithApp:(id)app picked:(BOOL)picked {
    NSString *name = strOf(app, @"name");
    if (!name.length) name = strOf(app, @"bundleID");
    if (!name.length) name = [NSString stringWithFormat:@"<%@>", NSStringFromClass([app class])];
    self.nameLabel.text = name;
    self.subLabel.text = strOf(app, @"bundleID");
    self.accessoryType = picked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    self.tintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    NSString *bidForBadge = strOf(app, @"bundleID");
    if (bidForBadge.length && [gBetaInstalledBundleIDs containsObject:bidForBadge]) {
        self.badgeLabel.text = @"测试版";
        self.badgeLabel.textColor = [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:1.0];
        self.badgeLabel.backgroundColor = [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:0.12];
        self.badgeLabel.hidden = NO;
    } else if (bidForBadge.length && [gInstalledBundleIDs containsObject:bidForBadge]) {
        self.badgeLabel.text = @"正式版";
        self.badgeLabel.textColor = [UIColor colorWithWhite:0.42 alpha:1.0];
        self.badgeLabel.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
        self.badgeLabel.hidden = NO;
    } else {
        self.badgeLabel.hidden = YES;
    }

    id build = call0(app, @"latestAppBuild");
    id v = self.iconView;
    self.iconOverlay.hidden = YES;
    self.iconView.alpha = 1;
    self.iconAppID = strOf(app, @"appID");
    self.iconFetching = NO;

    if (!self.iconView.superview) { [self.iconBox addSubview:self.iconView]; [self.iconBox sendSubviewToBack:self.iconView]; }
    BOOL isNative = [NSStringFromClass([v class]) rangeOfString:@"IconURLImageView"].location != NSNotFound;
    if (isNative) {
        // 让 App 自己的图标视图去取图（用它的服务和磁盘缓存）
        if (build && [v respondsToSelector:NSSelectorFromString(@"setBuild:variant:")]) {
            [(OASIconURLImageView *)v setBuild:build variant:nil];
        } else if ([v respondsToSelector:NSSelectorFromString(@"setURL:")]) {
            NSURL *u = tftoolIconURLPrivate(app);
            if (u) [(OASIconURLImageView *)v setURL:u];
        }
        [self pollNativeIcon:0];
    } else if ([v isKindOfClass:[UIImageView class]]) {
        // 没有原生图标视图时按 appID 兜底拉图
        UIImage *cached = tftoolCachedIcon(app);
        ((UIImageView *)v).image = cached;
        if (!cached) {
            NSString *aid = strOf(app, @"appID");
            NSString *us = aid.length ? gIconURLs[aid] : nil;
            NSURL *u = us.length ? [NSURL URLWithString:us] : tftoolIconURLPrivate(app);
            if (u) {
                __weak UIView *wv = v;
                [[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                    UIImage *img = (d && !e) ? [UIImage imageWithData:d] : nil;
                    if (img) dispatch_async(dispatch_get_main_queue(), ^{ ((UIImageView *)wv).image = img; });
                }];
            }
        }
    }
}

@end

@interface TFListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *sections;      // @[@{title,apps}]
@property (nonatomic, strong) NSMutableArray *picked;
@property (nonatomic, strong) UIBarButtonItem *goButton;
@property (nonatomic, strong) UIBarButtonItem *selAllItem;
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, strong) NSSet *installedBundleIDs;
@property (nonatomic, assign) BOOL dragSelecting;
@property (nonatomic, assign) BOOL dragTargetPicked;
@property (nonatomic, strong) NSTimer *dragScrollTimer;
@property (nonatomic, assign) CGFloat dragScrollDelta;
@property (nonatomic, assign) CGPoint lastDragWindowPoint;
@property (nonatomic, strong) NSIndexPath *dragAnchor;
@property (nonatomic, assign) BOOL dragAnchorWasPicked;
@property (nonatomic, strong) NSMutableArray *dragBasePicked;
@property (nonatomic, strong) UIBarButtonItem *countItem;
@end

@implementation TFListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"批量测试";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(close)];

    UIImageSymbolConfiguration *symCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    UIBarButtonItem *refreshItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise" withConfiguration:symCfg]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
    self.navigationItem.rightBarButtonItem = refreshItem;

    self.selAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                                     target:self action:@selector(toggleAll)];
    UILabel *countLabel = [[UILabel alloc] init];
    countLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    countLabel.textColor = UIColor.secondaryLabelColor;
    countLabel.text = @"已选 0 个";
    [countLabel sizeToFit];
    self.countItem = [[UIBarButtonItem alloc] initWithCustomView:countLabel];
    self.goButton = [[UIBarButtonItem alloc] initWithTitle:@"停止测试" style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(go)];
    UIBarButtonItem *f1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                        target:nil action:nil];
    UIBarButtonItem *f2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                        target:nil action:nil];
    self.toolbarItems = @[self.selAllItem, f1, self.countItem, f2, self.goButton];
    self.picked = [NSMutableArray array];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 76;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.35;
    [self.table addGestureRecognizer:lp];

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed)
        [self.navigationController setToolbarHidden:YES animated:NO];
}

#pragma mark 拖动多选

- (void)applyDragStateToRow:(NSInteger)row section:(NSInteger)section {
    if (section >= (NSInteger)self.sections.count || section < 0) return;
    NSArray *apps = self.sections[section][@"apps"];
    if (row >= (NSInteger)apps.count || row < 0) return;
    id app = apps[row];
    BOOL has = [self.picked containsObject:app];
    if (self.dragTargetPicked && !has) [self.picked addObject:app];
    else if (!self.dragTargetPicked && has) [self.picked removeObject:app];
}

// 把上一次经过的行到当前行之间的所有行都处理掉（保证连续，方向随意）
- (NSInteger)linearIndexOf:(NSIndexPath *)ip {
    NSInteger n = 0;
    for (NSInteger sec = 0; sec < ip.section && sec < (NSInteger)self.sections.count; sec++)
        n += (NSInteger)[self.sections[sec][@"apps"] count] + 1000;   // 分组间留间隙，避免跨组误判
    return n + ip.row;
}

- (NSIndexPath *)indexPathForLinear:(NSInteger)lin {
    NSInteger n = 0;
    for (NSInteger sec = 0; sec < (NSInteger)self.sections.count; sec++) {
        NSInteger cnt = (NSInteger)[self.sections[sec][@"apps"] count];
        if (lin < n + cnt) return [NSIndexPath indexPathForRow:(lin - n) inSection:sec];
        n += cnt + 1000;
    }
    return nil;
}

// 锚点区间模型：锚点那一行按下时的状态决定整段的“涂法”，
// 区间 = 锚点 ↔ 手指当前行（跨分组也连续）；区间内一律设成锚点状态，区间外保持按下前快照。
- (void)applyDragAt:(NSIndexPath *)ip {
    if (!ip || !self.dragAnchor) return;
    NSInteger a = [self linearIndexOf:self.dragAnchor];
    NSInteger b = [self linearIndexOf:ip];
    NSInteger lo = MIN(a, b), hi = MAX(a, b);
    BOOL want = self.dragAnchorWasPicked;      // 锚点原本是选中的 → 整段取消；否则整段选中

    NSMutableArray *touched = [NSMutableArray array];
    for (NSInteger lin = [self linearIndexOfWithSnapshotStart]; lin >= 0; lin = [self nextLinearFrom:lin]) {
        NSIndexPath *p = [self indexPathForLinear:lin];
        if (!p) break;
        id app = self.sections[p.section][@"apps"][p.row];
        BOOL inRange = (lin >= lo && lin <= hi);
        BOOL base = [self.dragBasePicked containsObject:app];
        BOOL desired = inRange ? want : base;
        BOOL has = [self.picked containsObject:app];
        if (desired && !has) [self.picked addObject:app];
        else if (!desired && has) [self.picked removeObject:app];
        else continue;
        [touched addObject:p];
    }
    if (touched.count) {
        [self.table reloadRowsAtIndexPaths:touched withRowAnimation:UITableViewRowAnimationNone];
        UISelectionFeedbackGenerator *fg = [[UISelectionFeedbackGenerator alloc] init];
        [fg selectionChanged];
        [self updateGo];
    }
}

// 依次遍历所有行的线性序号
- (NSInteger)linearIndexOfWithSnapshotStart { return 0; }
- (NSInteger)nextLinearFrom:(NSInteger)lin {
    NSIndexPath *p = [self indexPathForLinear:lin];
    if (!p) return -1;
    NSInteger cnt = (NSInteger)[self.sections[p.section][@"apps"] count];
    if (p.row + 1 < cnt) return lin + 1;
    NSInteger next = lin + (cnt - p.row) + 1000;      // 跳到下一组第一行
    return [self indexPathForLinear:next] ? next : -1;
}

// 拖动到列表上下边缘时自动滚动
- (void)dragScrollTick:(NSTimer *)t {
    if (!self.dragSelecting || self.dragScrollDelta == 0) return;
    CGFloat y = self.table.contentOffset.y + self.dragScrollDelta;
    CGFloat maxY = MAX(0, self.table.contentSize.height - self.table.bounds.size.height);
    y = MAX(0, MIN(maxY, y));
    self.table.contentOffset = CGPointMake(self.table.contentOffset.x, y);
    CGPoint p = [self.table convertPoint:self.lastDragWindowPoint fromView:nil];
    [self applyDragAt:[self.table indexPathForRowAtPoint:p]];
}

- (void)updateDragAutoScroll:(CGPoint)windowPoint {
    self.lastDragWindowPoint = windowPoint;
    CGPoint inTable = [self.table convertPoint:windowPoint fromView:nil];
    CGFloat h = self.table.bounds.size.height, edge = 100, step = 22;
    if (inTable.y < self.table.contentOffset.y + edge) self.dragScrollDelta = -step;
    else if (inTable.y > self.table.contentOffset.y + h - edge) self.dragScrollDelta = step;
    else self.dragScrollDelta = 0;
    if (self.dragScrollDelta != 0) {
        if (!self.dragScrollTimer) {
            self.dragScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.02 target:self
                                                                  selector:@selector(dragScrollTick:)
                                                                  userInfo:nil repeats:YES];
        }
    } else {
        [self.dragScrollTimer invalidate];
        self.dragScrollTimer = nil;
    }
}

- (void)setSheetPansEnabled:(BOOL)enabled {
    UIView *v = self.navigationController.view;
    while (v) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if ([g isKindOfClass:[UIPanGestureRecognizer class]]) g.enabled = enabled;
        }
        v = v.superview;
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        NSIndexPath *ip = [self.table indexPathForRowAtPoint:[g locationInView:self.table]];
        if (!ip) return;
        [self setSheetPansEnabled:NO];
        self.dragSelecting = YES;
        self.table.scrollEnabled = NO;
        NSArray *apps = self.sections[ip.section][@"apps"];
        self.dragAnchor = ip;
        self.dragAnchorWasPicked = ![self.picked containsObject:apps[ip.row]];   // 锚点行本身翻转
        self.dragBasePicked = [NSMutableArray arrayWithArray:self.picked];   // 按下前的选择，用于区间外还原
        [self applyDragAt:ip];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.dragSelecting) {
            CGPoint wp = [g locationInView:nil];
            [self applyDragAt:[self.table indexPathForRowAtPoint:[self.table convertPoint:wp fromView:nil]]];
            [self updateDragAutoScroll:wp];
        }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self.dragScrollTimer invalidate];
        self.dragScrollTimer = nil;
        self.dragScrollDelta = 0;
        if (self.dragSelecting) {
            self.dragSelecting = NO;
            self.dragAnchor = nil;
            self.dragBasePicked = nil;
            self.table.scrollEnabled = YES;
            [self updateGo];
        }
        __weak TFListVC *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [ws setSheetPansEnabled:YES]; });
    }
}

#pragma mark 已安装

- (void)applyInstalledSet:(NSSet *)set note:(NSString *)note {
    NSUInteger hit = 0, total = 0;
    NSMutableArray *sample = [NSMutableArray array];
    for (NSDictionary *sec in self.sections) {
        for (id a in sec[@"apps"]) {
            total++;
            NSString *b = strOf(a, @"bundleID");
            if (b.length && [set containsObject:b]) { hit++; if (sample.count < 3) [sample addObject:b]; }
        }
    }
    LOG(@"[installed] %@ 共 %lu 个；与列表匹配 %lu/%lu 例:%@", note, (unsigned long)set.count,
        (unsigned long)hit, (unsigned long)total, [sample componentsJoinedByString:@","]);
    if (hit == 0 && total > 0) {
        NSMutableArray *mine = [NSMutableArray array], *theirs = [NSMutableArray array];
        for (NSDictionary *sec in self.sections)
            for (id a in sec[@"apps"]) {
                NSString *b = strOf(a, @"bundleID");
                if (b.length && mine.count < 3) [mine addObject:b];
            }
        NSInteger i = 0;
        for (NSString *b in set) { if (i++ >= 3) break; [theirs addObject:b]; }
        LOG(@"[installed] 未匹配！我方样本=%@  系统样本=%@", [mine componentsJoinedByString:@","],
            [theirs componentsJoinedByString:@","]);
    }
    if (!set.count) return;
    gInstalledBundleIDs = set;
    __weak TFListVC *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ws.installedBundleIDs = set;
        [ws.table reloadData];
    });
}

// 兜底方案：LSApplicationWorkspace
- (BOOL)loadInstalledAppsViaLS {
    @try {
        Class ls = objc_getClass("LSApplicationWorkspace");
        SEL dsel = NSSelectorFromString(@"defaultWorkspace");
        SEL asel = NSSelectorFromString(@"allInstalledApplications");
        if (!ls || ![ls respondsToSelector:dsel]) return NO;
        id ws = ((id (*)(id, SEL))objc_msgSend)(ls, dsel);
        if (!ws || ![ws respondsToSelector:asel]) return NO;
        NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, asel);
        NSMutableSet *set = [NSMutableSet set];
        for (id a in apps) {
            NSString *b = strOf(a, @"bundleIdentifier");
            if (!b.length) b = strOf(a, @"applicationIdentifier");
            if (b.length) [set addObject:b];
        }
        [self applyInstalledSet:set note:@"LSApplicationWorkspace"];
        return set.count > 0;
    } @catch (NSException *e) { LOG(@"[installed] LS ex %@", e.name); }
    return NO;
}

- (void)loadBetaInstalledApps {
    id sc = tftoolSessionContext();
    Class ctxCls = objc_getClass("OASAppContext");
    if (!sc || !ctxCls) { LOG(@"[beta] 没有 sessionContext/OASAppContext"); return; }
    if (!gBetaInstalledBundleIDs) gBetaInstalledBundleIDs = [NSMutableSet set];
    NSUInteger n = 0;
    for (NSDictionary *sec in self.sections) {
        for (id app in sec[@"apps"]) {
            @try {
                id ctx = [[ctxCls alloc] initWithAppStub:app andSessionContext:sc];
                NSString *ver = strOf(ctx, @"installedBuildGroupOrVersion");
                NSString *bid = strOf(app, @"bundleID");
                if (ver.length && bid.length) { [gBetaInstalledBundleIDs addObject:bid]; n++; }
            } @catch (NSException *e) {}
        }
    }
    LOG(@"[beta] 测试版已装 %lu 个", (unsigned long)n);
    dispatch_async(dispatch_get_main_queue(), ^{ [self.table reloadData]; });
}

- (void)loadInstalledApps {
    id sc = tftoolSessionContext();
    id im = call0(sc, @"installManager");
    SEL sel = NSSelectorFromString(@"fetchInstalledAppsWithCompletion:");
    if (!im || ![im respondsToSelector:sel]) {
        LOG(@"[installed] 没有 installManager，改用 LSApplicationWorkspace");
        [self loadInstalledAppsViaLS];
        return;
    }
    LOG(@"[installed] 开始查询 (im=%@)", NSStringFromClass([im class]));
    __weak TFListVC *ws = self;
    ((void (*)(id, SEL, id))objc_msgSend)(im, sel, ^(NSArray *installed) {
        NSMutableSet *set = [NSMutableSet set];
        id sample = nil;
        for (id a in installed) {
            if (!sample) sample = a;
            NSString *b = strOf(a, @"bundleID");
            if (!b.length) b = strOf(a, @"applicationIdentifier");
            if (!b.length) b = strOf(a, @"bundleIdentifier");
            if (b.length) [set addObject:b];
        }
        LOG(@"[installed] 得到 %lu 个（示例类型=%@）", (unsigned long)set.count,
            sample ? NSStringFromClass([sample class]) : @"-");
        if (set.count) [self applyInstalledSet:set note:@"installManager"];
        else { LOG(@"[installed] installManager 返回 0，改用 LSApplicationWorkspace"); [self loadInstalledAppsViaLS]; }
    });
}

- (NSArray *)allApps { return tftoolFlatten(self.sections ?: @[]); }

- (void)reload {
    self.sections = tftoolCollectSections();
    if ([[self allApps] count] > 0) {
        if (!gInstalledBundleIDs) [self loadInstalledApps];
        if (!gBetaInstalledBundleIDs) [self loadBetaInstalledApps];
    }   // 有 App 了再去查安装状态
    [self.picked removeAllObjects];
    [self.table reloadData];
    [self updateGo];
    if (!objc_getClass("OASIconURLImageView")) {   // 没有原生图标视图时才退回公共接口
        NSMutableArray *ids = [NSMutableArray array];
        for (id a in [self allApps]) { NSString *s = strOf(a, @"appID"); if (s.length) [ids addObject:s]; }
        __weak TFListVC *ws = self;
        tftoolPrefetchIcons([self allApps], ids, ^{ [ws.table reloadData]; });
    }
}

- (void)clearSelection {
    [self.picked removeAllObjects];
    [self.table reloadData];
    [self updateGo];
}

- (void)updateGo {
    NSArray *all = [self allApps];
    BOOL allSelected = all.count && self.picked.count == all.count;
    self.selAllItem.title = allSelected ? @"全不选" : @"全选";
    self.selAllItem.enabled = all.count > 0;
    self.goButton.enabled = self.picked.count > 0;
    UILabel *l = (UILabel *)self.countItem.customView;
    if ([l isKindOfClass:[UILabel class]]) {
        l.text = [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)self.picked.count];
        [l sizeToFit];
    }
    self.title = all.count ? [NSString stringWithFormat:@"批量测试 (%lu)", (unsigned long)all.count] : @"批量测试";
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.onClose) self.onClose();
}
- (void)close {
    if (self.onClose) self.onClose();
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)toggleAll {
    NSArray *all = [self allApps];
    if (self.picked.count == all.count) [self.picked removeAllObjects];
    else { [self.picked removeAllObjects]; [self.picked addObjectsFromArray:all]; }
    [self.table reloadData];
    [self updateGo];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self.sections[s][@"apps"] count];
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    NSString *t = self.sections[s][@"title"];
    return t.length ? t : nil;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    id app = self.sections[ip.section][@"apps"][ip.row];
    if ([self.picked containsObject:app]) [self.picked removeObject:app]; else [self.picked addObject:app];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self updateGo];
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TFAppCell *c = [tv dequeueReusableCellWithIdentifier:@"app"];
    if (!c) c = [[TFAppCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"app"];
    id app = self.sections[ip.section][@"apps"][ip.row];
    [c configureWithApp:app picked:[self.picked containsObject:app]];
    return c;
}

- (void)go {
    NSArray *targets = [self.picked copy];
    if (!targets.count) return;
    NSUInteger total = [[self allApps] count];
    BOOL big = (targets.count >= 5) || (targets.count == total);
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"停止测试"
                         message:[NSString stringWithFormat:@"将停止测试 %lu 个 App。", (unsigned long)targets.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:(big ? @"继续" : @"执行")
                                          style:(big ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                        handler:^(UIAlertAction *a) {
        if (big) [self confirmAndRun:targets];
        else [self runFor:targets];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)confirmAndRun:(NSArray *)targets {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"再次确认"
                         message:[NSString stringWithFormat:@"将停止测试 %lu 个 App。停止后这些 App 会从列表移除，"
                                                            @"要恢复测试需要重新接受邀请或兑换码。", (unsigned long)targets.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确认停止" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) { [self runFor:targets]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)runFor:(NSArray *)targets {
    __block NSArray *processed = [targets copy];
    __block NSInteger pending = (NSInteger)targets.count;
    __block NSInteger failed = 0;
    self.goButton.enabled = NO;
    self.goButton.title = @"处理中…";
    LOG(@"[run] 开始处理 %lu 个 | list=%p sc=%p mgr=%p", (unsigned long)targets.count,
        tftoolNewestList(), tftoolSessionContext(), tftoolInviteManager());
    void (^finish)(void) = ^{
        LOG(@"[run] 结束 failed=%ld", (long)failed);
        @try { [tftoolNewestList() refresh]; } @catch (NSException *e) {}
        NSMutableArray *left = [NSMutableArray array];
        for (NSDictionary *sec in self.sections) {
            NSMutableArray *apps = [sec[@"apps"] mutableCopy];
            if (processed) [apps removeObjectsInArray:processed];
            [left addObject:@{@"title": sec[@"title"] ?: @"", @"apps": apps}];
        }
        self.sections = left;
        [self.picked removeAllObjects];
        [self.table reloadData];
        [self updateGo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reload];
            NSString *msg = failed
                ? [NSString stringWithFormat:@"成功 %lu 个，失败 %ld 个。", (unsigned long)targets.count - (unsigned long)failed, (long)failed]
                : [NSString stringWithFormat:@"已停止 %lu 个 App 的测试。", (unsigned long)targets.count];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"批量停止测试"
                message:msg preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        });
    };
    for (id app in targets) {
        NSString *name = strOf(app, @"name"), *how = nil;
        LOG(@"[run] → %@ | %@", name, strOf(app, @"bundleID"));
        BOOL started = tftoolStopOne(app, ^{
            pending--; LOG(@"[run] cb %@(%@) 剩 %ld", name, how ?: @"?", (long)pending);
            if (pending <= 0) finish();
        }, &how);
        if (!started) { failed++; pending--; }
        else if ([how hasSuffix:@"plain"]) { pending--; }
    }
    if (pending <= 0) finish();
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (pending > 0) { LOG(@"[run] 超时 剩 %ld", (long)pending); finish(); }
    });
}
@end

#pragma mark - 入口按钮

@interface TFDrag : NSObject @end
@implementation TFDrag
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; if (!v.superview) return;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static TFDrag *gDrag;
static UIButton *gButton;
static __weak UIWindow *gHostWindow;

static UIWindow *tftoolKeyWindow(void) {
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

// 找一个可见的底部 tab bar；有 tab bar 时把悬浮按钮放在它上方
static UITabBar *tftoolVisibleTabBar(UIView *root, int depth) {
    if (!root || root.hidden || root.alpha < 0.05 || depth > 12) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return (UITabBar *)root;
    for (UIView *sub in root.subviews) {
        UITabBar *bar = tftoolVisibleTabBar(sub, depth + 1);
        if (bar) return bar;
    }
    return nil;
}

static void tftoolPresentList(void) {
    @try {
        UIWindow *w = gHostWindow ?: tftoolKeyWindow();
        UIViewController *host = w.rootViewController;
        if (!host) { LOG(@"[ui] 没有可用的 rootViewController"); return; }
        TFListVC *vc = [[TFListVC alloc] init];
        vc.onClose = ^{ if (gButton) gButton.hidden = NO; };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                              UISheetPresentationControllerDetent.largeDetent];
            sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 16;
            sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        }
        gButton.hidden = YES;
        [host presentViewController:nav animated:YES completion:nil];
        LOG(@"[ui] 已弹出列表页");
    } @catch (NSException *e) { LOG(@"[ui] ex %@ %@", e.name, e.reason); }
}

static void tftoolPlaceButton(UIWindow *w) {
    if (!gButton.superview) [w addSubview:gButton];
    [w bringSubviewToFront:gButton];
    CGSize sz = w.bounds.size;
    CGRect bb = gButton.bounds;
    CGFloat bottomY = sz.height - w.safeAreaInsets.bottom;
    UITabBar *tab = tftoolVisibleTabBar(w, 0);
    if (tab) {
        CGRect tf = [tab convertRect:tab.bounds toView:w];
        if (tf.size.height > 1 && CGRectGetMinY(tf) < bottomY) bottomY = CGRectGetMinY(tf);
    }
    CGRect f = CGRectMake(sz.width - bb.size.width - 16,
                          bottomY - bb.size.height - 16,
                          bb.size.width, bb.size.height);
    if (!CGRectEqualToRect(gButton.frame, f)) {
        gButton.frame = f;
        LOG(@"[ui] 悬浮按钮 %@", NSStringFromCGRect(f));
    }
}

static void tftoolAttachButton(void) {
    @try {
        UIWindow *w = tftoolKeyWindow();
        if (!w) return;
        if (!gButton) {
            gButton = [UIButton buttonWithType:UIButtonTypeSystem];
            gButton.frame = CGRectMake(0, 0, 64, 36);
            [gButton setTitle:@"批量" forState:UIControlStateNormal];
            gButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            [gButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            gButton.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.92];
            gButton.layer.cornerRadius = 18;
            gButton.clipsToBounds = YES;
            [gButton addAction:[UIAction actionWithHandler:^(UIAction *a) { tftoolPresentList(); }]
                    forControlEvents:UIControlEventTouchUpInside];
        }
        if (!w.rootViewController.presentedViewController) gButton.hidden = NO;
        gHostWindow = w;
        tftoolPlaceButton(w);
    } @catch (NSException *e) { LOG(@"[ui] ex %@ %@", e.name, e.reason); }
}

__attribute__((constructor)) static void tftool_init(void) {
    @try {
        LOG(@"=== TFTool 6.1 loaded in %@ ===", [NSBundle mainBundle].bundleIdentifier);
        if ([[NSFileManager defaultManager] fileExistsAtPath:docPath(@"tftool.off")]) {
            LOG(@"[init] 检测到 tftool.off，停止加载");
            return;
        }
        tftoolInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            tftoolAttachButton();
        });
        // 之后每 3 秒检查一次（窗口/前台变化时补挂按钮）
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                  (uint64_t)(3 * NSEC_PER_SEC), (uint64_t)(NSEC_PER_SEC / 2));
        dispatch_source_set_event_handler(t, ^{ tftoolAttachButton(); });
        dispatch_resume(t);
    } @catch (NSException *e) { LOG(@"[init] ex %@ %@", e.name, e.reason); }
}
