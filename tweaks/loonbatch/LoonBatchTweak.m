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

static BOOL boolIvar(id obj, const char *name) {
    if (!obj) return NO;
    @try {
        Class cls = object_getClass(obj);
        while (cls) {
            Ivar iv = class_getInstanceVariable(cls, name);
            if (iv) {
                const char *type = ivar_getTypeEncoding(iv);
                if (type && type[0] && type[0] != 'c' && type[0] != 'B' && type[0] != 'b') return NO;
                ptrdiff_t off = ivar_getOffset(iv);
                return *(BOOL *)((char *)(__bridge void *)obj + off);
            }
            cls = class_getSuperclass(cls);
        }
    } @catch (NSException *e) {}
    return NO;
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

static BOOL pluginItemsEqual(id a, id b) {
    if (a == b) return YES;
    id pa = pluginObject(a), pb = pluginObject(b);
    if (pa == pb) return YES;
    NSString *ua = strv(pa, @"remoteUrl") ?: strv(a, @"remoteUrl");
    NSString *ub = strv(pb, @"remoteUrl") ?: strv(b, @"remoteUrl");
    return ua.length && ub.length && [ua isEqualToString:ub];
}

static NSArray *arrayByRemovingPlugins(NSArray *src, NSArray *remove) {
    NSMutableArray *out = [NSMutableArray array];
    for (id x in src ?: @[]) {
        BOOL hit = NO;
        for (id y in remove) {
            if (pluginItemsEqual(x, y)) { hit = YES; break; }
        }
        if (!hit) [out addObject:x];
    }
    return out;
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

static BOOL backupConfig(LNDCConfigModel *config) {
    @try {
        NSString *fileName = strv(config, @"fileName");
        if (!fileName.length) fileName = msg0(dataManager(), @"currentConfigFileName");
        if (!fileName.length) { LBL(@"备份失败：没有配置文件名"); return NO; }
        NSURL *group = loonGroupURL();
        if (!group) { LBL(@"备份失败：没有 App Group"); return NO; }
        NSURL *src = [[group URLByAppendingPathComponent:@"config"] URLByAppendingPathComponent:fileName.lastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:src.path]) { LBL(@"备份失败：配置文件不存在"); return NO; }
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LoonBatch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        NSString *dst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@",
            [df stringFromDate:[NSDate date]], fileName.lastPathComponent]];
        NSError *err = nil;
        if ([[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err]) {
            LBL(@"已备份配置 %@", dst);
            return YES;
        }
        LBL(@"备份失败 %@", err);
    } @catch (NSException *e) { LBL(@"备份异常 %@", e); }
    return NO;
}

static NSString *configFilePath(LNDCConfigModel *config) {
    @try {
        NSString *fileName = strv(config, @"fileName");
        if (!fileName.length) fileName = msg0(dataManager(), @"currentConfigFileName");
        NSURL *group = loonGroupURL();
        if (!fileName.length || !group) return nil;
        return [[[group URLByAppendingPathComponent:@"config"]
                 URLByAppendingPathComponent:fileName.lastPathComponent] path];
    } @catch (NSException *e) { return nil; }
}

// saveConfigPlayload 在插件数组缩短时会把首项重复写回；保存后按链接清理 [Plugin] 段。
static NSUInteger gPluginRepairGeneration;
static BOOL repairPluginSection(NSString *path, NSSet *removedURLs, NSInteger *changedOut) {
    if (changedOut) *changedOut = 0;
    if (!path.length) return NO;
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!text) { LBL(@"读取配置失败 %@", err); return NO; }
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    BOOL inPlugin = NO;
    NSInteger changed = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *t = trimmed(line);
        if (t.length >= 2 && [t hasPrefix:@"["] && [t hasSuffix:@"]"]) {
            inPlugin = [t caseInsensitiveCompare:@"[Plugin]"] == NSOrderedSame;
            [out addObject:line];
            continue;
        }
        if (inPlugin && t.length) {
            NSString *url = trimmed([[t componentsSeparatedByString:@","] firstObject]);
            if (url.length && [removedURLs containsObject:url]) { changed++; continue; }
            if (url.length && [seen containsObject:t]) { changed++; continue; }
            if (url.length) [seen addObject:t];
        }
        [out addObject:line];
    }
    if (changed) {
        NSString *fixed = [out componentsJoinedByString:@"\n"];
        if ([fixed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
            LBL(@"已修复插件配置 %ld 行", (long)changed);
            if (changedOut) *changedOut = changed;
            return YES;
        }
        LBL(@"修复插件配置失败 %@", err);
        return NO;
    }
    return YES;
}

