//
//  LoonBatchTweak.m — Loon 插件/规则批量管理
//  在每个列表页右下角加「批量」按钮，打开自建多选页，读取当前配置的模型后批量处理。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#pragma mark - 日志

static void LBL(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/loonbatch.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:p];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        NSLog(@"[LoonBatch] %@", s);
    } @catch (NSException *e) {}
}

#pragma mark - Loon 模型的最小声明（按运行时 selector 调用）

@interface LNPlugin : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, copy) NSString *pluginName;
@property (nonatomic, copy) NSString *remoteUrl;
@property (nonatomic, assign) BOOL enable;
@property (nonatomic, assign) BOOL pin;
@end

@interface LNRule : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *strategyName;
@property (nonatomic, copy) NSString *playload;
@property (nonatomic, assign) NSInteger resourceType;
@end

@interface LNRemoteRule : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *desc;
@property (nonatomic, copy) NSString *remoteUrl;
@property (nonatomic, copy) NSString *strategyName;
@property (nonatomic, copy) NSString *tag;
@end

@interface LNDCConfigModel : NSObject
@property (nonatomic, strong) NSArray *plugins;
@property (nonatomic, strong) NSArray *localRule;
@property (nonatomic, strong) NSArray *remoteRules;
@property (nonatomic, strong) NSArray *proxys;
@property (nonatomic, strong) NSArray *remoteProxys;
@property (nonatomic, copy) NSString *fileName;
- (void)saveConfigPlayload;
@end

@interface LNDataManager : NSObject
+ (instancetype)shareInstance;
- (LNDCConfigModel *)currentConfigModel;
- (NSString *)currentConfigFileName;
- (void)postChangeNoti;
@end

@interface LNRuleArchieveManager : NSObject
+ (instancetype)shareInstance;
- (void)deleteLocalRule:(id)rule;
- (void)deleteRemoteRule:(id)rule;
- (void)deletePluginRules:(id)plugin;
@end

#pragma mark - 工具

static id msg0(id o, NSString *s) {
    if (!o) return nil;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(o, sel); } @catch (NSException *e) { return nil; }
}
static void msgv(id o, NSString *s) {
    if (!o) return;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(o, sel); } @catch (NSException *e) {}
}
static void msg1(id o, NSString *s, id arg) {
    if (!o) return;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(o, sel, arg); } @catch (NSException *e) {}
}
static NSString *strv(id o, NSString *s) {
    @try { id v = msg0(o, s); return [v isKindOfClass:[NSString class]] ? v : nil; } @catch (NSException *e) { return nil; }
}
static BOOL boolv(id o, NSString *s) {
    if (!o) return NO;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(o, sel); } @catch (NSException *e) { return NO; }
}
static NSInteger intv(id o, NSString *s) {
    if (!o) return 0;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return 0;
    @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(o, sel); } @catch (NSException *e) { return 0; }
}
static BOOL setBoolv(id o, NSString *s, BOOL v) {
    if (!o) return NO;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(o, sel, v); return YES; } @catch (NSException *e) { return NO; }
}

static BOOL ptrContains(NSArray *arr, id item) {
    for (id x in arr) if (x == item) return YES;
    return NO;
}
static void ptrToggle(NSMutableArray *arr, id item) {
    NSUInteger i = NSNotFound;
    for (NSUInteger j = 0; j < arr.count; j++) if (arr[j] == item) { i = j; break; }
    if (i == NSNotFound) [arr addObject:item]; else [arr removeObjectAtIndex:i];
}
static NSArray *arrayByRemovingPtrs(NSArray *src, NSArray *remove) {
    NSMutableArray *out = [NSMutableArray array];
    for (id x in src ?: @[]) if (!ptrContains(remove, x)) [out addObject:x];
    return out;
}

#pragma mark - 插件原生名称

static NSURL *loonGroupURL(void) {
    static NSURL *url;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            url = [[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:@"group.com.ruikq.decar"];
        } @catch (NSException *e) { url = nil; }
    });
    return url;
}

static NSString *md5Hex(NSString *s) {
    if (!s.length) return nil;
    const char *utf8 = s.UTF8String;
    if (!utf8) return nil;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(utf8, (CC_LONG)strlen(utf8), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
    return out;
}

static NSString *trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *nameInPluginText(NSString *text) {
    if (!text.length) return nil;
    NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *t = trimmed(line);
        if (![t hasPrefix:@"#!name"]) continue;
        NSRange eq = [t rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *v = trimmed([t substringFromIndex:eq.location + 1]);
        v = [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
        if (v.length) return v;
    }
    return nil;
}

static NSString *pluginNameFromDisk(NSString *url) {
    NSString *hash = md5Hex(url);
    NSURL *group = loonGroupURL();
    if (!group || !hash.length) return nil;
    NSArray *dirs = @[@"remotePlugin", @"privatePlugin"];
    NSArray *exts = @[@"lpx", @"plugin"];
    for (NSString *d in dirs) {
        for (NSString *e in exts) {
            NSURL *f = [[[group URLByAppendingPathComponent:d isDirectory:YES]
                          URLByAppendingPathComponent:hash] URLByAppendingPathExtension:e];
            NSData *data = [NSData dataWithContentsOfURL:f options:NSDataReadingMappedIfSafe error:NULL];
            if (!data.length) continue;
            NSUInteger len = MIN(data.length, (NSUInteger)65536);
            NSData *head = (len == data.length) ? data : [data subdataWithRange:NSMakeRange(0, len)];
            NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
            NSString *name = nameInPluginText(text);
            if (name.length) return name;
        }
    }
    return nil;
}

static NSString *pluginNativeName(NSString *url) {
    if (!url.length) return nil;
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSString *cached = cache[url];
        if (cached.length) return cached;
        NSString *name = pluginNameFromDisk(url);
        if (name.length) cache[url] = name;
        return name;
    }
}

static BOOL looksLikeHash(NSString *s) {
    if (s.length != 32) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return NO;
    }
    return YES;
}

static id pluginObject(id p) {
    id o = msg0(p, @"plugin");
    return o ?: p;
}

static BOOL itemEnabled(id item) {
    id t = pluginObject(item);
    if ([t respondsToSelector:NSSelectorFromString(@"enable")]) return boolv(t, @"enable");
    if ([t respondsToSelector:NSSelectorFromString(@"enabled")]) return boolv(t, @"enabled");
    return NO;
}

