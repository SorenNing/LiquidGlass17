// ============================================================================
// LVGlassDock — Sileo 悬浮玻璃底栏 v0.2.1（防闪退重构）
//
// 崩溃史与结论：
//   0.1.2  摘出重挂骨架        → 不闪退，但样式差（Sileo 灰底没清）
//   0.1.3/0.1.9  hook setFrame → 闪退（与 UITabBarController 内部布局拉锯，
//                              dispatch block 抛未捕获异常 → SIGABRT，.ips 实锤）
//   0.2.0  加灰底清理          → 仍闪退（同一个 setFrame hook）
//
// v0.2.1 = 回 0.1.2 的「摘出重挂」骨架（已验证不闪）+ 0.2.0 的灰底清理 +
//          校准几何（高56/边距9/底距21/圆角28）+ 所有清理包 @try。
//   * 不再 hook setFrame
//   * tabBar 摘到 vc.view 上，用 frame 直接管理，系统布局碰不到它
//   * layout hook 只做胶囊排位（纯算术，不可能抛异常）
// ============================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

#define LV_DONE_TAG ((long)0x4C564431)   // 'LVD1'
#define LV_OV_TAG   ((long)0x6F76)       // 'ov'
#define LV_GLASS_TAG ((long)0x6C7667)    // 'lvg'
#define LV_PILL_KEY  "lv_pill"
#define LV_OVSIZE_KEY "lv_ovsize"

@class _UIVisualEffectSubview;   // 私有类，运行时取

// ---- 日志 ------------------------------------------------------------------
static FILE *lv_log_file = nil;
static void LVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LVLog(NSString *fmt, ...)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = @"/var/mobile/Library/Accessibility";
        mkdir(dir.fileSystemRepresentation, 0755);
        NSString *path = [dir stringByAppendingPathComponent:@"lvglass.log"];
        FILE *probe = fopen(path.fileSystemRepresentation, "a");
        if (!probe) {
            dir = @"/var/mobile/Library";
            path = [dir stringByAppendingPathComponent:@"lvglass.log"];
        } else { fclose(probe); }
        struct stat st = {0};
        if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 64 * 1024)
            truncate(path.fileSystemRepresentation, 0);
        lv_log_file = fopen(path.fileSystemRepresentation, "a");
    });
    if (!lv_log_file) return;
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(lv_log_file, "[lvdock] %s\n", line.UTF8String);
    fflush(lv_log_file);
}

// ---- 配置 ------------------------------------------------------------------
#define LV_PREFS_DOMAIN @"com.ning.lvglass"
static CFStringRef LVDomain(void) { return (__bridge CFStringRef)LV_PREFS_DOMAIN; }

static CGFloat LVFloat(NSString *key, CGFloat def) {
    CFPreferencesAppSynchronize(LVDomain());
    id v = (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, LVDomain());
    if (v == nil) v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    CGFloat out = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
    if (v) CFRelease((__bridge CFTypeRef)v);
    return out;
}
static BOOL LVEnabled(void) {
    CFPreferencesAppSynchronize(LVDomain());
    id v = (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)@"LVDockEnabled", LVDomain());
    if (v == nil) v = [[NSUserDefaults standardUserDefaults] objectForKey:@"LVDockEnabled"];
    BOOL out = v ? [v boolValue] : YES;
    if (v) CFRelease((__bridge CFTypeRef)v);
    return out;
}

// 几何（视频实测校准）
static CGFloat LVDockHeight(void)  { return 56; }
static CGFloat LVDockMargin(void)  { return 9;  }
static CGFloat LVDockBottom(void)  { return 21; }
static CGFloat LVDockRadius(void)  { return 28; }