static void dropStringKeys(id object, NSString *getter, NSString *setter, NSSet *urls) {
    if (!object || !urls.count) return;
    @try {
        id dict = msg0(object, getter);
        if (![dict isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *m = [dict mutableCopy];
        for (id key in [m allKeys])
            if ([key isKindOfClass:[NSString class]] && [urls containsObject:key]) [m removeObjectForKey:key];
        if (m.count != [dict count] && [object respondsToSelector:NSSelectorFromString(setter)])
            [object setValue:m forKey:getter];
    } @catch (NSException *e) {}
}

static void dropDeletedPluginCache(LNDCConfigModel *config, NSSet *urls) {
    dropStringKeys(config, @"allPluginNames", @"setAllPluginNames:", urls);
    dropStringKeys(config, @"pluginPolicys", @"setPluginPolicys:", urls);
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
@property (nonatomic, strong) UILongPressGestureRecognizer *selectPress;
@property (nonatomic, strong) NSIndexPath *selectAnchor;
@property (nonatomic, strong) NSIndexPath *selectTarget;
@property (nonatomic, assign) BOOL selectDragging;
@property (nonatomic, assign) BOOL selectMoved;
@property (nonatomic, assign) BOOL selectWant;
@property (nonatomic, strong) NSMutableArray *selectBase;
@property (nonatomic, assign) CGPoint selectStartWindowPoint;
@property (nonatomic, assign) CGPoint selectLastWindowPoint;
@property (nonatomic, assign) CGFloat selectScrollDelta;
@property (nonatomic, strong) NSTimer *selectScrollTimer;
@property (nonatomic, strong) NSMutableArray *disabledSheetPans;
@property (nonatomic, copy) void (^onClose)(void);
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
    lp.numberOfTouchesRequired = 1;
    lp.cancelsTouchesInView = YES;
    lp.delegate = self;
    [self.tableView addGestureRecognizer:lp];

    self.selectPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSelectPress:)];
    self.selectPress.numberOfTouchesRequired = 2;
    self.selectPress.minimumPressDuration = 0.0;
    self.selectPress.allowableMovement = CGFLOAT_MAX;
    self.selectPress.cancelsTouchesInView = YES;
    self.selectPress.delegate = self;
    [self.tableView addGestureRecognizer:self.selectPress];
    self.tableView.panGestureRecognizer.maximumNumberOfTouches = 1;
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
    if (self.selectDragging) [self endSelectDrag];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [self setSheetPansEnabled:YES];
        [self.navigationController setToolbarHidden:YES animated:NO];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if ((self.isBeingDismissed || self.navigationController.isBeingDismissed) && self.onClose) self.onClose();
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
    if (self.selectDragging) [self endSelectDrag];
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
    NSArray *oldSelected = [self.selected copy];
    NSMutableSet *selectedKeys = [NSMutableSet set];
    for (id x in oldSelected) {
        NSString *k = [self stableKeyForItem:x];
        if (k.length) [selectedKeys addObject:k];
    }
    NSMutableArray *still = [NSMutableArray array];
    for (id x in [self allItems]) {
        NSString *k = [self stableKeyForItem:x];
        if (ptrContains(oldSelected, x) || (k.length && [selectedKeys containsObject:k])) [still addObject:x];
    }
    self.selected = still;
    NSUInteger total = [[self allItems] count];
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
- (id)itemAtPath:(NSIndexPath *)ip {
    if (!ip || ip.section < 0 || ip.section >= (NSInteger)self.sections.count) return nil;
    NSArray *items = [self itemsForSection:ip.section];
    if (ip.row < 0 || ip.row >= (NSInteger)items.count) return nil;
    return items[(NSUInteger)ip.row];
}

- (NSString *)stableKeyForItem:(id)item {
    if (!item) return nil;
    if (self.mode == LNBLModePlugins) {
        id p = pluginObject(item);
        NSString *u = strv(p, @"remoteUrl") ?: strv(item, @"remoteUrl");
        return u.length ? [@"p:" stringByAppendingString:u] : [@"p:" stringByAppendingString:pluginTitle(item)];
    }
    if (self.mode == LNBLModeNodes) {
        NSString *u = strv(item, @"remoteUrl");
        if (u.length) return [@"rn:" stringByAppendingString:u];
        return [NSString stringWithFormat:@"ln:%@|%@:%ld", nodeTitle(item),
                strv(item, @"serverAddress") ?: @"", (long)intv(item, @"serverPort")];
    }
    id inner = msg0(item, @"remoteRule") ?: msg0(item, @"rule") ?: item;
    if ([inner isKindOfClass:NSClassFromString(@"RemoteRule")]) {
        NSString *u = strv(inner, @"remoteUrl");
        return u.length ? [@"rr:" stringByAppendingString:u] : [@"rr:" stringByAppendingString:remoteRuleTitle(inner)];
    }
    NSString *p = strv(inner, @"playload");
    return p.length ? [@"lr:" stringByAppendingString:p] : [@"lr:" stringByAppendingString:ruleTitle(inner)];
}

- (NSInteger)linearIndexOf:(NSIndexPath *)ip {
    if (!ip) return -1;
    NSInteger n = 0;
    for (NSInteger s = 0; s < ip.section && s < (NSInteger)self.sections.count; s++)
        n += (NSInteger)[self itemsForSection:s].count + 1000;
    return n + ip.row;
}

- (NSIndexPath *)indexPathForLinear:(NSInteger)lin {
    NSInteger n = 0;
    for (NSInteger s = 0; s < (NSInteger)self.sections.count; s++) {
        NSInteger cnt = (NSInteger)[self itemsForSection:s].count;
        if (lin >= n && lin < n + cnt) return [NSIndexPath indexPathForRow:(lin - n) inSection:s];
        n += cnt + 1000;
    }
    return nil;
}

- (NSInteger)nextLinearFrom:(NSInteger)lin {
    NSIndexPath *p = [self indexPathForLinear:lin];
    if (!p) return -1;
    NSInteger cnt = (NSInteger)[self itemsForSection:p.section].count;
    if (p.row + 1 < cnt) return lin + 1;
    NSInteger next = lin + (cnt - p.row) + 1000;
    return [self indexPathForLinear:next] ? next : -1;
}

- (void)refreshSelectedRows:(NSArray *)paths {
    for (NSIndexPath *p in paths) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:p];
        id item = [self itemAtPath:p];
        if (!cell || !item) continue;
        cell.accessoryView = [self statusAccessoryForItem:item selected:ptrContains(self.selected, item)];
    }
}

