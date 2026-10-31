//
//  TFInstallBypassTweak.m — 注入 installd
//  只处理安装兼容性：最低系统版本、设备家族、设备能力、thinning。
//  默认关闭；存在标记文件时才生效。签名校验交给已有的 AppSync。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kFlag1 = @"/var/mobile/Library/Preferences/com.tomie.tfinstallbypass.enabled";
static NSString *const kFlag2 = @"/rootfs/private/var/mobile/Library/Preferences/com.tomie.tfinstallbypass.enabled";
static NSString *const kLogPath = @"/var/mobile/Library/Logs/TFInstallBypass.log";

static void LOGS(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

static BOOL bypassEnabled(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:kFlag1] || [fm fileExistsAtPath:kFlag2];
}

static NSString *objDesc(id obj) {
    @try { return obj ? [obj description] : @"nil"; } @catch (NSException *e) { return @"<读取失败>"; }
}

static id idSafe(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    Method m = class_getInstanceMethod([obj class], s);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || enc[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, s); } @catch (NSException *e) { return nil; }
}

static IMP oFamily, oCaps, oMinOS, oThinning, oValidate, oValidateMeta, oCurOS, oOSVer, oFamCompat;

static BOOL hFamily(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oFamily)(self, _cmd, err);
    BOOL on = bypassEnabled();
    LOGS(@"[family] %@ id=%@ -> %d bypass=%d", NSStringFromClass([self class]),
         idSafe(self, @"bundleIdentifier") ?: idSafe(self, @"identifier"), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}

static BOOL hCaps(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oCaps)(self, _cmd, err);
    BOOL on = bypassEnabled();
    LOGS(@"[caps] %@ id=%@ -> %d bypass=%d", NSStringFromClass([self class]),
         idSafe(self, @"bundleIdentifier") ?: idSafe(self, @"identifier"), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}

static BOOL hMinOS(id self, SEL _cmd, id minVersion, id osVersion, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, id, id, NSError **))oMinOS)(self, _cmd, minVersion, osVersion, err);
    BOOL on = bypassEnabled();
    LOGS(@"[minos] %@ min=%@ current=%@ -> %d bypass=%d", NSStringFromClass([self class]),
         objDesc(minVersion), objDesc(osVersion), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}

static BOOL hThinning(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oThinning)(self, _cmd, err);
    BOOL on = bypassEnabled();
    LOGS(@"[thin] %@ -> %d bypass=%d", NSStringFromClass([self class]), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}


static BOOL hCurOS(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oCurOS)(self, _cmd, err);
    BOOL on = bypassEnabled();
    LOGS(@"[curos] %@ -> %d bypass=%d", NSStringFromClass([self class]), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}

static BOOL hOSVer(id self, SEL _cmd, id osVersion, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, id, NSError **))oOSVer)(self, _cmd, osVersion, err);
    BOOL on = bypassEnabled();
    LOGS(@"[osver] %@ target=%@ -> %d bypass=%d", NSStringFromClass([self class]), objDesc(osVersion), r, on);
    if (on) { if (err) *err = nil; return YES; }
    return r;
}

static BOOL hFamCompat(id self, SEL _cmd, int family) {
    BOOL r = ((BOOL (*)(id, SEL, int))oFamCompat)(self, _cmd, family);
    BOOL on = bypassEnabled();
    LOGS(@"[famc] %@ family=%d -> %d bypass=%d", NSStringFromClass([self class]), family, r, on);
    if (on) return YES;
    return r;
}

static BOOL hValidate(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oValidate)(self, _cmd, err);
    if (!r) LOGS(@"[validate] %@ -> NO err=%@", NSStringFromClass([self class]), err && *err ? objDesc(*err) : @"nil");
    return r;
}

static BOOL hValidateMeta(id self, SEL _cmd, NSError **err) {
    BOOL r = ((BOOL (*)(id, SEL, NSError **))oValidateMeta)(self, _cmd, err);
    if (!r) LOGS(@"[meta] %@ -> NO err=%@", NSStringFromClass([self class]), err && *err ? objDesc(*err) : @"nil");
    return r;
}

static void hookMethod(Class c, NSString *name, IMP newImp, IMP *oldImp, BOOL classMethod) {
    if (!c) return;
    Method m = classMethod ? class_getClassMethod(c, NSSelectorFromString(name))
                           : class_getInstanceMethod(c, NSSelectorFromString(name));
    if (!m) { LOGS(@"[hook] 缺少 %@", name); return; }
    *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    LOGS(@"[hook] %@ %s", name, method_getTypeEncoding(m) ?: "?");
}

__attribute__((constructor)) static void init(void) {
    LOGS(@"=== TFInstallBypass loaded in %@ ===", [[NSProcessInfo processInfo] processName]);
    Class c = objc_getClass("MIBundle");
    if (c) {
        hookMethod(c, @"isApplicableToCurrentDeviceFamilyWithError:", (IMP)hFamily, &oFamily, NO);
        hookMethod(c, @"isApplicableToCurrentDeviceCapabilitiesWithError:", (IMP)hCaps, &oCaps, NO);
        hookMethod(c, @"isMinimumOSVersion:applicableToOSVersion:error:", (IMP)hMinOS, &oMinOS, NO);
        hookMethod(c, @"thinningMatchesCurrentDeviceWithError:", (IMP)hThinning, &oThinning, NO);
        hookMethod(c, @"isApplicableToCurrentOSVersionWithError:", (IMP)hCurOS, &oCurOS, NO);
        hookMethod(c, @"isApplicableToOSVersion:error:", (IMP)hOSVer, &oOSVer, NO);
        hookMethod(c, @"isCompatibleWithDeviceFamily:", (IMP)hFamCompat, &oFamCompat, NO);
        hookMethod(c, @"_validateWithError:", (IMP)hValidate, &oValidate, NO);
        hookMethod(c, @"validateAppMetadataWithError:", (IMP)hValidateMeta, &oValidateMeta, NO);
    } else {
        LOGS(@"[init] 没有 MIBundle");
    }
}