static BOOL itemSetEnabled(id item, BOOL enable) {
    id t = pluginObject(item);
    if ([t respondsToSelector:NSSelectorFromString(@"setEnable:")]) return setBoolv(t, @"setEnable:", enable);
    if ([t respondsToSelector:NSSelectorFromString(@"setEnabled:")]) return setBoolv(t, @"setEnabled:", enable);
    return NO;
}

static BOOL itemCanToggle(id item) {
    id t = pluginObject(item);
    return [t respondsToSelector:NSSelectorFromString(@"setEnable:")]
        || [t respondsToSelector:NSSelectorFromString(@"setEnabled:")];
}

static BOOL isRemoteProxy(id x) {
    Class c = NSClassFromString(@"RemoteProxy");
    return c && [x isKindOfClass:c];
}

static NSString *pluginTitle(id p) {
    id o = pluginObject(p);
    NSString *tag = strv(o, @"tag");
    if (tag.length && !looksLikeHash(tag)) return tag;
    NSString *pn = strv(o, @"pluginName");
    if (pn.length && ![pn isEqualToString:@"local"] && !looksLikeHash(pn)) return pn;
    NSString *url = strv(o, @"remoteUrl");
    NSString *name = pluginNativeName(url);
    if (!name.length || [name isEqualToString:@"local"]) {
        NSString *file = [url lastPathComponent].stringByDeletingPathExtension;
        if (file.length && !looksLikeHash(file)) name = file;
    }
    if (!name.length) name = strv(o, @"name");
    return name.length ? name : @"(未命名插件)";
}

static NSString *pluginSubtitle(id p) {
    id o = pluginObject(p);
    return strv(o, @"remoteUrl") ?: @"";
}

static NSString *ruleTitle(id r) {
    NSString *s = strv(r, @"playload");
    if (!s.length) {
        NSString *k = strv(r, @"key"), *p = strv(r, @"strategyName");
        if (k.length && p.length) s = [NSString stringWithFormat:@"%@ → %@", k, p];
        else s = k;
    }
    return s.length ? s : @"(空规则)";
}

static NSString *remoteRuleTitle(id r) {
    NSString *s = strv(r, @"name");
    if (!s.length || looksLikeHash(s)) s = strv(r, @"tag");
    if (!s.length) s = [strv(r, @"remoteUrl") lastPathComponent];
    return s.length ? s : @"(未命名远程规则)";
}

static NSString *remoteRuleSubtitle(id r) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *u = strv(r, @"remoteUrl");
    if (u.length) [a addObject:u];
    NSString *p = strv(r, @"strategyName");
    if (p.length) [a addObject:p];
    NSString *d = strv(r, @"desc");
    if (d.length) [a addObject:d];
    return [a componentsJoinedByString:@" · "];
}

static NSString *nodeTitle(id n) {
    NSString *s = strv(n, @"proxyName");
    if (!s.length) s = strv(n, @"remarks");
    if (!s.length) s = strv(n, @"name");
    return s.length ? s : @"(未命名节点)";
}

static NSString *nodeSubtitle(id n) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *proto = strv(n, @"protocol");
    if (proto.length) [a addObject:proto];
    NSString *host = strv(n, @"serverAddress");
    NSInteger port = intv(n, @"serverPort");
    if (host.length) [a addObject:(port > 0 ? [NSString stringWithFormat:@"%@:%ld", host, (long)port] : host)];
    NSString *url = strv(n, @"remoteUrl");
    if (url.length) [a addObject:url];
    return [a componentsJoinedByString:@" · "];
}

static id dataManager(void) {
    Class c = NSClassFromString(@"DataManager");
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("shareInstance"));
}
static id ruleManager(void) {
    Class c = NSClassFromString(@"RuleArchieveManager");
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("shareInstance"));
}

static LNDCConfigModel *currentConfig(void) {
    Class dmc = NSClassFromString(@"DataManager");
    if (!dmc) return nil;
    id dm = ((id (*)(id, SEL))objc_msgSend)(dmc, sel_registerName("shareInstance"));
    id c = msg0(dm, @"currentConfigModel");
    return [c isKindOfClass:NSClassFromString(@"DCConfigModel")] ? c : nil;
}

static LNDCConfigModel *configFromObject(id obj) {
    if (!obj) return nil;
    Class modelClass = NSClassFromString(@"DCConfigModel");
    if (!modelClass) return nil;
    @try {
        id c = msg0(obj, @"configModel");
        if ([c isKindOfClass:modelClass]) return c;
    } @catch (NSException *e) {}
    @try {
        SEL sel = NSSelectorFromString(@"currentConfigModel");
        if ([obj respondsToSelector:sel]) {
            id c = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([c isKindOfClass:modelClass]) return c;
        }
    } @catch (NSException *e) {}
    // Swift VC 的 currentConfigModel 通常是 Swift 存储属性，KVC 取不到时读 ivar。
    @try {
        Class cls = object_getClass(obj);
        while (cls) {
            Ivar iv = class_getInstanceVariable(cls, "configModel");
            if (!iv) iv = class_getInstanceVariable(cls, "currentConfigModel");
            if (iv) {
                id c = object_getIvar(obj, iv);
                if ([c isKindOfClass:modelClass]) return c;
                break;
            }
            cls = class_getSuperclass(cls);
        }
    } @catch (NSException *e) {}
    return nil;
}
static LNDCConfigModel *configForHost(id host) {
    LNDCConfigModel *c = currentConfig();
    if (c) return c;
    c = configFromObject(host);
    if (c) return c;
    return currentConfig();
}

static void backupConfig(LNDCConfigModel *config) {
    @try {
        NSString *fileName = strv(config, @"fileName");
        if (!fileName.length) fileName = msg0(dataManager(), @"currentConfigFileName");
        if (!fileName.length) return;
        NSURL *group = loonGroupURL();
        if (!group) return;
        NSURL *src = [[group URLByAppendingPathComponent:@"config"] URLByAppendingPathComponent:fileName.lastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:src.path]) return;
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LoonBatch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *dst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@",
            [df stringFromDate:[NSDate date]], fileName.lastPathComponent]];
        NSError *err = nil;
        if ([[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err])
            LBL(@"已备份配置 %@", dst);
        else
            LBL(@"备份失败 %@", err);
    } @catch (NSException *e) { LBL(@"备份异常 %@", e); }
}

static const NSInteger kLBDimTag = 0x4C43;