- (void)applySelectAt:(NSIndexPath *)ip {
    if (!ip || !self.selectAnchor) return;
    NSInteger a = [self linearIndexOf:self.selectAnchor];
    NSInteger b = [self linearIndexOf:ip];
    if (a < 0 || b < 0) return;
    NSInteger lo = MIN(a, b), hi = MAX(a, b);
    BOOL want = self.selectWant;
    NSMutableArray *touched = [NSMutableArray array];
    for (NSInteger lin = 0; lin >= 0; lin = [self nextLinearFrom:lin]) {
        NSIndexPath *p = [self indexPathForLinear:lin];
        if (!p) break;
        id item = [self itemAtPath:p];
        if (!item) continue;
        BOOL inRange = (lin >= lo && lin <= hi);
        BOOL base = ptrContains(self.selectBase, item);
        BOOL desired = inRange ? want : base;
        BOOL has = ptrContains(self.selected, item);
        if (desired && !has) [self.selected addObject:item];
        else if (!desired && has) [self.selected removeObject:item];
        else continue;
        [touched addObject:p];
    }
    if (touched.count) {
        [self refreshSelectedRows:touched];
        UISelectionFeedbackGenerator *fg = [[UISelectionFeedbackGenerator alloc] init];
        [fg selectionChanged];
        [self updateButtons];
    }
}

