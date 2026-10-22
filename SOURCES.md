# 技术来源

## AppKit 压力输入

按刻通过 Apple 的 AppKit 接口读取压力阶段和力度：

- [NSEvent.pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure)：每个阶段有自己的力度曲线，读数属于当前阶段。
- [NSEvent.stage](https://developer.apple.com/documentation/appkit/nsevent/stage)：阶段 2 可用于 Force Click 等即时动作。
- [NSView.pressureConfiguration](https://developer.apple.com/documentation/appkit/nsview/pressureconfiguration)：配置指针所在视图的压力行为。力度显示区和指针浮层使用 `.primaryDeepClick`。
- [系统 Force Click 功能](https://support.apple.com/en-gb/102309)：介绍查词、Finder 预览等系统行为。

## 跨 App 输入与接管

[Hammerspoon 文档](https://www.hammerspoon.org/docs/hs.eventtap.event.html#getTouchDetails) 介绍了先捕获 `gesture`，再转换为 Cocoa 事件读取压力信息的流程。相关源文件：

- [libeventtap_event.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap_event.m)：`eventtap_event_getTouchDetails` 将 CGEvent 包装成 NSEvent，读取压力事件的 `pressure`、`stage` 和 `stageTransition`。
- [libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)：创建 session event tap 并处理事件的放行与丢弃。

按刻参考这一流程独立实现：订阅 CG 手势事件（类型 29），转换为 NSEvent 后，只处理压力事件（类型 34）。获得权限后使用主动过滤，仅在相应 App 已启用“接管系统重按”时过滤重按阶段；普通点击和释放继续放行。[Apple 的 CGEventTapCallBack 文档](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)说明，主动过滤回调返回空值可以丢弃事件。

这些类型值来自公开 AppKit 常量。CGEventTap 对跨 App 压力事件的具体交付行为仍取决于系统环境；本机已验证 Edge 中的重按菜单和系统动作接管，其他系统、设备与 App 需要继续实测。

Hammerspoon 的[根许可证为 MIT](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE)。按刻没有复制其代码，也没有引入其 `newGesture` 使用的外部 GPL 手势合成依赖。项目未使用私有 `MultitouchSupport.framework`。

## 界面与动作

界面使用 AppKit 原生控件和 `NSVisualEffectView`，动画使用 Core Animation。系统开启“减少动态效果”时，菜单会减少缩放并缩短淡入淡出。

快捷键通过 Core Graphics 发往已确认的目标 App；应用和网址通过 `NSWorkspace` 打开；快捷指令通过 macOS 自带的 `shortcuts run` 运行。项目没有第三方运行时依赖。