static void setCellDimmed(UITableViewCell *cell, BOOL dimmed) {
    if (!cell) return;
    UIView *overlay = [cell viewWithTag:kLBDimTag];
    if (dimmed) {
        cell.alpha = 1.0;
        if (!overlay) {
            overlay = [[UIView alloc] initWithFrame:cell.bounds];
            overlay.tag = kLBDimTag;
            overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            overlay.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.55];
            overlay.userInteractionEnabled = NO;
            [cell addSubview:overlay];
        }
    } else {
        if (overlay) [overlay removeFromSuperview];
        cell.alpha = 1.0;
    }
}

static UIImage *renderCellImage(UITableViewCell *cell) {
    if (!cell || cell.bounds.size.width < 1 || cell.bounds.size.height < 1) return nil;
    CGSize size = cell.bounds.size;
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.secondarySystemGroupedBackgroundColor setFill];
        [ctx fillRect:CGRectMake(0, 0, size.width, size.height)];
        [cell.layer renderInContext:ctx.CGContext];
    }];
}

static BOOL samePtrOrder(NSArray *a, NSArray *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) if (a[i] != b[i]) return NO;
    return YES;
}

#pragma mark - 批量页

typedef NS_ENUM(NSInteger, LNBLMode) {
    LNBLModePlugins = 1,
    LNBLModeRules = 2,
    LNBLModeNodes = 3,
};

@interface LNBatchCell : UITableViewCell
@end

@implementation LNBatchCell
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.detailTextLabel.text.length == 0 && self.textLabel.text.length > 0) {
        CGRect f = self.textLabel.frame;
        f.origin.y = (CGRectGetHeight(self.contentView.bounds) - CGRectGetHeight(f)) / 2.0;
        self.textLabel.frame = f;
    }
}
@end

@interface LNBatchVC : UITableViewController <UIGestureRecognizerDelegate>
@property (nonatomic, assign) LNBLMode mode;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, strong) NSMutableArray *sections;   // @{title, items}
@property (nonatomic, strong) NSMutableArray *selected;   // 指针比较
@property (nonatomic, strong) UIBarButtonItem *selectAllItem;
@property (nonatomic, strong) UIBarButtonItem *countItem;
@property (nonatomic, strong) UIBarButtonItem *actionItem;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) NSArray *dragGroup;
@property (nonatomic, assign) NSInteger dragSection;
@property (nonatomic, assign) NSInteger dragInsertRow;
@property (nonatomic, assign) CGPoint dragViewPoint;
@property (nonatomic, assign) CGPoint dragStartViewPoint;
@property (nonatomic, assign) BOOL dragMoved;
@property (nonatomic, strong) UIView *dragPreview;
@property (nonatomic, strong) UIView *dropIndicator;
@property (nonatomic, strong) CADisplayLink *dragScrollLink;
@end

@implementation LNBatchVC

- (instancetype)initWithMode:(LNBLMode)mode host:(UIViewController *)host {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _mode = mode;
    _host = host;
    _selected = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 62;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.decelerationRate = UIScrollViewDecelerationRateFast;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.35;
    lp.allowableMovement = 12;
    lp.cancelsTouchesInView = YES;
    lp.delegate = self;
    [self.tableView addGestureRecognizer:lp];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];
    [self setupToolbar];
    [self reloadData];
}

- (void)setupToolbar {
    self.selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                                         target:self action:@selector(toggleSelectAll)];
    UILabel *countLabel = [[UILabel alloc] init];
    countLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    countLabel.textColor = UIColor.secondaryLabelColor;
    countLabel.text = @"已选 0";
    [countLabel sizeToFit];
    self.countItem = [[UIBarButtonItem alloc] initWithCustomView:countLabel];
    self.actionItem = [[UIBarButtonItem alloc] initWithTitle:@"操作" style:UIBarButtonItemStylePlain
                                                      target:nil action:nil];
    UIBarButtonItem *f1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                        target:nil action:nil];
    UIBarButtonItem *f2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                        target:nil action:nil];
    self.toolbarItems = @[self.selectAllItem, f1, self.countItem, f2, self.actionItem];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = NO;
    [self.navigationController setToolbarHidden:NO animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.dragGroup.count) [self endCustomDrag:NO];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [self.navigationController setToolbarHidden:YES animated:NO];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.sections.count == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reloadData];
            if (self.sections.count == 0) {
                UILabel *l = [[UILabel alloc] initWithFrame:self.tableView.bounds];
                l.text = @"没有可管理的项目\n或配置尚未就绪，请返回列表后重试";
                l.numberOfLines = 2;
                l.textAlignment = NSTextAlignmentCenter;
                l.textColor = UIColor.secondaryLabelColor;
                self.tableView.backgroundView = l;
            }
        });
    }
}

- (void)reloadData {
    LNDCConfigModel *config = configForHost(self.host);
    self.sections = [NSMutableArray array];
    if (!config) {
        self.title = @"批量";
        [self.tableView reloadData];
        [self updateButtons];
        return;
    }
    self.tableView.backgroundView = nil;
    if (self.mode == LNBLModePlugins) {
        NSArray *items = config.plugins ?: @[];
        self.title = [NSString stringWithFormat:@"批量插件 (%lu)", (unsigned long)items.count];
        [self.sections addObject:@{@"title": @"插件", @"items": items, @"kind": @"plugins"}];
    } else if (self.mode == LNBLModeNodes) {
        NSArray *local = config.proxys ?: @[];
        NSArray *remote = config.remoteProxys ?: @[];
        self.title = [NSString stringWithFormat:@"批量节点 (%lu)", (unsigned long)(local.count + remote.count)];
        if (local.count) [self.sections addObject:@{@"title": @"本地节点", @"items": local, @"kind": @"localNodes"}];
        if (remote.count) [self.sections addObject:@{@"title": @"订阅", @"items": remote, @"kind": @"remoteProxies"}];
    } else {
        NSArray *local = config.localRule ?: @[];
        NSArray *remote = config.remoteRules ?: @[];
        self.title = [NSString stringWithFormat:@"批量规则 (%lu)", (unsigned long)(local.count + remote.count)];
        if (local.count) [self.sections addObject:@{@"title": @"本地规则", @"items": local, @"kind": @"localRules"}];
        if (remote.count) [self.sections addObject:@{@"title": @"远程规则", @"items": remote, @"kind": @"remoteRules"}];
    }
    NSArray *all = [self allItems];
    NSMutableArray *still = [NSMutableArray array];
    for (id x in self.selected) if (ptrContains(all, x)) [still addObject:x];
    self.selected = still;
    NSUInteger total = all.count;
    LBL(@"批量页 mode=%ld config=%@ sections=%lu items=%lu", (long)self.mode,
        NSStringFromClass([config class]), (unsigned long)self.sections.count, (unsigned long)total);
    __block CGPoint offset = self.tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [self.tableView reloadData];
        [self.tableView layoutIfNeeded];
        CGFloat minY = -self.tableView.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, self.tableView.contentSize.height - self.tableView.bounds.size.height
                                   + self.tableView.adjustedContentInset.bottom);
        offset.y = MIN(MAX(offset.y, minY), maxY);
        self.tableView.contentOffset = offset;
    }];
    [self updateButtons];
}