- (NSIndexPath *)selectTargetForWindowPoint:(CGPoint)wp {
    CGPoint p = [self.tableView convertPoint:wp fromView:nil];
    NSIndexPath *candidate = [self.tableView indexPathForRowAtPoint:p];
    if (!candidate) return self.selectTarget;
    if (!self.selectTarget || [candidate isEqual:self.selectTarget]) return candidate;
    CGRect row = [self.tableView rectForRowAtIndexPath:candidate];
    CGFloat inset = 8.0;
    if (p.y < CGRectGetMinY(row) + inset || p.y > CGRectGetMaxY(row) - inset) return self.selectTarget;
    return candidate;
}

- (void)selectScrollTick:(NSTimer *)t {
    if (!self.selectDragging || self.selectScrollDelta == 0) return;
    UIEdgeInsets insets = self.tableView.adjustedContentInset;
    CGFloat minY = -insets.top;
    CGFloat maxY = MAX(minY, self.tableView.contentSize.height - self.tableView.bounds.size.height + insets.bottom);
    CGFloat y = self.tableView.contentOffset.y + self.selectScrollDelta;
    y = MAX(minY, MIN(maxY, y));
    if (fabs(y - self.tableView.contentOffset.y) < 0.5) {
        [self.selectScrollTimer invalidate];
        self.selectScrollTimer = nil;
        self.selectScrollDelta = 0;
        return;
    }
    self.tableView.contentOffset = CGPointMake(self.tableView.contentOffset.x, y);
    NSIndexPath *target = [self selectTargetForWindowPoint:self.selectLastWindowPoint];
    if (target && ![target isEqual:self.selectTarget]) {
        self.selectTarget = target;
        [self applySelectAt:target];
    }
}

- (void)updateSelectAutoScroll:(CGPoint)wp {
    self.selectLastWindowPoint = wp;
    CGPoint p = [self.tableView convertPoint:wp fromView:nil];
    UIEdgeInsets insets = self.tableView.adjustedContentInset;
    CGFloat top = self.tableView.contentOffset.y + insets.top;
    CGFloat bottom = self.tableView.contentOffset.y + self.tableView.bounds.size.height - insets.bottom;
    CGFloat edge = 100, step = 22;
    if (p.y < top + edge) self.selectScrollDelta = -step;
    else if (p.y > bottom - edge) self.selectScrollDelta = step;
    else self.selectScrollDelta = 0;
    if (self.selectScrollDelta != 0) {
        if (!self.selectScrollTimer)
            self.selectScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.02 target:self
                                                                      selector:@selector(selectScrollTick:)
                                                                      userInfo:nil repeats:YES];
    } else {
        [self.selectScrollTimer invalidate];
        self.selectScrollTimer = nil;
    }
}

- (NSIndexPath *)selectIndexPathForGesture:(UIGestureRecognizer *)g {
    for (NSUInteger i = 0; i < g.numberOfTouches; i++) {
        NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:[g locationOfTouch:i inView:self.tableView]];
        if (ip) return ip;
    }
    return nil;
}

- (void)endSelectDrag {
    [self.selectScrollTimer invalidate];
    self.selectScrollTimer = nil;
    self.selectScrollDelta = 0;
    self.selectDragging = NO;
    self.selectAnchor = nil;
    self.selectTarget = nil;
    self.selectBase = nil;
    self.selectMoved = NO;
    self.tableView.scrollEnabled = YES;
    self.tableView.panGestureRecognizer.enabled = YES;
    [self restoreSheetPansSoon];
}

