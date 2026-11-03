# LVGlass — Sileo 悬浮玻璃底栏

LiquidGlass17 项目的第一个落地功能：把 Sileo 的 UITabBar 变成悬浮玻璃条。
客户端配方（不需要 backboardd 服务端，玻璃采样的是 Sileo 自己的内容）。

## 效果
- 悬浮底栏：高 64 / 左右边距 18 / 底边距 34 / 圆角 32（continuous）
- 材质：SystemThinMaterial 玻璃（列表从玻璃下滚过）
- 边缘造型：双方向高光（1.0 / 0.145 权重）+ 内暗环（bgFragment 第 10/11 步 CPU 版）
- 选中胶囊：每 Tab 宽/N、四周内缩 4、圆角 28，400ms 水滴滑移（连点续接）

## 文件
```
client/LVDock.m         主实现（TabBar 接管 + 玻璃容器 + 胶囊 + 边缘绘制）
client/LVGlassFilter.h  CAFilter 参数层（服务端在线时启用折射参数）
client/LVGlassDock.plist  MobileSubstrate filter（只注入 Sileo）
tools/check.sh          本地语法检查（用本地 iOS 16.5 SDK）
tools/ci-build.sh       Actions 构建（arm64e + 签名 + deb）
.github/workflows/build.yml
```

## 安装
1. push 后 Actions 产出 `com.ning.lvglass_x.x.x_iphoneos-arm64e.deb`
2. 下载安装，打开 Sileo 看底栏

## 开关（NVG 配置，Sileo 进程的 defaults）
```
LVDockEnabled    BOOL  默认 YES
LVDockHighlight  数字  高光强度 0-1，默认 0.9
```

## 日志
```
/var/mobile/Library/Accessibility/lvglass.log
```
