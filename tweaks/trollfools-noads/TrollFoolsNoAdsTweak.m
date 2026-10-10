//
//  TrollFoolsNoAdsTweak.m — TrollFools 去广告（越狱 dylib）
//  通过 MobileSubstrate/ElleKit filter 注入 wiki.qaq.TrollFools。
//
//  官方与修改版都用 @AppStorage("isAdvertisementHiddenV2") 控制应用列表里的
//  推广卡片（TrollRecorder / Reveil / XXTouch Elite / TrollVNC，修改版还多了 Letterpress）。
//  官方 .onAppear 里有 `Double.random(in: 0..<1) < 0.1` 的 10% 重置逻辑，
//  所以右滑 Hide 之后还会不定期冒出来。
//
//  这里直接接管该键：读取恒为 YES、写入被丢弃 → 广告 section 永远不渲染。
//  官方版 / 修改版同 key，一份 dylib 通吃。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kTFAdHiddenKey = @"isAdvertisementHiddenV2";

typedef id   (*TFNAObjIMP)(id, SEL, id);
typedef BOOL (*TFNABoolIMP)(id, SEL, id);
typedef void (*TFNASetBoolIMP)(id, SEL, BOOL, id);
typedef void (*TFNASetObjIMP)(id, SEL, id, id);

static TFNAObjIMP    orig_objectForKey;
static TFNABoolIMP   orig_boolForKey;
static TFNAObjIMP    orig_valueForKey;
static TFNASetBoolIMP orig_setBool;
static TFNASetObjIMP  orig_setObject;
static TFNASetObjIMP  orig_setValue;

static inline BOOL TFNAIsAdKey(NSString *key) {
    return [key isKindOfClass:[NSString class]] && [key isEqualToString:kTFAdHiddenKey];
}

static id tfna_objectForKey(id self, SEL _cmd, NSString *key) {
    if (TFNAIsAdKey(key)) return @YES;
    return orig_objectForKey ? orig_objectForKey(self, _cmd, key) : nil;
}

static BOOL tfna_boolForKey(id self, SEL _cmd, NSString *key) {
    if (TFNAIsAdKey(key)) return YES;
    return orig_boolForKey ? orig_boolForKey(self, _cmd, key) : NO;
}

static id tfna_valueForKey(id self, SEL _cmd, NSString *key) {
    if (TFNAIsAdKey(key)) return @YES;
    return orig_valueForKey ? orig_valueForKey(self, _cmd, key) : nil;
}

static void tfna_setBool(id self, SEL _cmd, BOOL value, NSString *key) {
    if (TFNAIsAdKey(key)) return;
    if (orig_setBool) orig_setBool(self, _cmd, value, key);
}

static void tfna_setObject(id self, SEL _cmd, id value, NSString *key) {
    if (TFNAIsAdKey(key)) return;
    if (orig_setObject) orig_setObject(self, _cmd, value, key);
}

static void tfna_setValue(id self, SEL _cmd, id value, NSString *key) {
    if (TFNAIsAdKey(key)) return;
    if (orig_setValue) orig_setValue(self, _cmd, value, key);
}

static void TFNASwap(Class cls, SEL sel, IMP newIMP, IMP *outOrig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_setImplementation(m, newIMP);
    if (outOrig && !*outOrig) *outOrig = old;
}

__attribute__((constructor))
static void TrollFoolsNoAdsInit(void) {
    // 类簇：真实类型是私有子类，取标准实例的 class 最稳。
    Class cls = [[NSUserDefaults standardUserDefaults] class];
    if (!cls) cls = [NSUserDefaults class];

    TFNASwap(cls, @selector(objectForKey:),    (IMP)tfna_objectForKey, (IMP *)&orig_objectForKey);
    TFNASwap(cls, @selector(boolForKey:),      (IMP)tfna_boolForKey,   (IMP *)&orig_boolForKey);
    TFNASwap(cls, @selector(valueForKey:),     (IMP)tfna_valueForKey,  (IMP *)&orig_valueForKey);
    TFNASwap(cls, @selector(setBool:forKey:),  (IMP)tfna_setBool,      (IMP *)&orig_setBool);
    TFNASwap(cls, @selector(setObject:forKey:),(IMP)tfna_setObject,    (IMP *)&orig_setObject);
    TFNASwap(cls, @selector(setValue:forKey:), (IMP)tfna_setValue,     (IMP *)&orig_setValue);

    // 双保险：直接把底层值写成 true（走原始 IMP，绕开上面的写入拦截）。
    if (orig_setBool) {
        orig_setBool([NSUserDefaults standardUserDefaults], @selector(setBool:forKey:), YES, kTFAdHiddenKey);
    }

    NSLog(@"[TrollFoolsNoAds] loaded — advertisement hidden");
}