// ============================================================================
// LVGlassDock — Sileo 悬浮玻璃底栏 v0.1.2（客户端配方，不依赖 backboardd）
//
// 核心策略（对比 v0.1.1 的修正）：
//   • 不摘 tabBar、不挂约束 —— UITabBarController 内部会重设 tabBar frame，
//     摘出来重挂约束必打架。改为 hook UITabBar setFrame:，把系统给的任何
//     frame 强制改写成悬浮矩形（重入保护 + 尺寸兜底）。
//   • 玻璃底座用 UITabBarAppearance 的 backgroundEffect（系统材质层），
//     不再自己叠 CABackdropView —— 避免双重模糊。
//   • 边缘造型（bgFragment 第 10/11 步 CPU 版）= 只在尺寸变化时重建的
//     UIImageView 覆盖层，zPosition 高于按钮但几乎全透明（只有 1px 亮边）。
//   • 选中胶囊插在 _UIBarBackground 之上、按钮之下。
//   • Sileo 弹窗对齐：swizzle _TtC5Sileo15TabBarController 的
//     defaultFrameForBottomDockingView（mangled 名），让 popupBar 跟着悬浮条走。
//
// 布局参数 = 用户锁定的最终版：
//   高 64 / 左右边距 18 / 底边距 34 / 圆角 32(continuous) / 胶囊内缩 4 圆角 28
//
// 激活条件：bundle id 含 "sileo"；开关 LVDockEnabled（默认开，改后需重开 Sileo）
// 日志：    /var/mobile/Library/Accessibility/lvglass.log（>64KB 自动截断）
// ============================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

#define LV_DONE_TAG ((long)0x4C564431)   // 'LVD1' 已接管标记
#define LV_OV_TAG   ((long)0x6F76)       // 'ov'  边缘造型层
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
        if (!probe) {  // 主路径不可写 → 退到 Library 直下
            dir = @"/var/mobile/Library";
            path = [dir stringByAppendingPathComponent:@"lvglass.log"];
            probe = fopen(path.fileSystemRepresentation, "a");
        }
        if (probe) fclose(probe);
        // 简单截断：超过 64KB 重来（不做真环形缓冲）
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

// ---- 配置（LVGlass 自己的 domain，PreferenceLoader 可写） ------------------
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
    BOOL out = v ? [v boolValue] : YES;   // 默认开
    if (v) CFRelease((__bridge CFTypeRef)v);
    return out;
}

// 几何参数（2026-11-04 按视频实测校准：条更扁、边距更小、更贴底）
static CGFloat LVDockHeight(void)  { return 56; }
static CGFloat LVDockMargin(void)  { return 9;  }
static CGFloat LVDockBottom(void)  { return 21; }
static CGFloat LVDockRadius(void)  { return 28; }

// ============================================================================
#pragma mark - 边缘造型位图（bgFragment highlight+darkRing 的离线版）
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

        // -- 内暗环：exp2(-|inside - 1.5k| / max(k, 0.5)) 的近似
        CGContextSaveGState(c);
        CGFloat darkA = 0.22 * strength;
        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:k];
        [ring appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, k*1.4, k*1.4)
                                                    cornerRadius:k*0.65]];
        CGContextAddPath(c, ring.CGPath);
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0 alpha:darkA].CGColor);
        CGContextEOFillPath(c);
        CGContextRestoreGState(c);

        // -- 亮边：整圈 0.18 基线 + 顶部主光 0.70（pow(x,1.5) 渐隐）+ 底部 0.145 补光
        CGContextSaveGState(c);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:k] addClip];

        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.18*strength].CGColor);
        UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5, 0.5)
                                                        cornerRadius:k-0.5];
        edge.lineWidth = 1.0;
        CGContextAddPath(c, edge.CGPath);
        CGContextStrokePath(c);

        CGFloat topH = 3.0;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1,1,1, 0.70*strength,  1,1,1, 0.0};
        CGFloat locs[]  = {0, 1};
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad,
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
            CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)+topH), 0);
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

