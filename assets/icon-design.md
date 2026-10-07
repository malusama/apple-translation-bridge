# 本地翻译桥 Liquid Glass 图标

采用 Apple Icon Composer 的原生分层图标。两片透光玻璃与 A / 文 表达英中翻译；玻璃边缘、高光、折射与层间阴影由系统材质产生。素材是原创 SVG 几何与 Core Text 字形轮廓，本版没有使用栅格图像生成工具。

## 设计源与导出

- `MacApp/AppIcon.icon`：应用的分层源文件，包含独立的玻璃与字形图层。
- `scripts/create-glass-icon.swift`：重建矢量图层和 Icon Composer 配置。
- `scripts/generate-icon.swift`：通过 Xcode 自带的 Icon Composer 导出默认外观和 macOS 静态兼容尺寸。
- `assets/liquid-glass/default.png`、`dark.png`：浅色与深色设计预览。系统图标也支持单色外观。

设计遵循 [Apple 的图标规范](https://developer.apple.com/design/human-interface-guidelines/app-icons) 与 [Icon Composer 的分层材质流程](https://developer.apple.com/icon-composer/)。应用保留编译后的玻璃图层，不用静态 ICNS 强制覆盖 Dock 图标。

## HDR 高光

`scripts/export-icon-hdr.swift` 在玻璃上缘的一小段反光中加入线性亮度能量，然后使用 Core Image 编码为 Adaptive HDR。HEIC 与 JPEG 都包含 ISO 增益图；正常亮度的基准图像仍然保留。高光来自设计中明确指定的局部反射。

- `assets/liquid-glass/icon-light-hdr.heic` / `.jpg`：浅色 HDR 版本。
- `assets/liquid-glass/icon-dark-hdr.heic` / `.jpg`：深色 HDR 版本。
- `assets/liquid-glass/hdr-verification-light.json` / `hdr-verification-dark.json`：重新解码后的增益图、动态范围与峰值验证。
- `highlight-mask-light.png` / `highlight-mask-dark.png`：高光影响范围。

浅色 HEIC 的解码峰值为普通白色的约 2.71 倍，深色 HEIC 约 3.44 倍；增强范围约占 0.13% 的像素。应用窗口使用对应外观的 HEIC，并通过 SwiftUI `allowedDynamicRange(.high)` 允许 HDR 显示。实际屏幕亮度由显示设备和系统决定。聊天中的 PNG 与商店截图是普通亮度预览；Dock 的动态材质由系统渲染，上面的 HDR 数值针对导出文件。

## 重建

```sh
swift scripts/create-glass-icon.swift
swift scripts/generate-icon.swift
# 使用 Xcode 的 ictool 导出 Dark 外观到 assets/liquid-glass/dark.png 后：
swift scripts/export-icon-hdr.swift assets/liquid-glass/default.png assets/liquid-glass light
swift scripts/export-icon-hdr.swift assets/liquid-glass/dark.png assets/liquid-glass dark
```

HDR 图像复制为 `MacApp/BrandIcon-Light.heic`、`MacApp/BrandIcon-Dark.heic`；默认 PNG 提供窗口图标的透明轮廓蒙版。