- (NSArray *)allItems {
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *s in self.sections) [all addObjectsFromArray:s[@"items"]];
    return all;
}

- (NSArray *)itemsForSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return @[];
    return self.sections[section][@"items"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [self itemsForSection:s].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sections[s][@"title"];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if ([self itemsForSection:s].count < 2) return nil;
    return @"长按拖动可排序；勾选多行后拖动会整组移动";
}

- (UIView *)statusAccessoryForItem:(id)item selected:(BOOL)selected {
    BOOL hasStatus = NO, enabled = NO;
    id t = pluginObject(item);
    if ([t respondsToSelector:NSSelectorFromString(@"enabled")]) {
        hasStatus = YES;
        enabled = boolv(t, @"enabled");
    } else if ([t respondsToSelector:NSSelectorFromString(@"enable")]) {
        hasStatus = YES;
        enabled = boolv(t, @"enable");
    }
    CGFloat w = hasStatus ? 98 : 26;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 30)];
    if (hasStatus) {
        UILabel *pill = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 64, 22)];
        pill.text = enabled ? @"已启用" : @"已禁用";
        pill.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        pill.textAlignment = NSTextAlignmentCenter;
        pill.textColor = enabled ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        pill.backgroundColor = enabled
            ? [UIColor.systemGreenColor colorWithAlphaComponent:0.14]
            : [UIColor.systemGrayColor colorWithAlphaComponent:0.14];
        pill.layer.cornerRadius = 11;
        pill.clipsToBounds = YES;
        [box addSubview:pill];
    }
    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    check.frame = CGRectMake(hasStatus ? 72 : 3, 5, 20, 20);
    check.tintColor = UIColor.systemBlueColor;
    check.hidden = !selected;
    [box addSubview:check];
    return box;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    LNBatchCell *c = [tv dequeueReusableCellWithIdentifier:@"cell"];
    if (!c) c = [[LNBatchCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    id item = [self itemsForSection:ip.section][ip.row];
    if (self.mode == LNBLModePlugins) {
        c.textLabel.text = pluginTitle(item);
        c.detailTextLabel.text = pluginSubtitle(item);
    } else if (self.mode == LNBLModeNodes) {
        c.textLabel.text = nodeTitle(item);
        c.detailTextLabel.text = nodeSubtitle(item);
    } else if ([item isKindOfClass:NSClassFromString(@"RemoteRule")]) {
        c.textLabel.text = remoteRuleTitle(item);
        c.detailTextLabel.text = remoteRuleSubtitle(item);
    } else {
        id inner = msg0(item, @"remoteRule") ?: msg0(item, @"rule");
        if ([inner isKindOfClass:NSClassFromString(@"RemoteRule")]) {
            c.textLabel.text = remoteRuleTitle(inner);
            c.detailTextLabel.text = remoteRuleSubtitle(inner);
        } else {
            c.textLabel.text = ruleTitle(inner ?: item);
            c.detailTextLabel.text = @"";
        }
    }
    c.textLabel.font = [UIFont systemFontOfSize:16];
    c.detailTextLabel.numberOfLines = 1;
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.accessoryView = [self statusAccessoryForItem:item selected:ptrContains(self.selected, item)];
    setCellDimmed(c, self.dragGroup.count && ptrContains(self.dragGroup, item));
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    id item = [self itemsForSection:ip.section][ip.row];
    ptrToggle(self.selected, item);
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [tv deselectRowAtIndexPath:ip animated:NO];
    [self updateButtons];
}

- (void)toggleSelectAll {
    NSArray *all = [self allItems];
    BOOL allSelected = all.count > 0;
    for (id x in all) if (!ptrContains(self.selected, x)) { allSelected = NO; break; }
    [self.selected removeAllObjects];
    if (!allSelected) for (id x in all) [self.selected addObject:x];
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)updateButtons {
    NSUInteger n = self.selected.count;
    UILabel *countLabel = (UILabel *)self.countItem.customView;
    if ([countLabel isKindOfClass:[UILabel class]]) {
        countLabel.text = [NSString stringWithFormat:@"已选 %lu", (unsigned long)n];
        [countLabel sizeToFit];
    }
    NSArray *all = [self allItems];
    BOOL allSelected = all.count > 0;
    for (id x in all) if (!ptrContains(self.selected, x)) { allSelected = NO; break; }
    self.selectAllItem.title = allSelected ? @"全不选" : @"全选";
    self.selectAllItem.enabled = all.count > 0;
    self.actionItem.enabled = all.count > 0;
    self.actionItem.menu = [self buildActionMenu];
}

#pragma mark 自定义拖动排序
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}


- (UIView *)dragOverlayHost {
    UIView *host = self.navigationController.view ?: self.view.window;
    return host ?: self.view;
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
    CGPoint vp = [g locationInView:[self dragOverlayHost]];
    CGPoint tp = [g locationInView:self.tableView];
    if (g.state == UIGestureRecognizerStateBegan) {
        NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:tp];
        if (!ip) return;
        NSArray *items = [self itemsForSection:ip.section];
        if (ip.row < 0 || ip.row >= (NSInteger)items.count) return;
        id item = items[(NSUInteger)ip.row];
        NSMutableArray *group = [NSMutableArray array];
        if (ptrContains(self.selected, item) && self.selected.count > 1) {
            for (id x in items) if (ptrContains(self.selected, x)) [group addObject:x];
        } else {
            [group addObject:item];
        }
        self.dragGroup = group;
        self.dragSection = ip.section;
        self.dragInsertRow = ip.row;
        self.dragViewPoint = vp;
        self.dragStartViewPoint = vp;
        self.dragMoved = NO;
        [self beginCustomDrag];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.dragViewPoint = vp;
        CGFloat dx = vp.x - self.dragStartViewPoint.x;
        CGFloat dy = vp.y - self.dragStartViewPoint.y;
        if (!self.dragMoved && hypot(dx, dy) > 8) self.dragMoved = YES;
        [self updateCustomDrag];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self endCustomDrag:YES];
    } else if (g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        [self endCustomDrag:NO];
    }
}