// ============================================================================
#pragma mark - 玻璃面板位图（纯自绘：不依赖任何系统模糊，立刻显示、永不消失）
// ============================================================================
static UIImage *LVGlassPanel(CGSize size, BOOL dark, CGFloat radius, CGFloat strength)
{
    if (size.width < 4 || size.height < 4) return nil;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.opaque = NO;
    f.scale  = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat k = radius;

        // 基底：浅色乳白玻璃 / 深色烟灰玻璃
        CGFloat baseA = dark ? 0.46 : 0.74;
        UIColor *base = dark ? [UIColor colorWithWhite:0.16 alpha:baseA]
                             : [UIColor colorWithWhite:1.00 alpha:baseA];
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:k];
        [base setFill];
        [shape fill];

        CGContextSaveGState(c);
        [shape addClip];

        // 顶部高光（越靠上越亮）
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1,1,1, (dark ? 0.26 : 0.30) * strength,  1,1,1, 0.0};
        CGFloat locs[]  = {0, 1};
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad,
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect) + size.height * 0.55), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);

        // 底部轻微压暗（体积感）
        CGFloat comps2[] = {0,0,0, 0.0,  0,0,0, (dark ? 0.16 : 0.10)};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(cs, comps2, locs, 2);
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        grad2 = CGGradientCreateWithColorComponents(cs2, comps2, locs, 2);
        CGContextDrawLinearGradient(c, grad2,
            CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect) - size.height * 0.45),
            CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(cs2);

        // 1px 亮边（玻璃亮边）
        UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5, 0.5)
                                                        cornerRadius:k - 0.5];
        edge.lineWidth = 1.0;
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:(dark ? 0.30 : 0.92)].CGColor);
        CGContextAddPath(c, edge.CGPath);
        CGContextStrokePath(c);

        // 内暗环（靠内一圈轻微压暗，做出厚度）
        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 2.5, 2.5)
                                                        cornerRadius:k - 2.5];
        ring.lineWidth = 3.0;
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0 alpha:(dark ? 0.14 : 0.06)].CGColor);
        CGContextAddPath(c, ring.CGPath);
        CGContextStrokePath(c);

        CGContextRestoreGState(c);
    }];
}

#pragma mark - 胶囊
@interface LVPillView : UIView
@end
@implementation LVPillView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = 22;
        self.layer.cornerCurve  = kCACornerCurveContinuous;
        self.layer.borderWidth  = 1.0;
        self.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.backgroundColor    = [UIColor colorWithWhite:1 alpha:0.42];
    }
    return self;
}
@end

// ============================================================================
#pragma mark - 接管
// ============================================================================
static void (*orig_tabBarLayout)(id, SEL);
static CGRect (*orig_popupDockFrame)(id, SEL);
static void  lv_trySwizzlePopupFrame(void);
static CGRect lv_popupDockFrame_hook(UITabBarController *vc, SEL _cmd);
static BOOL  lv_dressPending = NO;

void lv_updateOverlay(UITabBar *tb);
void lv_updatePill(UITabBar *tb);

