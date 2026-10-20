//
//  LoonBatchTweak.m — Loon 插件/规则批量管理
//  在每个列表页右下角加「批量」按钮，打开自建多选页，读取当前配置的模型后批量删除。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
static NSString *strv(id o, NSString *s) {
    @try { id v = msg0(o, s); return [v isKindOfClass:[NSString class]] ? v : nil; } @catch (NSException *e) { return nil; }
}
static BOOL boolv(id o, NSString *s) {
    if (!o) return NO;
    SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(o, sel); } @catch (NSException *e) { return NO; }
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

static NSString *pluginTitle(id p) {
    NSString *s = strv(p, @"name");
    if (!s.length) s = strv(p, @"tag");
    if (!s.length) s = strv(p, @"pluginName");
    if (!s.length) s = [strv(p, @"remoteUrl") lastPathComponent];
    return s.length ? s : @"(未命名插件)";
}
static NSString *pluginSubtitle(id p) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *u = strv(p, @"remoteUrl");
    if (u.length) [a addObject:u];
    [a addObject:boolv(p, @"enable") ? @"已启用" : @"已禁用"];
    if (boolv(p, @"pin")) [a addObject:@"已固定"];
    return [a componentsJoinedByString:@" · "];
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
    if (!s.length) s = strv(r, @"tag");
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

static void backupConfig(LNDCConfigModel *config) {
    @try {
        NSString *fileName = strv(config, @"fileName");
        if (!fileName.length) fileName = msg0(dataManager(), @"currentConfigFileName");
        if (!fileName.length) return;
        NSURL *group = [[NSFileManager defaultManager]
            containerURLForSecurityApplicationGroupIdentifier:@"group.com.ruikq.decar"];
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

#pragma mark - 批量页

typedef NS_ENUM(NSInteger, LNBLMode) {
    LNBLModePlugins = 1,
    LNBLModeRules = 2,
    LNBLModeLocalRules = 3,
    LNBLModeRemoteRules = 4,
};

@interface LNBatchVC : UITableViewController
@property (nonatomic, assign) LNBLMode mode;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, strong) NSMutableArray *sections;   // @{title, items}
@property (nonatomic, strong) NSMutableArray *selected;   // 指针比较
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *selectAllButton;
@property (nonatomic, strong) UIButton *deleteButton;
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
    self.tableView.rowHeight = 64;
    self.tableView.allowsMultipleSelection = YES;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];
    [self reloadData];
    [self buildBottomBar];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = NO;
}

- (void)buildBottomBar {
    CGFloat h = 54;
    self.bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, h)];
    self.bottomBar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.bottomBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    self.selectAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.selectAllButton.frame = CGRectMake(16, 0, 96, h);
    self.selectAllButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.selectAllButton setTitle:@"全选" forState:UIControlStateNormal];
    self.selectAllButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.selectAllButton addTarget:self action:@selector(toggleSelectAll) forControlEvents:UIControlEventTouchUpInside];

    self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.deleteButton.frame = CGRectMake(self.view.bounds.size.width - 180, 0, 164, h);
    self.deleteButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [self.deleteButton setTitle:@"删除" forState:UIControlStateNormal];
    [self.deleteButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    self.deleteButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.bottomBar addSubview:self.selectAllButton];
    [self.bottomBar addSubview:self.deleteButton];
    [self.view addSubview:self.bottomBar];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, h + 20, 0);
    [self updateButtons];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat h = 54 + self.view.safeAreaInsets.bottom;
    self.bottomBar.frame = CGRectMake(0, self.view.bounds.size.height - h, self.view.bounds.size.width, h);
    self.selectAllButton.frame = CGRectMake(16, 0, 96, 54);
    self.deleteButton.frame = CGRectMake(self.view.bounds.size.width - 180, 0, 164, 54);
    [self.view bringSubviewToFront:self.bottomBar];
}