- (void)handleSelectPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        NSIndexPath *ip = [self selectIndexPathForGesture:g];
        if (!ip) return;
        id item = [self itemAtPath:ip];
        if (!item) return;
        [self setSheetPansEnabled:NO];
        self.selectDragging = YES;
        self.tableView.scrollEnabled = NO;
        self.tableView.panGestureRecognizer.enabled = NO;
        self.selectAnchor = ip;
        self.selectTarget = ip;
        CGPoint wp = [g locationInView:nil];
        self.selectStartWindowPoint = wp;
        self.selectLastWindowPoint = wp;
        self.selectMoved = NO;
        self.selectWant = !ptrContains(self.selected, item);
        self.selectBase = [NSMutableArray arrayWithArray:self.selected];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (!self.selectDragging) return;
        CGPoint wp = [g locationInView:nil];
        if (!self.selectMoved) {
            CGFloat dx = wp.x - self.selectStartWindowPoint.x;
            CGFloat dy = wp.y - self.selectStartWindowPoint.y;
            if (dx * dx + dy * dy < 36.0) return;
            self.selectMoved = YES;
        }
        NSIndexPath *target = [self selectTargetForWindowPoint:wp];
        if (target) {
            self.selectTarget = target;
            [self applySelectAt:target];
        }
        [self updateSelectAutoScroll:wp];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self endSelectDrag];
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sections[s][@"title"];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if ([self itemsForSection:s].count < 2) return nil;
    return @"长按拖动可排序；勾选多行后拖动会整组移动";
}

- (UIView *)statusAccessoryForItem:(id)item selected:(BOOL)selected {
    id t = pluginObject(item);
    BOOL hasStatus = itemCanToggle(item)
        || [t respondsToSelector:NSSelectorFromString(@"enable")]
        || [t respondsToSelector:NSSelectorFromString(@"enabled")];
    BOOL enabled = hasStatus ? itemEnabled(item) : NO;
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
    c.textLabel.numberOfLines = 1;
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    c.detailTextLabel.numberOfLines = 1;
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
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
    if (gestureRecognizer == self.selectPress || otherGestureRecognizer == self.selectPress) return NO;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.selectPress) return [self selectIndexPathForGesture:g] != nil;
    return YES;
}


- (UIView *)dragOverlayHost {
    UIView *host = self.navigationController.view ?: self.view.window;
    return host ?: self.view;
}

- (void)setSheetPansEnabled:(BOOL)enabled {
    if (!enabled) {
        if (self.disabledSheetPans) return;
        self.disabledSheetPans = [NSMutableArray array];
        UIView *v = self.navigationController.view;
        while (v) {
            for (UIGestureRecognizer *g in v.gestureRecognizers) {
                if ([g isKindOfClass:[UIPanGestureRecognizer class]] && g.enabled) {
                    g.enabled = NO;
                    [self.disabledSheetPans addObject:g];
                }
            }
            v = v.superview;
        }
    } else {
        for (UIGestureRecognizer *g in self.disabledSheetPans) g.enabled = YES;
        self.disabledSheetPans = nil;
    }
}

- (void)restoreSheetPansSoon {
    __weak LNBatchVC *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!ws || ws.selectDragging || ws.dragGroup.count) return;
        [ws setSheetPansEnabled:YES];
    });
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
    if (self.dragGroup.count == 0 || !self.dragMoved) return;
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
    [self restoreSheetPansSoon];
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
        LBL(@"保存异常 %@", e);
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