- (void)beginCustomDrag {
    self.tableView.panGestureRecognizer.enabled = NO;
    [self setSheetPansEnabled:NO];
    self.dragPreview = [self buildDragPreview];
    if (self.dragPreview) [[self dragOverlayHost] addSubview:self.dragPreview];
    for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
        NSArray *items = [self itemsForSection:ip.section];
        if (ip.row < 0 || ip.row >= (NSInteger)items.count) continue;
        setCellDimmed([self.tableView cellForRowAtIndexPath:ip],
                      ptrContains(self.dragGroup, items[(NSUInteger)ip.row]));
    }
    self.dropIndicator = [[UIView alloc] initWithFrame:CGRectZero];
    self.dropIndicator.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.85];
    self.dropIndicator.layer.cornerRadius = 1;
    self.dropIndicator.hidden = YES;
    self.dropIndicator.userInteractionEnabled = NO;
    [self.tableView addSubview:self.dropIndicator];

    [self updateCustomDrag];

    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [h impactOccurred];
    self.dragScrollLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(dragScrollTick)];
    [self.dragScrollLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (UIView *)buildDragPreview {
    NSArray *sectionItems = [self itemsForSection:self.dragSection];
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    CGSize cellSize = CGSizeMake(300, 62);
    for (id x in self.dragGroup) {
        NSUInteger r = [sectionItems indexOfObjectIdenticalTo:x];
        if (r == NSNotFound) continue;
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:
            [NSIndexPath indexPathForRow:(NSInteger)r inSection:self.dragSection]];
        if (!c) continue;
        cellSize = c.bounds.size;
        BOOL wasHighlighted = c.highlighted;
        c.highlighted = NO;
        UIImage *img = renderCellImage(c);
        c.highlighted = wasHighlighted;
        if (img) [images addObject:img];
    }
    if (!images.count) return nil;
    NSUInteger layers = MIN(images.count, (NSUInteger)3);
    CGFloat off = 7;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        cellSize.width + off * (layers - 1), cellSize.height + off * (layers - 1))];
    box.backgroundColor = UIColor.clearColor;
    box.userInteractionEnabled = NO;
    box.transform = CGAffineTransformMakeScale(0.86, 0.86);
    box.layer.shadowColor = UIColor.blackColor.CGColor;
    box.layer.shadowOpacity = 0.22;
    box.layer.shadowRadius = 6;
    box.layer.shadowOffset = CGSizeMake(0, 3);
    for (NSUInteger i = 0; i < layers; i++) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:images[i]];
        iv.frame = CGRectMake(off * i, off * i, cellSize.width, cellSize.height);
        iv.layer.cornerRadius = 12;
        iv.clipsToBounds = YES;
        iv.layer.borderWidth = 0.5;
        iv.layer.borderColor = UIColor.separatorColor.CGColor;
        [box addSubview:iv];
    }
    if (self.dragGroup.count > 1) {
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(box.bounds.size.width - 30, -10, 30, 30)];
        badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.dragGroup.count];
        badge.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        badge.textColor = UIColor.whiteColor;
        badge.backgroundColor = UIColor.systemBlueColor;
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 15;
        badge.clipsToBounds = YES;
        [box addSubview:badge];
    }
    return box;
}

- (void)updateCustomDrag {
    if (self.dragGroup.count == 0) return;
    UIView *host = [self dragOverlayHost];
    CGPoint vp = self.dragViewPoint;
    if (self.dragPreview) {
        CGFloat scale = 0.86;
        CGFloat halfW = self.dragPreview.bounds.size.width * scale / 2;
        CGFloat halfH = self.dragPreview.bounds.size.height * scale / 2;
        CGFloat x = MIN(MAX(vp.x + 8, halfW + 8), host.bounds.size.width - halfW - 8);
        CGFloat top = host.safeAreaInsets.top + halfH + 4;
        CGFloat y = MAX(vp.y - 24, top);
        self.dragPreview.center = CGPointMake(x, y);
    }
    if (self.dragMoved) {
        CGPoint tp = [host convertPoint:vp toView:self.tableView];
        NSInteger row = [self insertionRowForTablePoint:tp];
        if (row != self.dragInsertRow) {
            self.dragInsertRow = row;
            UISelectionFeedbackGenerator *sf = [[UISelectionFeedbackGenerator alloc] init];
            [sf selectionChanged];
        }
    }
    [self updateDropIndicator];
}

- (NSInteger)insertionRowForTablePoint:(CGPoint)p {
    NSArray *items = [self itemsForSection:self.dragSection];
    if (!items.count) return 0;
    CGRect first = [self.tableView rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:0 inSection:self.dragSection]];
    CGRect last = [self.tableView rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:(NSInteger)items.count - 1 inSection:self.dragSection]];
    if (p.y <= CGRectGetMinY(first)) return 0;
    if (p.y >= CGRectGetMaxY(last)) return (NSInteger)items.count;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        CGRect r = [self.tableView rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:i inSection:self.dragSection]];
        if (p.y < CGRectGetMaxY(r)) return (p.y > CGRectGetMidY(r)) ? i + 1 : i;
    }
    return (NSInteger)items.count;
}

- (void)updateDropIndicator {
    NSArray *items = [self itemsForSection:self.dragSection];
    if (!self.dragMoved || !items.count || !self.dropIndicator) {
        self.dropIndicator.hidden = YES;
        return;
    }
    CGFloat y;
    if (self.dragInsertRow <= 0) {
        y = CGRectGetMinY([self.tableView rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:0 inSection:self.dragSection]]);
    } else if (self.dragInsertRow >= (NSInteger)items.count) {
        y = CGRectGetMaxY([self.tableView rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:(NSInteger)items.count - 1 inSection:self.dragSection]]);
    } else {
        y = CGRectGetMinY([self.tableView rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:self.dragInsertRow inSection:self.dragSection]]);
    }
    self.dropIndicator.frame = CGRectMake(16, y - 1, self.tableView.bounds.size.width - 32, 2);
    self.dropIndicator.hidden = NO;
    [self.tableView bringSubviewToFront:self.dropIndicator];
}