// ============================================================================
#pragma mark - 胶囊视图
// ============================================================================
@interface LVPillView : UIView
@end
@implementation LVPillView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = 22;                      // 高 48 = 56 - 内缩4*2
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
static void  (*orig_tabBarLayout)(id, SEL);
static void  (*orig_tabBarSetFrame)(id, SEL, CGRect);
static CGRect (*orig_popupDockFrame)(id, SEL);
// 注意：Sileo 的 defaultFrameForBottomDockingView 是 Swift 计算属性，
// 编译成返回 CGRect 的 C 函数（ARM64 经 x8 间接返回）。我们的 hook 必须
// 同样返回 CGRect，否则调用约定不匹配 → 真机 popupBar 一出现就崩。
// 这里用函数签名直接返回 CGRect（不是 NSValue！）。
static CGRect lv_popupDockFrame_hook(UITabBarController *vc, SEL _cmd);
static BOOL  lv_inSetFrame = NO;     // setFrame 重入保护
static BOOL  lv_dressPending = NO;
static void  lv_trySwizzlePopupFrame(void);

void LVDressUpTabBar(UITabBar *tb);
void lv_updateOverlay(UITabBar *tb);
void lv_updatePill(UITabBar *tb);

// 悬浮矩形（相对 tabBar 的 superview 坐标）
static CGRect LVFloatingFrame(CGSize containerSize)
{
    CGFloat w = containerSize.width - LVDockMargin() * 2;
    CGFloat h = LVDockHeight();
    if (w < 120) return CGRectNull;    // 容器异常（转场/分屏瞬间），不接管
    return CGRectMake(LVDockMargin(), containerSize.height - LVDockBottom() - h, w, h);
}

// --- 1. setFrame 钩子：把系统安排的 frame 强制改成悬浮矩形 -------------------
static void lv_tabBarSetFrame_hook(UITabBar *tb, SEL _cmd, CGRect frame)
{
    if (lv_inSetFrame || tb.tag != LV_DONE_TAG) {
        orig_tabBarSetFrame(tb, _cmd, frame);
        return;
    }
    CGSize cs = tb.superview ? tb.superview.bounds.size : frame.size;
    CGRect f = LVFloatingFrame(cs);
    if (CGRectIsNull(f) || CGRectEqualToRect(f, frame)) {
        orig_tabBarSetFrame(tb, _cmd, frame);
        return;
    }
    lv_inSetFrame = YES;
    orig_tabBarSetFrame(tb, _cmd, f);
    lv_inSetFrame = NO;
}

// --- 2. 布局钩子：轻量。首次延迟到本轮布局结束后打扮；平时只排胶囊 -----------
static void lv_tabBarLayout_hook(UITabBar *tb, SEL _cmd)
{
    orig_tabBarLayout(tb, _cmd);
    lv_trySwizzlePopupFrame();   // 类就绪后第一时间挂弹窗钩子
    if (tb.tag != LV_DONE_TAG) {
        if (!lv_dressPending) {
            lv_dressPending = YES;
            UITabBar *captured = tb;
            dispatch_async(dispatch_get_main_queue(), ^{
                lv_dressPending = NO;
                LVDressUpTabBar(captured);   // 见下：先声明
            });
        }
        return;
    }
    lv_updatePill(tb);
    lv_updateOverlay(tb);
}

