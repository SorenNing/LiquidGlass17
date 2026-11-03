// ============================================================================
// LVGlassFilter — CAFilter 参数层（对照 LiquidGlass27 的 inputBanana* 设计）
//
// LiquidGlass27 用 KVC 把自定义参数塞进 CAFilter：
//     filters.<name>.inputBananaRefraction / inputBananaGlassTintAmount ...
// 服务端（BGRenderServer）在 hook 的 GaussianBlurFilter::render 里读这些 key。
//
// 本文件是同一设计的"客户端可独立运行"版本：
//   • 若服务端在线（backboardd 里有我们的引擎），滤镜走自定义 key，
//     服务端接管后用这些参数画真玻璃；
//   • 若服务端不在线，iOS 26+ 系统直接识别 UIGlassEffect 同源参数，
//     iOS 17 退化为标准 blurRadius —— 观感依然是玻璃，只是没有折射。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIColor.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

// 我们的自定义 input key 前缀（服务端按这个名字读取）
#define LV_KEY_REFRACTION   @"inputLVRefraction"    // 折射强度 0–2
#define LV_KEY_EDGE_HEIGHT  @"inputLVEdgeHeight"    // 边缘折射带宽
#define LV_KEY_TINT_AMOUNT  @"inputLVTintAmount"    // 染色 0–1
#define LV_KEY_TINT_COLOR   @"inputLVTintColor"     // 染色 RGBA
#define LV_KEY_HIGHLIGHT    @"inputLVHighlight"     // 高光 0–1
#define LV_KEY_DARK_RING    @"inputLVDarkRing"      // 内暗环 0–1
#define LV_KEY_RADIUS       @"inputLVRadius"        // 圆角
#define LV_KEY_SHAPE_SIZE   @"inputLVShapeSize"     // 形状尺寸

// 预期的服务端能力通报（Darwin notify key）
#define LV_NOTIFY_CAPS      @"iya.ning.lvglass/Capabilities"

static inline BOOL LVServerOnline(void)
{
    // 服务端在 backboardd 里加载后会把 state 置 1（notify_get_state 可查）
    uint64_t state = 0;
    int token = 0;
    notify_register_check("iya.ning.lvglass/EngineReady", &token);
    notify_get_state(token, &state);
    notify_cancel(token);
    return state != 0;
}

// CAFilter 是私有类：运行时取
static inline id LVFilterWithType(NSString *type) {
    Class cls = NSClassFromString(@"CAFilter");
    return cls ? [cls performSelector:@selector(filterWithType:) withObject:type] : nil;
}

// 给一个 layer 挂"玻璃滤镜"：
//   服务端在线 → 完整参数包（折射/染色/高光，服务端接管渲染）
//   否则       → 标准 gaussianBlur（系统渲染，观感退化但稳定）
static inline void LVApplyGlassFilter(CALayer *layer, CGFloat refraction,
                                      CGFloat tintAmount, UIColor *tintColor)
{
    id f = LVFilterWithType(@"gaussianBlur");
    if (!f) return;

    // 标准参数（系统认识）
    [f setValue:@(6.0) forKey:@"inputRadius"];
    [f setValue:@(YES) forKey:@"inputNormalized"];

    // 自定义参数（只有我们的服务端认识；多余 key 系统会忽略）
    CGFloat refr = LVServerOnline() ? refraction : 0.0;
    [f setValue:@(refr) forKey:LV_KEY_REFRACTION];
    [f setValue:@(tintAmount) forKey:LV_KEY_TINT_AMOUNT];
    if (tintColor) {
        CGFloat r,g,b,a; [tintColor getRed:&r green:&g blue:&b alpha:&a];
        [f setValue:@[[NSNumber numberWithFloat:r],[NSNumber numberWithFloat:g],
                      [NSNumber numberWithFloat:b],[NSNumber numberWithFloat:a]]
             forKey:LV_KEY_TINT_COLOR];
    }

    layer.filters = @[f];
}