- (void)dragScrollTick {
    if (self.dragGroup.count == 0) return;
    UIView *host = [self dragOverlayHost];
    CGRect visible = [self.tableView convertRect:self.tableView.bounds toView:host];
    CGFloat yInTable = self.dragViewPoint.y - CGRectGetMinY(visible);
    CGFloat h = visible.size.height;
    CGFloat margin = 72;
    CGFloat dy = 0;
    if (yInTable < margin) dy = -9;
    else if (yInTable > h - margin) dy = 9;
    if (dy == 0) return;
    CGFloat minY = -self.tableView.adjustedContentInset.top;
    CGFloat maxY = MAX(minY, self.tableView.contentSize.height - h + self.tableView.adjustedContentInset.bottom);
    CGFloat y = MAX(minY, MIN(self.tableView.contentOffset.y + dy, maxY));
    if (fabs(y - self.tableView.contentOffset.y) < 0.5) return;
    self.tableView.contentOffset = CGPointMake(0, y);
    [self updateCustomDrag];
}

- (void)endCustomDrag:(BOOL)commit {
    [self.dragScrollLink invalidate];
    self.dragScrollLink = nil;
    self.tableView.panGestureRecognizer.enabled = YES;
    __weak LNBatchVC *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws setSheetPansEnabled:YES];
    });
    [self.dragPreview removeFromSuperview];
    self.dragPreview = nil;
    [self.dropIndicator removeFromSuperview];
    self.dropIndicator = nil;
    for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
        setCellDimmed([self.tableView cellForRowAtIndexPath:ip], NO);
    }
    self.dragMoved = NO;
    NSArray *group = self.dragGroup;
    NSInteger section = self.dragSection;
    NSInteger insertRow = self.dragInsertRow;
    self.dragGroup = nil;
    if (!commit || group.count == 0) return;
    NSArray *old = [self itemsForSection:section];
    if (!old.count) return;
    NSMutableArray *rest = [NSMutableArray array];
    NSInteger insertIndex = 0;
    for (NSInteger i = 0; i < (NSInteger)old.count; i++) {
        id x = old[(NSUInteger)i];
        if (ptrContains(group, x)) continue;
        if (i < insertRow) insertIndex++;
        [rest addObject:x];
    }
    if (insertIndex > (NSInteger)rest.count) insertIndex = (NSInteger)rest.count;
    [rest insertObjects:group atIndexes:[NSIndexSet indexSetWithIndexesInRange:
        NSMakeRange((NSUInteger)insertIndex, group.count)]];
    if (samePtrOrder(old, rest)) return;
    [self applyReorder:rest inSection:section];
}

- (void)applyReorder:(NSArray *)items inSection:(NSInteger)section {
    LNDCConfigModel *config = configForHost(self.host);
    if (!config) return;
    NSString *kind = (section >= 0 && section < (NSInteger)self.sections.count)
        ? self.sections[(NSUInteger)section][@"kind"] : nil;
    if ([kind isEqualToString:@"plugins"]) {
        config.plugins = items;
    } else if ([kind isEqualToString:@"localRules"]) {
        config.localRule = items;
    } else if ([kind isEqualToString:@"remoteRules"]) {
        config.remoteRules = items;
    } else if ([kind isEqualToString:@"localNodes"]) {
        config.proxys = items;
    } else if ([kind isEqualToString:@"remoteProxies"]) {
        config.remoteProxys = items;
    }
    [self commitLight];
}

#pragma mark 操作菜单

- (UIMenu *)buildActionMenu {
    BOOL has = self.selected.count > 0;
    BOOL toggleable = NO, anyEnabled = NO, anyDisabled = NO;
    for (id item in self.selected) {
        if (!itemCanToggle(item)) continue;
        toggleable = YES;
        if (itemEnabled(item)) anyEnabled = YES;
        else anyDisabled = YES;
    }

    NSString *copyTitle = @"复制链接";
    if (self.mode == LNBLModeRules) copyTitle = @"复制选中内容";
    else if (self.mode == LNBLModeNodes) copyTitle = @"复制节点";

    __weak LNBatchVC *ws = self;
    UIAction *copy = [UIAction actionWithTitle:copyTitle image:[UIImage systemImageNamed:@"doc.on.doc"]
                                     identifier:nil handler:^(UIAction *a) { [ws copySelected]; }];
    UIAction *enable = [UIAction actionWithTitle:@"启用" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                      identifier:nil handler:^(UIAction *a) { [ws setSelectedEnabled:YES]; }];
    UIAction *disable = [UIAction actionWithTitle:@"禁用" image:[UIImage systemImageNamed:@"xmark.circle"]
                                       identifier:nil handler:^(UIAction *a) { [ws setSelectedEnabled:NO]; }];
    UIAction *del = [UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"]
                                   identifier:nil handler:^(UIAction *a) { [ws deleteTapped]; }];
    del.attributes = UIMenuElementAttributesDestructive;

    if (!has) {
        copy.attributes = UIMenuElementAttributesDisabled;
        del.attributes |= UIMenuElementAttributesDisabled;
    }
    if (!toggleable || !anyDisabled) enable.attributes = UIMenuElementAttributesDisabled;
    if (!toggleable || !anyEnabled) disable.attributes = UIMenuElementAttributesDisabled;
    return [UIMenu menuWithTitle:@"" children:@[copy, enable, disable, del]];
}

- (void)copySelected {
    NSMutableArray *lines = [NSMutableArray array];
    for (id item in [self.selected copy]) {
        NSString *s = nil;
        if (self.mode == LNBLModePlugins) {
            s = strv(pluginObject(item), @"remoteUrl");
        } else if (self.mode == LNBLModeNodes) {
            if (isRemoteProxy(item)) s = strv(item, @"remoteUrl");
            else {
                s = strv(item, @"playload");
                if (!s.length) s = msg0(item, @"generateLoonFormat");
            }
        } else {
            id inner = msg0(item, @"remoteRule") ?: msg0(item, @"rule");
            if ([item isKindOfClass:NSClassFromString(@"RemoteRule")] || [inner isKindOfClass:NSClassFromString(@"RemoteRule")]) {
                s = strv([inner isKindOfClass:NSClassFromString(@"RemoteRule")] ? inner : item, @"remoteUrl");
            } else {
                s = strv(inner ?: item, @"playload");
            }
        }
        if (s.length) [lines addObject:s];
    }
    if (!lines.count) {
        [self showToast:@"没有可复制的内容"];
        return;
    }
    UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    [self showToast:[NSString stringWithFormat:@"已复制 %lu 项", (unsigned long)lines.count]];
}