// --- 3. 打扮：外观/圆角/胶囊/造型层 -----------------------------------------
void LVDressUpTabBar(UITabBar *tb)
{
    if (!tb || tb.superview == nil || tb.tag == LV_DONE_TAG) return;
    if (!LVEnabled()) return;

    // --- 0. 干掉 Sileo WhiteBlur 灰底：_UIVisualEffectSubview 的 0.85 白/黑
    //        （Sileo 自己的 hook 会设置背景色，这里把它的 view 直接隐藏/透明）
    Class subCls = NSClassFromString(@"_UIVisualEffectSubview");
    if (subCls) {
        for (UIView *v in tb.subviews) {
            if ([v isKindOfClass:subCls]) {
                v.backgroundColor = UIColor.clearColor;   // 去灰板
                v.hidden = NO;                            // 保留模糊，只去底色
            }
        }
    }
    // _UIBarBackground 里 Sileo 塞的自绘层同样清理
    Class bgCls = NSClassFromString(@"_UIBarBackground");
    if (bgCls) {
        for (UIView *v in tb.subviews) {
            if (![v isKindOfClass:bgCls]) continue;
            for (UIView *sv in v.subviews) {
                if ([sv isKindOfClass:subCls]) sv.backgroundColor = UIColor.clearColor;
                // hairline（分隔线）也是它画的
                if (sv.bounds.size.height <= 2.0 && sv.backgroundColor != nil &&
                    [NSStringFromClass(sv.class) containsString:@"Hairline"])
                    sv.hidden = YES;
            }
        }
    }

    // --- 玻璃材质（系统渲染，勿自己再叠 blur）
    UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    ap.backgroundEffect   = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    ap.backgroundColor    = UIColor.clearColor;
    ap.shadowColor        = UIColor.clearColor;
    ap.shadowImage        = [[UIImage alloc] init];
    tb.standardAppearance   = ap;
    tb.scrollEdgeAppearance = ap;

    tb.layer.cornerRadius   = LVDockRadius();
    tb.layer.cornerCurve    = kCACornerCurveContinuous;
    tb.clipsToBounds        = YES;

    // --- 胶囊（图标下面：_UIBarBackground 之上；初始位置放首格，避免闪现到角落）
    LVPillView *pill = objc_getAssociatedObject(tb, LV_PILL_KEY);
    if (!pill) {
        pill = [[LVPillView alloc] initWithFrame:CGRectMake(4, 4, 60, tb.bounds.size.height - 8)];
        BOOL placed = NO;
        if (bgCls) {
            for (UIView *v in tb.subviews) {
                if ([v isKindOfClass:bgCls]) { [tb insertSubview:pill aboveSubview:v]; placed = YES; break; }
            }
        }
        if (!placed) [tb insertSubview:pill atIndex:0];
        objc_setAssociatedObject(tb, LV_PILL_KEY, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // --- 边缘造型层（图标上面，但几乎全透明只留边光）
    UIImageView *ov = [[UIImageView alloc] initWithFrame:tb.bounds];
    ov.tag = LV_OV_TAG;
    ov.userInteractionEnabled = NO;
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [tb addSubview:ov];

    // --- 全部成功后才打标记（失败下次布局会重试）
    tb.tag = LV_DONE_TAG;
    lv_updateOverlay(tb);
    lv_updatePill(tb);
    LVLog(@"dressed superview=%@ items=%lu", NSStringFromClass(tb.superview.class) ?: @"?",
          (unsigned long)tb.items.count);
}

// --- 4. 边缘造型层：只在尺寸变化时重建 --------------------------------------
void lv_updateOverlay(UITabBar *tb)
{
    UIImageView *ov = [tb viewWithTag:LV_OV_TAG];
    if (!ov) return;
    NSValue *cached = objc_getAssociatedObject(tb, LV_OVSIZE_KEY);
    CGSize oldSize = cached ? [cached CGSizeValue] : CGSizeZero;
    CGSize now = tb.bounds.size;
    if (cached && CGSizeEqualToSize(oldSize, now)) return;
    objc_setAssociatedObject(tb, LV_OVSIZE_KEY, [NSValue valueWithCGSize:now],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat strength = LVFloat(@"LVDockHighlight", 0.9);
    ov.image = LVEdgeOverlay(now, LVDockRadius(), strength);
}

// --- 5. 胶囊排位 + 水滴滑移 --------------------------------------------------
void lv_updatePill(UITabBar *tb)
{
    LVPillView *pill = objc_getAssociatedObject(tb, LV_PILL_KEY);
    if (!pill || tb.items.count == 0 || tb.bounds.size.width < 40) return;
    NSUInteger idx = tb.selectedItem ? [tb.items indexOfObject:tb.selectedItem] : 0;
    if (idx == NSNotFound) idx = 0;

    CGFloat tabW = tb.bounds.size.width / tb.items.count;
    CGRect target = CGRectMake(tabW * idx + 4, 4, tabW - 8, tb.bounds.size.height - 8);

    if (CGRectIsEmpty(pill.frame)) {
        pill.frame = target;                            // 首次直接落位
        return;
    }
    if (CGRectEqualToRect(pill.frame, target)) return;

    // 水滴滑移：400ms，presentationLayer 起点连点续接
    CGRect from = [(CALayer *)[pill valueForKey:@"presentationLayer"] frame];
    if (CGRectIsEmpty(from)) from = pill.frame;
    [pill.layer removeAllAnimations];
    [UIView animateKeyframesWithDuration:0.4 delay:0
        options:UIViewKeyframeAnimationOptionCalculationModeCubic | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            [UIView addKeyframeWithRelativeStartTime:0  relativeDuration:0.6 animations:^{
                pill.frame = CGRectMake(from.origin.x + (target.origin.x - from.origin.x) * 0.7,
                                        target.origin.y, target.size.width, target.size.height);
            }];
            [UIView addKeyframeWithRelativeStartTime:0.6 relativeDuration:0.4 animations:^{
                pill.frame = target;
            }];
        } completion:nil];
}

// ============================================================================
#pragma mark - Sileo 弹窗对齐
// defaultFrameForBottomDockingView 的 Swift 类运行时名是 mangled 的
// 注意：constructor 阶段 Swift 类还没注册（日志证实 not found），
// 所以改成「懒挂」：第一次 layout 时类已存在，在那时再 swizzle。
// ============================================================================
static BOOL lv_popupHooked = NO;

static void lv_trySwizzlePopupFrame(void)
{
    if (lv_popupHooked) return;
    Class cls = NSClassFromString(@"_TtC5Sileo15TabBarController")
             ?: NSClassFromString(@"TabBarController");
    if (!cls) return;   // 还没注册，下次再试
    SEL sel = @selector(defaultFrameForBottomDockingView);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { lv_popupHooked = YES; LVLog(@"defaultFrame getter not found on %@ (no popup hook)", cls); return; }

    orig_popupDockFrame = (CGRect(*)(id,SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)lv_popupDockFrame_hook);
    lv_popupHooked = YES;
    LVLog(@"popup frame hook on %@", cls);
}

static CGRect lv_popupDockFrame_hook(UITabBarController *vc, SEL _cmd)
{
    // 返回悬浮矩形，让 popupBar 贴着玻璃条上方（直接返回 CGRect，见前注）
    if (vc.view.window) {
        CGRect f = LVFloatingFrame(vc.view.bounds.size);
        if (!CGRectIsNull(f)) return f;
    }
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
    // 设置变更：只刷新偏好缓存。不做任何视图操作（防崩），
    // 下一次 tabBar layout 自然按新值渲染。
    dispatch_async(dispatch_get_main_queue(), ^{
        LVLog(@"reload -> %@", LVEnabled() ? @"enabled" : @"disabled");
    });
}

__attribute__((constructor))
static void LVInstall(void)
{
    @autoreleasepool {
        // 第一行日志放在一切判定之前：只要 dylib 被加载就必须出现。
        // 没有这行 = dylib 根本没被 substrate 注入（filter 问题），不是代码问题。
        NSString *bid0 = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        NSString *exe0 = [[NSProcessInfo processInfo] processName] ?: @"(nil)";
        LVLog(@"dylib loaded: bid=%@ exe=%@", bid0, exe0);

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
        // 双保险：bundle id 或可执行名任一含 sileo（大小写不敏感）
        if (![bid.lowercaseString containsString:@"sileo"] &&
            ![exe.lowercaseString containsString:@"sileo"]) {
            LVLog(@"not sileo target, skip");
            return;   // 只在 Sileo
        }
        if (!LVEnabled()) { LVLog(@"disabled, skip %@", bid); return; }

        // 监听设置变更（切换开关后立即生效，不用重开）
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, LVReloadCB,
                                        (__bridge CFStringRef)@"com.ning.lvglass/reload",
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        Method m1 = class_getInstanceMethod([UITabBar class], @selector(layoutSubviews));
        Method m2 = class_getInstanceMethod([UITabBar class], @selector(setFrame:));
        if (!m1 || !m2) return;
        orig_tabBarLayout  = (void(*)(id,SEL))method_getImplementation(m1);
        orig_tabBarSetFrame = (void(*)(id,SEL,CGRect))method_getImplementation(m2);
        method_setImplementation(m1, (IMP)lv_tabBarLayout_hook);
        method_setImplementation(m2, (IMP)lv_tabBarSetFrame_hook);

        LVLog(@"installed in %@ (v0.1.4)", bid);
    }
}