- (void)refreshPluginHostLight {
    UIViewController *vc = self.host;
    if (!vc) return;
    if ([vc respondsToSelector:NSSelectorFromString(@"configHasChanged")]) msgv(vc, @"configHasChanged");
    [self reloadHostListsOnly];
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
    if (!backupConfig(config)) {
        [self showResult:@"备份失败，已取消删除" ok:NO];
        return;
    }
    BOOL light = (self.mode == LNBLModePlugins);
    NSArray *picked = [self.selected copy];
    NSArray *origPlugins = config.plugins ?: @[];
    NSArray *origLocal = config.localRule ?: @[];
    NSArray *origRemote = config.remoteRules ?: @[];
    NSArray *origProxys = config.proxys ?: @[];
    NSArray *origRemoteProxys = config.remoteProxys ?: @[];
    NSArray *newLocal = origLocal;
    NSArray *newRemote = origRemote;
    NSArray *pluginSurvivors = nil;
    NSMutableSet *removedPluginURLs = [NSMutableSet set];
    NSUInteger repairGen = light ? ++gPluginRepairGeneration : 0;
    NSError *error = nil;
    @try {
        LNRuleArchieveManager *mgr = (LNRuleArchieveManager *)ruleManager();
        if (self.mode == LNBLModePlugins) {
            for (id x in picked) {
                id p = pluginObject(x);
                NSString *url = strv(p, @"remoteUrl") ?: strv(x, @"remoteUrl");
                if (!url.length) {
                    NSString *line = msg0(p, @"generatePlayload");
                    NSString *first = [[line componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
                    url = trimmed([[first ?: @"" componentsSeparatedByString:@","] firstObject]);
                }
                if (url.length) [removedPluginURLs addObject:url];
                if (p) [mgr deletePluginRules:p];
            }
            pluginSurvivors = arrayByRemovingPlugins(origPlugins, picked);
            config.plugins = pluginSurvivors;
        } else if (self.mode == LNBLModeNodes) {
            NSMutableArray *local = [NSMutableArray array];
            NSMutableArray *remote = [NSMutableArray array];
            for (id x in picked) {
                if (isRemoteProxy(x)) [remote addObject:x];
                else [local addObject:x];
            }
            config.proxys = arrayByRemovingPtrs(origProxys, local);
            config.remoteProxys = arrayByRemovingPtrs(origRemoteProxys, remote);
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
            newLocal = arrayByRemovingPtrs(origLocal, local);
            newRemote = arrayByRemovingPtrs(origRemote, remote);
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

    if (error) {
        // 保存失败时把内存模型恢复到删除前，失败项继续留在列表。
        @try {
            config.plugins = origPlugins;
            config.localRule = origLocal;
            config.remoteRules = origRemote;
            config.proxys = origProxys;
            config.remoteProxys = origRemoteProxys;
        } @catch (NSException *e) { LBL(@"回滚异常 %@", e); }
    }

    NSString *warning = nil;
    if (!error && light && pluginSurvivors) {
        config.plugins = pluginSurvivors;
        dropDeletedPluginCache(config, removedPluginURLs);
        NSString *path = configFilePath(config);
        NSInteger repaired = 0;
        if (!repairPluginSection(path, removedPluginURLs, &repaired))
            warning = @"已删除，但配置修复失败，请检查插件列表";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (repairGen == gPluginRepairGeneration)
                repairPluginSection(path, removedPluginURLs, NULL);
        });
    }
    if (light) [self refreshPluginHostLight];
    else [self refreshHost];
    [self reloadData];
    LBL(@"已删除 %lu 项 mode=%ld error=%@", (unsigned long)picked.count, (long)self.mode, error);
    if (error) [self showResult:[NSString stringWithFormat:@"删除失败：%@", error.localizedDescription] ok:NO];
    else if (warning) [self showResult:warning ok:NO];
    else [self showResult:@"已删除" ok:YES];
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
    if (!self.view.window) return;
    if (ok) {
        [self showToast:msg];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"失败"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

#pragma mark - 入口按钮

static const NSInteger kLoonBatchButtonTag = 0x4C42;
static char kLBModeKey;

static BOOL gLNFabCustomPosition;
static CGPoint gLNFabCustomCenter;
static BOOL gLNFabDidDrag;

static UITabBar *LNFabVisibleTabBar(UIView *root, int depth) {
    if (!root || root.hidden || root.alpha < 0.05 || depth > 12) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return (UITabBar *)root;
    for (UIView *sub in root.subviews) {
        UITabBar *bar = LNFabVisibleTabBar(sub, depth + 1);
        if (bar) return bar;
    }
    return nil;
}

static CGFloat LNFabBottomY(UIView *root) {
    CGFloat bottomY = root.bounds.size.height - root.safeAreaInsets.bottom;
    UITabBar *tab = root.window ? LNFabVisibleTabBar(root.window, 0) : nil;
    if (tab) {
        CGRect r = [tab convertRect:tab.bounds toView:root];
        if (r.size.height > 1 && CGRectGetMinY(r) < bottomY) bottomY = CGRectGetMinY(r);
    }
    return bottomY;
}

static CGPoint LNFabClampCenter(CGPoint center, UIView *root, CGSize size) {
    CGFloat minX = root.safeAreaInsets.left + size.width / 2.0 + 8.0;
    CGFloat maxX = root.bounds.size.width - root.safeAreaInsets.right - size.width / 2.0 - 8.0;
    CGFloat minY = root.safeAreaInsets.top + size.height / 2.0 + 8.0;
    CGFloat maxY = LNFabBottomY(root) - size.height / 2.0 - 8.0;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    return CGPointMake(MIN(MAX(center.x, minX), maxX), MIN(MAX(center.y, minY), maxY));
}

static UIImage *LNFabBackground(CGSize size) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat radius = size.height / 2.0;
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                                            cornerRadius:radius];
        [clip addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {0.04, 0.52, 1.00, 1.0, 0.37, 0.36, 0.90, 1.0};
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);
        CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        [[UIColor colorWithWhite:1.0 alpha:0.20] setStroke];
        UIBezierPath *border = [UIBezierPath bezierPathWithRoundedRect:
            CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5)
                                                              cornerRadius:radius - 0.5];
        border.lineWidth = 1.0;
        [border stroke];
    }];
}