- (void)setSelectedEnabled:(BOOL)enable {
    NSInteger changed = 0;
    for (id item in [self.selected copy]) {
        if (itemSetEnabled(item, enable)) changed++;
    }
    if (!changed) {
        [self showToast:@"选中的项目不支持启用/禁用"];
        return;
    }
    if (self.mode == LNBLModePlugins) [self commitLight];
    else [self commitChange];
    [self showToast:[NSString stringWithFormat:@"%@ %ld 项", enable ? @"已启用" : @"已禁用", (long)changed]];
}

- (void)commitChange {
    LNDCConfigModel *config = configForHost(self.host);
    @try {
        [config saveConfigPlayload];
    } @catch (NSException *e) {
        LBL(@"保存异常 %@", e);
    }
    msgv(dataManager(), @"postChangeNoti");
    [self refreshHost];
    [self reloadData];
}

- (void)commitLight {
    LNDCConfigModel *config = configForHost(self.host);
    @try {
        [config saveConfigPlayload];
    } @catch (NSException *e) {
        LBL(@"保存顺序异常 %@", e);
    }
    UIViewController *vc = self.host;
    if (vc) {
        @try {
            if ([vc respondsToSelector:NSSelectorFromString(@"setPlugins:")]) {
                [vc setValue:(config.plugins ?: @[]) forKey:@"plugins"];
            }
        } @catch (NSException *e) {}
        [self reloadHostListsOnly];
    }
    [self reloadData];
}