- (void)reloadData {
    LNDCConfigModel *config = currentConfig();
    self.sections = [NSMutableArray array];
    if (!config) {
        self.title = @"批量";
        [self.tableView reloadData];
        return;
    }
    if (self.mode == LNBLModePlugins) {
        NSArray *items = config.plugins ?: @[];
        self.title = [NSString stringWithFormat:@"批量插件 (%lu)", (unsigned long)items.count];
        [self.sections addObject:@{@"title": @"插件", @"items": items}];
    } else if (self.mode == LNBLModeLocalRules) {
        NSArray *items = config.localRule ?: @[];
        self.title = [NSString stringWithFormat:@"批量本地规则 (%lu)", (unsigned long)items.count];
        [self.sections addObject:@{@"title": @"本地规则", @"items": items}];
    } else if (self.mode == LNBLModeRemoteRules) {
        NSArray *items = config.remoteRules ?: @[];
        self.title = [NSString stringWithFormat:@"批量远程规则 (%lu)", (unsigned long)items.count];
        [self.sections addObject:@{@"title": @"远程规则", @"items": items}];
    } else {
        NSArray *local = config.localRule ?: @[];
        NSArray *remote = config.remoteRules ?: @[];
        self.title = [NSString stringWithFormat:@"批量规则 (%lu)", (unsigned long)(local.count + remote.count)];
        if (local.count) [self.sections addObject:@{@"title": @"本地规则", @"items": local}];
        if (remote.count) [self.sections addObject:@{@"title": @"远程规则", @"items": remote}];
    }
    NSUInteger total = 0;
    for (NSDictionary *sec in self.sections) total += [sec[@"items"] count];
    LBL(@"批量页 mode=%ld config=%@ sections=%lu items=%lu", (long)self.mode,
        NSStringFromClass([config class]), (unsigned long)self.sections.count, (unsigned long)total);
    [self.tableView reloadData];
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

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"cell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    id item = [self itemsForSection:ip.section][ip.row];
    if (self.mode == LNBLModePlugins) {
        c.textLabel.text = pluginTitle(item);
        c.detailTextLabel.text = pluginSubtitle(item);
    } else if ([item isKindOfClass:NSClassFromString(@"RemoteRule")]) {
        c.textLabel.text = remoteRuleTitle(item);
        c.detailTextLabel.text = remoteRuleSubtitle(item);
    } else {
        c.textLabel.text = ruleTitle(item);
        c.detailTextLabel.text = @"";
    }
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = ptrContains(self.selected, item) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
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
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *s in self.sections) [all addObjectsFromArray:s[@"items"]];
    BOOL allSelected = all.count > 0;
    for (id x in all) if (!ptrContains(self.selected, x)) { allSelected = NO; break; }
    if (allSelected) [self.selected removeAllObjects];
    else {
        [self.selected removeAllObjects];
        for (id x in all) [self.selected addObject:x];
    }
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)updateButtons {
    NSUInteger n = self.selected.count;
    [self.deleteButton setTitle:(n ? [NSString stringWithFormat:@"删除 (%lu)", (unsigned long)n] : @"删除")
                       forState:UIControlStateNormal];
    self.deleteButton.enabled = n > 0;
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *s in self.sections) [all addObjectsFromArray:s[@"items"]];
    BOOL allSelected = all.count > 0;
    for (id x in all) if (!ptrContains(self.selected, x)) { allSelected = NO; break; }
    [self.selectAllButton setTitle:(allSelected ? @"全不选" : @"全选") forState:UIControlStateNormal];
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)deleteTapped {
    NSUInteger n = self.selected.count;
    if (!n) return;
    NSString *what = (self.mode == LNBLModePlugins) ? @"插件" : @"规则";
    NSString *extra = (self.mode == LNBLModePlugins)
        ? @"\n相关插件规则也会被移除。"
        : @"\n远程规则只会移除引用，不会删除已下载的规则文件。";
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
    LNDCConfigModel *config = currentConfig();
    if (!config) {
        [self showResult:@"未取到当前配置" ok:NO];
        return;
    }
    backupConfig(config);
    NSArray *picked = [self.selected copy];
    NSArray *newLocal = config.localRule ?: @[];
    NSArray *newRemote = config.remoteRules ?: @[];
    NSError *error = nil;
    @try {
        LNRuleArchieveManager *mgr = (LNRuleArchieveManager *)ruleManager();
        if (self.mode == LNBLModePlugins) {
            NSMutableArray *plugins = [NSMutableArray array];
            for (id x in picked) {
                id p = [x respondsToSelector:NSSelectorFromString(@"plugin")] ? msg0(x, @"plugin") : x;
                if (p) [plugins addObject:p];
            }
            config.plugins = arrayByRemovingPtrs(config.plugins, plugins);
            for (id p in plugins) [mgr deletePluginRules:p];
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
        msgv(dataManager(), @"postChangeNoti");
    } @catch (NSException *e) {
        error = [NSError errorWithDomain:@"LoonBatch" code:1 userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}];
        LBL(@"删除异常 %@", e);
    }
    [self refreshHostWithLocal:newLocal remote:newRemote];
    LBL(@"已删除 %lu 项 mode=%ld error=%@", (unsigned long)picked.count, (long)self.mode, error);
    [self showResult:(error ? [NSString stringWithFormat:@"部分操作失败：%@", error.localizedDescription] : @"已删除")
                 ok:(error == nil)];
}

- (void)refreshHostWithLocal:(NSArray *)local remote:(NSArray *)remote {
    UIViewController *vc = self.host;
    if (!vc) return;
    @try {
        if ([vc respondsToSelector:NSSelectorFromString(@"setRules:")]) [vc setValue:local forKey:@"rules"];
        if ([vc respondsToSelector:NSSelectorFromString(@"setRemoteAllRules:")]) [vc setValue:remote forKey:@"remoteAllRules"];
        if ([vc respondsToSelector:NSSelectorFromString(@"refreshPlugins")]) msgv(vc, @"refreshPlugins");
        else if ([vc respondsToSelector:NSSelectorFromString(@"initData")]) msgv(vc, @"initData");
        id list = msg0(vc, @"listView");
        if ([list respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(list, @"reloadData");
        id col = msg0(vc, @"iconView");
        if ([col respondsToSelector:NSSelectorFromString(@"reloadData")]) msgv(col, @"reloadData");
    } @catch (NSException *e) { LBL(@"刷新异常 %@", e); }
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
    if ([cn containsString:@"PluginList"]) return LNBLModePlugins;
    if ([cn containsString:@"AllRulesVC"]) return LNBLModeRules;
    if ([cn containsString:@"LNLocalRuleListVC"]) return LNBLModeLocalRules;
    if ([cn containsString:@"RemoteRuleListVC"]) return LNBLModeRemoteRules;
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
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
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
        hookViewDidAppear(NSClassFromString(@"LNLocalRuleListVC"));
        hookViewDidAppear(NSClassFromString(@"RemoteRuleListVC"));
    } @catch (NSException *e) { LBL(@"init 异常 %@", e); }
}