@interface LNFabDrag : NSObject
@property (nonatomic, assign) CGPoint startCenter;
@end

@implementation LNFabDrag
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *root = v.superview;
    if (!v || !root) return;
    CGPoint t = [g translationInView:root];
    if (g.state == UIGestureRecognizerStateBegan) {
        gLNFabDidDrag = YES;
        self.startCenter = v.center;
        [v.layer removeAllAnimations];
        v.transform = CGAffineTransformMakeScale(1.04, 1.04);
        v.layer.shadowOpacity = 0.42;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        v.center = LNFabClampCenter(CGPointMake(self.startCenter.x + t.x, self.startCenter.y + t.y), root, v.bounds.size);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        gLNFabCustomPosition = YES;
        gLNFabCustomCenter = v.center;
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             v.transform = CGAffineTransformIdentity;
                             v.layer.shadowOpacity = 0.30;
                         } completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gLNFabDidDrag = NO; });
    }
}
@end

static LNFabDrag *gLNFabDrag;

@interface LNBLShared : NSObject
+ (instancetype)shared;
- (void)installOn:(UIViewController *)vc;
- (void)openBatch:(UIButton *)sender;
- (void)fabTouchDown:(UIButton *)sender;
- (void)fabTouchUp:(UIButton *)sender;
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

- (void)fabTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.10 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.94, 0.94);
    }];
}

- (void)fabTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ sender.transform = CGAffineTransformIdentity; }
                     completion:nil];
}

- (UIButton *)buttonIn:(UIViewController *)vc {
    for (UIView *v in vc.view.subviews)
        if (v.tag == kLoonBatchButtonTag && [v isKindOfClass:[UIButton class]]) return (UIButton *)v;
    return nil;
}

- (void)placeButton:(UIButton *)b on:(UIViewController *)vc {
    if (gLNFabDidDrag) return;
    UIView *root = vc.view;
    CGSize size = b.bounds.size;
    CGPoint fallback = CGPointMake(root.bounds.size.width - size.width / 2.0 - 16.0,
                                   LNFabBottomY(root) - size.height / 2.0 - 16.0);
    CGPoint center = gLNFabCustomPosition ? gLNFabCustomCenter : fallback;
    b.center = LNFabClampCenter(center, root, size);
    b.hidden = vc.presentedViewController != nil;
}

