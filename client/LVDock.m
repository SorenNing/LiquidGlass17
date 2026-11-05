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
#define LV_PILL_KEY  "lv_pill"
#define LV_OVSIZE_KEY "lv_ovsize"

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
#pragma mark - 边缘造型位图
// ============================================================================
static UIImage *LVEdgeOverlay(CGSize size, CGFloat radius, CGFloat strength)
{
    if (size.width < 4 || size.height < 4) return nil;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.opaque = NO;
    f.scale  = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGRect rect = CGRectMake(1, 1, size.width - 2, size.height - 2);
        CGFloat k = radius;

        // 内暗环
        CGContextSaveGState(c);
        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:k];
        [ring appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, k*1.4, k*1.4)
                                                    cornerRadius:k*0.65]];
        CGContextAddPath(c, ring.CGPath);
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0 alpha:0.22*strength].CGColor);
        CGContextEOFillPath(c);
        CGContextRestoreGState(c);

        // 亮边
        CGContextSaveGState(c);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:k] addClip];
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.18*strength].CGColor);
        UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5, 0.5)
                                                        cornerRadius:k-0.5];
        edge.lineWidth = 1.0;
        CGContextAddPath(c, edge.CGPath);
        CGContextStrokePath(c);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1,1,1, 0.70*strength,  1,1,1, 0.0};
        CGFloat locs[]  = {0, 1};
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad,
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)+3.0), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.145*strength].CGColor);
        UIBezierPath *bot = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 1.5, 1.5)
                                                       cornerRadius:k-1.5];
        bot.lineWidth = 1.0;
        CGContextAddPath(c, bot.CGPath);
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

        // —— 玻璃外观
        UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
        [ap configureWithTransparentBackground];
        ap.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
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
        [tb removeFromSuperview];
        tb.frame = container.bounds;
        tb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:tb];
        if (!container.superview) [tbc.view addSubview:container];

        // —— 胶囊 & 造型层加回 tabBar
        if (!pill.superview) [tb addSubview:pill];
        UIImageView *ov = (UIImageView *)[tb viewWithTag:LV_OV_TAG];
        if (!ov) {
            ov = [[UIImageView alloc] initWithFrame:tb.bounds];
            ov.tag = LV_OV_TAG;
            ov.userInteractionEnabled = NO;
            ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [tb addSubview:ov];
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

// --- 边缘造型层：只在尺寸变化时重建 -----------------------------------------
void lv_updateOverlay(UITabBar *tb)
{
    @try {
        UIImageView *ov = (UIImageView *)[tb viewWithTag:LV_OV_TAG];
        if (!ov) return;
        NSValue *cached = objc_getAssociatedObject(tb, LV_OVSIZE_KEY);
        CGSize oldSize = cached ? [cached CGSizeValue] : CGSizeZero;
        CGSize now = tb.bounds.size;
        if (cached && CGSizeEqualToSize(oldSize, now)) return;
        objc_setAssociatedObject(tb, LV_OVSIZE_KEY, [NSValue valueWithCGSize:now],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat strength = LVFloat(@"LVDockHighlight", 0.9);
        ov.image = LVEdgeOverlay(now, LVDockRadius(), strength);
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

        Method m = class_getInstanceMethod([UITabBar class], @selector(layoutSubviews));
        if (!m) return;
        orig_tabBarLayout = (void(*)(id,SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)lv_tabBarLayout_hook);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, LVReloadCB,
                                        (__bridge CFStringRef)@"com.ning.lvglass/reload",
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        LVLog(@"installed in %@ (v0.2.1)", bid);
    }
}