- (void)reloadHostListsOnly {
    UIViewController *vc = self.host;
    if (!vc) return;
    @try {
        id list = msg0(vc, @"listView");
        if ([list respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(list, @"reloadData");
        id icon = msg0(vc, @"iconView");
        if ([icon respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(icon, @"reloadData");
        for (NSString *key in @[@"collectionView", @"tableView"]) {
            id v = nil;
            @try { v = [vc valueForKey:key]; } @catch (NSException *e) {}
            if ([v respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(v, @"reloadData");
        }
    } @catch (NSException *e) { LBL(@"轻量刷新异常 %@", e); }
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)deleteTapped {
    NSUInteger n = self.selected.count;
    if (!n) return;
    NSString *what = (self.mode == LNBLModePlugins) ? @"插件" : ((self.mode == LNBLModeNodes) ? @"节点" : @"规则");
    NSString *extra;
    if (self.mode == LNBLModePlugins) extra = @"\n相关插件规则也会被移除。";
    else if (self.mode == LNBLModeNodes) extra = @"\n本地节点会从配置删除；订阅只会移除引用，不会删除已下载的节点文件。";
    else extra = @"\n远程规则只会移除引用，不会删除已下载的规则文件。";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"删除 %lu 个%@？", (unsigned long)n, what]
                         message:[NSString stringWithFormat:@"会先备份当前配置。%@", extra]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak LNBatchVC *ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [ws performDelete];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)performDelete {
    LNDCConfigModel *config = configForHost(self.host);
    if (!config) {
        [self showResult:@"未取到当前配置" ok:NO];
        return;
    }
    backupConfig(config);
    BOOL light = (self.mode == LNBLModePlugins);
    NSArray *picked = [self.selected copy];
    NSArray *newLocal = config.localRule ?: @[];
    NSArray *newRemote = config.remoteRules ?: @[];
    NSError *error = nil;
    @try {
        LNRuleArchieveManager *mgr = (LNRuleArchieveManager *)ruleManager();
        if (self.mode == LNBLModePlugins) {
            NSMutableArray *plugins = [NSMutableArray array];
            for (id x in picked) {
                id p = pluginObject(x);
                if (p) [plugins addObject:p];
            }
            config.plugins = arrayByRemovingPtrs(config.plugins, plugins);
            for (id p in plugins) [mgr deletePluginRules:p];
        } else if (self.mode == LNBLModeNodes) {
            NSMutableArray *local = [NSMutableArray array];
            NSMutableArray *remote = [NSMutableArray array];
            for (id x in picked) {
                if (isRemoteProxy(x)) [remote addObject:x];
                else [local addObject:x];
            }
            config.proxys = arrayByRemovingPtrs(config.proxys, local);
            config.remoteProxys = arrayByRemovingPtrs(config.remoteProxys, remote);
            for (id n in local) {
                if ([config respondsToSelector:NSSelectorFromString(@"deleteNode:")]) msg1(config, @"deleteNode:", n);
                else msgv(n, @"deleteProxy");
            }
            for (id r in remote) msg1(config, @"deleteRemoteProxy:", r);
        } else {
            NSMutableArray *local = [NSMutableArray array];
            NSMutableArray *remote = [NSMutableArray array];
            for (id x in picked) {
                if ([x isKindOfClass:NSClassFromString(@"RemoteRule")]) [remote addObject:x];
                else if ([x isKindOfClass:NSClassFromString(@"Rule")]) [local addObject:x];
                else {
                    id rr = msg0(x, @"remoteRule");
                    id r = msg0(x, @"rule");
                    if (rr) [remote addObject:rr];
                    else if (r) [local addObject:r];
                }
            }
            newLocal = arrayByRemovingPtrs(newLocal, local);
            newRemote = arrayByRemovingPtrs(newRemote, remote);
            config.localRule = newLocal;
            config.remoteRules = newRemote;
            for (id r in local) [mgr deleteLocalRule:r];
            for (id r in remote) [mgr deleteRemoteRule:r];
        }
        [config saveConfigPlayload];
        if (!light) msgv(dataManager(), @"postChangeNoti");
    } @catch (NSException *e) {
        error = [NSError errorWithDomain:@"LoonBatch" code:1 userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}];
        LBL(@"删除异常 %@", e);
    }
    if (light) [self reloadHostListsOnly];
    else [self refreshHost];
    LBL(@"已删除 %lu 项 mode=%ld error=%@", (unsigned long)picked.count, (long)self.mode, error);
    [self showResult:(error ? [NSString stringWithFormat:@"部分操作失败：%@", error.localizedDescription] : @"已删除")
                 ok:(error == nil)];
}

- (void)refreshHost {
    UIViewController *vc = self.host;
    if (!vc) return;
    LNDCConfigModel *cfg = configForHost(vc);
    NSArray *local = cfg.localRule ?: @[];
    NSArray *remote = cfg.remoteRules ?: @[];
    @try {
        if ([vc respondsToSelector:NSSelectorFromString(@"setRules:")]) [vc setValue:local forKey:@"rules"];
        if ([vc respondsToSelector:NSSelectorFromString(@"setRemoteAllRules:")]) [vc setValue:remote forKey:@"remoteAllRules"];
        if ([vc respondsToSelector:NSSelectorFromString(@"setAllRemoteRules:")]) [vc setValue:remote forKey:@"allRemoteRules"];
        if ([vc respondsToSelector:NSSelectorFromString(@"refreshPlugins")]) msgv(vc, @"refreshPlugins");
        else if ([vc respondsToSelector:NSSelectorFromString(@"initData")]) msgv(vc, @"initData");
        id list = msg0(vc, @"listView");
        if ([list respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(list, @"reloadData");
        id col = msg0(vc, @"iconView");
        if ([col respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(col, @"reloadData");
        if ([vc respondsToSelector:NSSelectorFromString(@"tableView")]) {
            id tv = msg0(vc, @"tableView");
            if ([tv respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(tv, @"reloadData");
        }
    } @catch (NSException *e) { LBL(@"刷新异常 %@", e); }
}

- (void)showToast:(NSString *)text {
    if (!self.toastLabel) {
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.78];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 14;
        l.clipsToBounds = YES;
        l.alpha = 0;
        l.userInteractionEnabled = NO;
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [l.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
            [l.heightAnchor constraintEqualToConstant:36],
            [l.widthAnchor constraintGreaterThanOrEqualToConstant:100],
        ]];
        self.toastLabel = l;
    }
    self.toastLabel.text = [NSString stringWithFormat:@"  %@  ", text];
    self.toastLabel.alpha = 1;
    [self.view bringSubviewToFront:self.toastLabel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:1.4];
}

- (void)hideToast {
    [UIView animateWithDuration:0.25 animations:^{ self.toastLabel.alpha = 0; }];
}

- (void)showResult:(NSString *)msg ok:(BOOL)ok {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(ok ? @"完成" : @"失败")
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (ok) [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

#pragma mark - 入口按钮

static const NSInteger kLoonBatchButtonTag = 0x4C42;
static char kLBModeKey;

@interface LNBLShared : NSObject
+ (instancetype)shared;
- (void)installOn:(UIViewController *)vc;
- (void)openBatch:(UIButton *)sender;
@end

@implementation LNBLShared

+ (instancetype)shared {
    static LNBLShared *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LNBLShared new]; });
    return s;
}

- (LNBLMode)modeForClass:(NSString *)cn {
    if ([cn isEqualToString:@"PolicyGroupSelectVC"]) return LNBLModeNodes;
    if ([cn containsString:@"PluginList"]) return LNBLModePlugins;
    if ([cn containsString:@"AllRulesVC"]) return LNBLModeRules;
    return 0;
}

- (void)installOn:(UIViewController *)vc {
    if (!vc || [vc isKindOfClass:NSClassFromString(@"LNBatchVC")]) return;
    NSString *cn = NSStringFromClass([vc class]);
    LNBLMode mode = [self modeForClass:cn];
    if (!mode) return;
    for (UIView *v in vc.view.subviews) if (v.tag == kLoonBatchButtonTag) return;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = kLoonBatchButtonTag;
    b.frame = CGRectMake(0, 0, 64, 36);
    [b setTitle:@"批量" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.92];
    b.layer.cornerRadius = 18;
    b.clipsToBounds = YES;
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    objc_setAssociatedObject(b, &kLBModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [b addTarget:self action:@selector(openBatch:) forControlEvents:UIControlEventTouchUpInside];
    UIEdgeInsets ins = vc.view.safeAreaInsets;
    b.frame = CGRectMake(vc.view.bounds.size.width - 64 - 16,
                         vc.view.bounds.size.height - ins.bottom - 36 - 16, 64, 36);
    [vc.view addSubview:b];
    [vc.view bringSubviewToFront:b];
    LBL(@"入口已加 %@ mode=%ld", cn, (long)mode);
}

- (void)openBatch:(UIButton *)sender {
    LNBLMode mode = [objc_getAssociatedObject(sender, &kLBModeKey) integerValue];
    UIViewController *host = nil;
    UIResponder *r = sender;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) { host = (UIViewController *)r; break; }
        r = r.nextResponder;
    }
    if (!host) return;
    LNBatchVC *vc = [[LNBatchVC alloc] initWithMode:mode host:host];
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
    [host presentViewController:nav animated:YES completion:nil];
    LBL(@"打开批量页 mode=%ld host=%@", (long)mode, NSStringFromClass([host class]));
}
@end

// 给具体列表类补 viewDidAppear，防止 Swift 覆盖后不调用 super。
// 基类 hook 负责“继承默认实现”的 VC；具体类只包装它自己的 override，并保留原实现。
static void hookViewDidAppear(Class c) {
    if (!c) return;
    SEL sel = sel_registerName("viewDidAppear:");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    Class super = class_getSuperclass(c);
    Method sm = super ? class_getInstanceMethod(super, sel) : NULL;
    if (m == sm) return;   // 继承来的，基类 hook 已经覆盖
    IMP old = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^(id recv, BOOL animated) {
        ((void (*)(id, SEL, BOOL))old)(recv, sel, animated);
        [[LNBLShared shared] installOn:recv];
    });
    method_setImplementation(m, repl);
}

__attribute__((constructor)) static void init(void) {
    @try {
        LBL(@"=== LoonBatch loaded ===");
        LNDCConfigModel *cfg = currentConfig();
        LBL(@"启动配置 %@ plugins=%lu local=%lu remote=%lu", NSStringFromClass([cfg class]),
            (unsigned long)[cfg.plugins count], (unsigned long)[cfg.localRule count], (unsigned long)[cfg.remoteRules count]);
        Class base = [UIViewController class];
        SEL baseSel = sel_registerName("viewDidAppear:");
        Method m = class_getInstanceMethod(base, baseSel);
        if (m) {
            IMP old = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^(id recv, BOOL animated) {
                ((void (*)(id, SEL, BOOL))old)(recv, baseSel, animated);
                [[LNBLShared shared] installOn:recv];
            });
            method_setImplementation(m, repl);
        }
        hookViewDidAppear(NSClassFromString(@"PluginListVC"));
        hookViewDidAppear(NSClassFromString(@"_TtC4Loon17PluginListSwiftVC"));
        hookViewDidAppear(NSClassFromString(@"AllRulesVC"));
        hookViewDidAppear(NSClassFromString(@"PolicyGroupSelectVC"));
    } @catch (NSException *e) { LBL(@"init 异常 %@", e); }
}