// --- 清理 Sileo 灰底/hairline（全部 @try，绝不抛） ---------------------------
static void lv_cleanSileoOverlay(UITabBar *tb)
{
    @try {
        Class subCls = NSClassFromString(@"_UIVisualEffectSubview");
        Class bgCls  = NSClassFromString(@"_UIBarBackground");
        for (UIView *v in [tb.subviews copy]) {
            @try {
                if (subCls && [v isKindOfClass:subCls]) {
                    v.backgroundColor = UIColor.clearColor;
                    continue;
                }
                if (bgCls && [v isKindOfClass:bgCls]) {
                    // _UIBarBackground 自己也带白/灰底（Sileo 上色），一并清掉
                    v.backgroundColor = UIColor.clearColor;
                    v.layer.cornerRadius = LVDockRadius();
                    v.clipsToBounds = YES;
                    for (UIView *sv in [v.subviews copy]) {
                        @try {
                            if (subCls && [sv isKindOfClass:subCls])
                                sv.backgroundColor = UIColor.clearColor;
                            else if (sv.bounds.size.height <= 2.0 && sv.backgroundColor &&
                                     [NSStringFromClass(sv.class) containsString:@"Hairline"])
                                sv.hidden = YES;
                        } @catch (NSException *e) {}
                    }
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {
        LVLog(@"clean err %@", e);
    }
}

// --- 打扮：摘出重挂（0.1.2 验证过的骨架）+ 玻璃外观 + 胶囊 + 造型层 ----------
static void LVDressUpTabBar(UITabBar *tb)
{
    if (!tb || tb.superview == nil || tb.tag == LV_DONE_TAG) return;
    if (!LVEnabled()) return;

    @try {
        // 找 UITabBarController
        UIViewController *tbc = nil;
        UIResponder *r = tb.nextResponder;
        while (r) {
            if ([r isKindOfClass:[UITabBarController class]]) { tbc = (UITabBarController *)r; break; }
            r = r.nextResponder;
        }
        if (!tbc.view) return;

    // --- tabBar 本体完全透明：玻璃由容器里的 CABackdropLayer 自绘
    UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    ap.backgroundEffect = nil;
    ap.backgroundColor  = UIColor.clearColor;
        ap.shadowColor      = UIColor.clearColor;
        ap.shadowImage      = [[UIImage alloc] init];
        tb.standardAppearance   = ap;
        tb.scrollEdgeAppearance = ap;
        tb.layer.cornerRadius   = LVDockRadius();
        tb.layer.cornerCurve    = kCACornerCurveContinuous;
        tb.clipsToBounds        = YES;

        // —— 胶囊（先建，摘出后加回）
        LVPillView *pill = objc_getAssociatedObject(tb, LV_PILL_KEY);
        if (!pill) {
            pill = [[LVPillView alloc] initWithFrame:CGRectMake(4, 4, 60, LVDockHeight() - 8)];
            objc_setAssociatedObject(tb, LV_PILL_KEY, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // —— 摘出重挂：UIKit 禁止对 controller 管理的 tabBar 直接设 frame
        //   （"Cannot choose layout method for UITabBar managed by a controller"）。
        //   解法：包一层自定义容器 lv_container——controller 管不到容器，
        //   tabBar 在容器里 translates=NO 填满，浮动态全在容器 frame 上改。
        CGRect vcBounds = tbc.view.bounds;
        void *ck = (void *)"lv_dock_container";
        UIView *container = objc_getAssociatedObject(tbc, ck);
        if (!container) {
            container = [[UIView alloc] initWithFrame:CGRectMake(LVDockMargin(),
                vcBounds.size.height - LVDockBottom() - LVDockHeight(),
                vcBounds.size.width - LVDockMargin() * 2, LVDockHeight())];
            container.layer.cornerRadius = LVDockRadius();
            container.layer.cornerCurve  = kCACornerCurveContinuous;
            container.clipsToBounds      = YES;
            container.autoresizingMask   = UIViewAutoresizingFlexibleWidth |
                                           UIViewAutoresizingFlexibleTopMargin;
            objc_setAssociatedObject(tbc, ck, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // —— 自绘玻璃面板（CPU 位图，立刻显示、永不消失）
        UIImageView *panel = (UIImageView *)[container viewWithTag:LV_GLASS_TAG];
        if (!panel) {
            panel = [[UIImageView alloc] initWithFrame:container.bounds];
            panel.tag = LV_GLASS_TAG;
            panel.userInteractionEnabled = NO;
            panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [container insertSubview:panel atIndex:0];
        }
        BOOL dark = (tb.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        panel.image = LVGlassPanel(container.bounds.size, dark,
                                   LVDockRadius(), LVFloat(@"LVDockHighlight", 0.9));

        // —— tabBar 本体：完全透明（不要系统材质，避免一切外部干扰）
        [tb removeFromSuperview];
        tb.backgroundColor = UIColor.clearColor;
        tb.frame = container.bounds;
        tb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:tb];
        [container bringSubviewToFront:tb];
        if (!container.superview) {
            [tbc.view addSubview:container];
            [tbc.view bringSubviewToFront:container];
        }
        // 诊断：列出 tabBar 子视图（找"盖住图标"的层）
        NSMutableString *diag = [NSMutableString string];
        for (UIView *v in tb.subviews)
            [diag appendFormat:@"%@(%.0fx%.0f h=%.1f) ", NSStringFromClass(v.class),
                v.bounds.size.width, v.bounds.size.height, v.alpha];
        LVLog(@"tb subs: %@", diag);

        // —— 胶囊加回 tabBar（图标下面）
        if (pill.superview == tb) [tb bringSubviewToFront:pill];
        if (!pill.superview) {
            Class bgCls2 = NSClassFromString(@"_UIBarBackground");
            BOOL placed2 = NO;
            if (bgCls2) {
                for (UIView *v in [tb.subviews copy]) {
                    if ([v isKindOfClass:bgCls2]) { [tb insertSubview:pill aboveSubview:v]; placed2 = YES; break; }
                }
            }
            if (!placed2) [tb insertSubview:pill atIndex:0];
        }

        lv_cleanSileoOverlay(tb);
        tb.tag = LV_DONE_TAG;
        lv_updateOverlay(tb);
        lv_updatePill(tb);
        LVLog(@"dressed ok items=%lu", (unsigned long)tb.items.count);
    } @catch (NSException *e) {
        LVLog(@"dress err %@", e);   // 失败不打 tag，下次布局重试
    }
}

// --- 玻璃面板：尺寸/深浅色变化时重建位图 -----------------------------------
void lv_updateOverlay(UITabBar *tb)
{
    @try {
        UIView *container = tb.superview;
        UIImageView *panel = (UIImageView *)[container viewWithTag:LV_GLASS_TAG];
        if (!panel) return;
        static char kSizeKey;   // per-container 缓存
        NSValue *cached = objc_getAssociatedObject(container, &kSizeKey);
        CGSize now = container.bounds.size;
        BOOL dark = (tb.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        if (cached && CGSizeEqualToSize([cached CGSizeValue], now) && panel.image) return;
        objc_setAssociatedObject(container, &kSizeKey, [NSValue valueWithCGSize:now],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        panel.image = LVGlassPanel(now, dark, LVDockRadius(), LVFloat(@"LVDockHighlight", 0.9));
    } @catch (NSException *e) {}
}

// --- 胶囊排位 + 水滴滑移（纯算术） -------------------------------------------
void lv_updatePill(UITabBar *tb)
{
    @try {
        LVPillView *pill = objc_getAssociatedObject(tb, LV_PILL_KEY);
        if (!pill || tb.items.count == 0 || tb.bounds.size.width < 40) return;
        NSUInteger idx = tb.selectedItem ? [tb.items indexOfObject:tb.selectedItem] : 0;
        if (idx == NSNotFound) idx = 0;

        CGFloat tabW = tb.bounds.size.width / tb.items.count;
        CGRect target = CGRectMake(tabW * idx + 4, 4, tabW - 8, tb.bounds.size.height - 8);

        if (CGRectIsEmpty(pill.frame)) { pill.frame = target; return; }
        if (CGRectEqualToRect(pill.frame, target)) return;

        CGRect from = [(CALayer *)[pill valueForKey:@"presentationLayer"] frame];
        if (CGRectIsEmpty(from)) from = pill.frame;
        [pill.layer removeAllAnimations];
        [UIView animateKeyframesWithDuration:0.4 delay:0
            options:UIViewKeyframeAnimationOptionCalculationModeCubic | UIViewAnimationOptionBeginFromCurrentState
            animations:^{
                [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.6 animations:^{
                    pill.frame = CGRectMake(from.origin.x + (target.origin.x - from.origin.x) * 0.7,
                                            target.origin.y, target.size.width, target.size.height);
                }];
                [UIView addKeyframeWithRelativeStartTime:0.6 relativeDuration:0.4 animations:^{
                    pill.frame = target;
                }];
            } completion:nil];
    } @catch (NSException *e) {}
}

// --- 选中项变化时更新胶囊（tabBar 被摘出后 layout 不一定会重跑） -------------
static void (*orig_setSelectedItem)(id, SEL, UITabBarItem *);
static void (*orig_setSelectedItemAnimated)(id, SEL, UITabBarItem *, BOOL);
void lv_setSelectedItem_hook(id self, SEL _cmd, UITabBarItem *item)
{
    orig_setSelectedItem(self, _cmd, item);
    UITabBar *tb = (UITabBar *)self;
    lv_updatePill(tb);
}
void lv_setSelectedItemAnimated_hook(id self, SEL _cmd, UITabBarItem *item, BOOL animated)
{
    orig_setSelectedItemAnimated(self, _cmd, item, animated);
    UITabBar *tb = (UITabBar *)self;
    lv_updatePill(tb);
}

// --- 布局钩子：只排胶囊；首次延迟打扮；不动 frame、不抛异常 ------------------
static void lv_tabBarLayout_hook(UITabBar *tb, SEL _cmd)
{
    orig_tabBarLayout(tb, _cmd);
    @try {
        lv_trySwizzlePopupFrame();
        if (tb.tag != LV_DONE_TAG) {
            if (!lv_dressPending) {
                lv_dressPending = YES;
                __weak UITabBar *weak = tb;
                dispatch_async(dispatch_get_main_queue(), ^{
                    lv_dressPending = NO;
                    UITabBar *strong = weak;
                    if (strong) LVDressUpTabBar(strong);
                });
            }
            return;
        }
        lv_updatePill(tb);
        lv_updateOverlay(tb);
    } @catch (NSException *e) {
        LVLog(@"layout err %@", e);
    }
}

// ============================================================================
#pragma mark - Sileo 弹窗对齐（懒挂）
// ============================================================================
static BOOL lv_popupHooked = NO;

static void lv_trySwizzlePopupFrame(void)
{
    if (lv_popupHooked) return;
    @try {
        Class cls = NSClassFromString(@"_TtC5Sileo15TabBarController")
                 ?: NSClassFromString(@"TabBarController");
        if (!cls) return;
        SEL sel = @selector(defaultFrameForBottomDockingView);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { lv_popupHooked = YES; return; }
        orig_popupDockFrame = (CGRect(*)(id,SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)lv_popupDockFrame_hook);
        lv_popupHooked = YES;
        LVLog(@"popup hook on %@", cls);
    } @catch (NSException *e) {
        lv_popupHooked = YES;
    }
}

static CGRect lv_popupDockFrame_hook(UITabBarController *vc, SEL _cmd)
{
    @try {
        if (vc.view.window) {
            CGRect container = vc.view.bounds;
            CGFloat w = container.size.width - LVDockMargin() * 2;
            if (w >= 120) {
                return CGRectMake(LVDockMargin(),
                                  container.size.height - LVDockBottom() - LVDockHeight(),
                                  w, LVDockHeight());
            }
        }
    } @catch (NSException *e) {}
    return orig_popupDockFrame(vc, _cmd);
}

// ============================================================================
#pragma mark - 安装
// ============================================================================
static void LVReloadCB(CFNotificationCenterRef center __attribute__((unused)),
                       void *observer __attribute__((unused)),
                       CFStringRef name __attribute__((unused)),
                       const void *object __attribute__((unused)),
                       CFDictionaryRef userInfo __attribute__((unused)))
{
    dispatch_async(dispatch_get_main_queue(), ^{
        LVLog(@"reload -> %@", LVEnabled() ? @"enabled" : @"disabled");
    });
}

__attribute__((constructor))
static void LVInstall(void)
{
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"(nil)";
        LVLog(@"dylib loaded: bid=%@ exe=%@", bid, exe);

        if (![bid.lowercaseString containsString:@"sileo"] &&
            ![exe.lowercaseString containsString:@"sileo"]) {
            LVLog(@"not sileo, skip");
            return;
        }
        if (!LVEnabled()) { LVLog(@"disabled"); return; }

        Method ms = class_getInstanceMethod([UITabBar class], @selector(setSelectedItem:));
        if (ms) {
            orig_setSelectedItem = (void(*)(id,SEL,UITabBarItem *))method_getImplementation(ms);
            method_setImplementation(ms, (IMP)lv_setSelectedItem_hook);
        }
        Method msa = class_getInstanceMethod([UITabBar class], @selector(setSelectedItem:animated:));
        if (msa) {
            orig_setSelectedItemAnimated = (void(*)(id,SEL,UITabBarItem *,BOOL))method_getImplementation(msa);
            method_setImplementation(msa, (IMP)lv_setSelectedItemAnimated_hook);
        }

        Method m = class_getInstanceMethod([UITabBar class], @selector(layoutSubviews));
        if (!m) return;
        orig_tabBarLayout = (void(*)(id,SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)lv_tabBarLayout_hook);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, LVReloadCB,
                                        (__bridge CFStringRef)@"com.ning.lvglass/reload",
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        LVLog(@"installed in %@ (v0.3.4)", bid);
    }
}