- (void)installOn:(UIViewController *)vc {
    if (!vc || [vc isKindOfClass:NSClassFromString(@"LNBatchVC")]) return;
    NSString *cn = NSStringFromClass([vc class]);
    LNBLMode mode = [self modeForClass:cn];
    if (!mode) return;
    if ([cn isEqualToString:@"PolicyGroupSelectVC"] && boolIvar(vc, "_embeddedInPolicyPager")) return;
    UIButton *b = [self buttonIn:vc];
    if (!b) {
        b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = kLoonBatchButtonTag;
        b.frame = CGRectMake(0, 0, 54, 54);
        b.adjustsImageWhenHighlighted = NO;
        b.showsTouchWhenHighlighted = NO;
        b.tintColor = UIColor.whiteColor;
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"checklist" withConfiguration:cfg];
        if (!icon) icon = [UIImage systemImageNamed:@"checkmark.circle" withConfiguration:cfg];
        [b setImage:icon forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        UIImage *bg = LNFabBackground(b.bounds.size);
        [b setBackgroundImage:bg forState:UIControlStateNormal];
        [b setBackgroundImage:bg forState:UIControlStateHighlighted];
        b.layer.shadowColor = [UIColor colorWithRed:0.05 green:0.35 blue:0.85 alpha:1.0].CGColor;
        b.layer.shadowOpacity = 0.30;
        b.layer.shadowRadius = 12;
        b.layer.shadowOffset = CGSizeMake(0, 6);
        b.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:b.bounds].CGPath;
        b.accessibilityLabel = @"批量管理";
        b.accessibilityHint = @"打开插件、规则或节点批量管理";
        [b addTarget:self action:@selector(fabTouchDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(fabTouchUp:) forControlEvents:
            UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        if (!gLNFabDrag) gLNFabDrag = [LNFabDrag new];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gLNFabDrag action:@selector(pan:)];
        pan.maximumNumberOfTouches = 1;
        [b addGestureRecognizer:pan];
        [b addTarget:self action:@selector(openBatch:) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:b];
        LBL(@"入口已加 %@ mode=%ld", cn, (long)mode);
    }
    objc_setAssociatedObject(b, &kLBModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view bringSubviewToFront:b];
    [self placeButton:b on:vc];
}

- (void)openBatch:(UIButton *)sender {
    if (gLNFabDidDrag) return;
    LNBLMode mode = [objc_getAssociatedObject(sender, &kLBModeKey) integerValue];
    UIViewController *host = nil;
    UIResponder *r = sender;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) { host = (UIViewController *)r; break; }
        r = r.nextResponder;
    }
    if (!host) return;
    LNBatchVC *vc = [[LNBatchVC alloc] initWithMode:mode host:host];
    vc.onClose = ^{ sender.hidden = NO; };
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
    sender.hidden = YES;
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

static void hookViewDidLayoutSubviews(Class c) {
    if (!c) return;
    SEL sel = sel_registerName("viewDidLayoutSubviews");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    Class super = class_getSuperclass(c);
    Method sm = super ? class_getInstanceMethod(super, sel) : NULL;
    if (m == sm) return;
    IMP old = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^(id recv) {
        ((void (*)(id, SEL))old)(recv, sel);
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
        hookViewDidLayoutSubviews(NSClassFromString(@"PluginListVC"));
        hookViewDidLayoutSubviews(NSClassFromString(@"_TtC4Loon17PluginListSwiftVC"));
        hookViewDidLayoutSubviews(NSClassFromString(@"AllRulesVC"));
        hookViewDidLayoutSubviews(NSClassFromString(@"PolicyGroupSelectVC"));
    } @catch (NSException *e) { LBL(@"init 异常 %@", e); }
}
