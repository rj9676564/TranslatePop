# TranslatePop

一个面向 macOS 的全局划词翻译弹窗工具。

它的目标是：

- 在任意软件中双击英文单词时快速翻译
- 在任意软件中按住拖选单词或句子后弹出翻译结果
- 以菜单栏常驻应用的方式工作，不依赖主窗口

当前项目基于 `SwiftUI + AppKit + macOS Accessibility` 实现，适合作为全局取词翻译工具的产品原型和后续迭代基础。

## 功能特性

- 菜单栏常驻应用
- 全局鼠标监听
- 双击取词
- 拖选取句
- 悬浮翻译弹窗
- 可配置第三方翻译接口
- 支持 OpenAI Compatible 与 Zhipu 两类接口
- 自动识别源语言并翻译为简体中文
- 自动过滤空白、纯标点、重复触发
- 设置页权限引导与接口连通性测试
- API Key 保存在 Keychain

## 当前交互规则

- 双击：翻译单词
- 按住并拖选后松开：翻译选中的单词或句子
- 普通单击：不会触发翻译
- 纯标点、纯空白、重复内容：不会触发翻译

## 取词策略

当前自动取词链路：

1. 辅助功能读取当前软件暴露的选中文本
2. 如果失败，尝试剪贴板回退

说明：

- OCR 识别能力目前仍保留在代码中，但用户入口已隐藏
- 当前版本不会在自动取词中使用 OCR

## 技术架构

核心模块如下：

- `TranslatePop/AppCoordinator.swift`
  应用协调器，负责权限刷新、全局监听、触发调度、翻译调用和弹窗展示
- `TranslatePop/SelectionCaptureService.swift`
  负责选中文本捕获，封装辅助功能和剪贴板回退策略
- `TranslatePop/TranslationService.swift`
  两层翻译服务设计：
  - 统一领域服务 `TranslationService`
  - 供应商适配层 `TranslationProviderAdapting`
- `TranslatePop/PopupPresenter.swift`
  负责悬浮弹窗展示、定位、自动消失和长文本滚动
- `TranslatePop/SettingsStore.swift`
  保存接口配置与应用偏好
- `TranslatePop/PermissionService.swift`
  负责权限检测、申请和跳转系统设置

## 运行环境

- macOS 15.7+
- Xcode 17+
- Swift 5

## 首次运行前准备

### 1. 打开项目

```bash
open TranslatePop.xcodeproj
```

或者使用命令行构建：

```bash
xcodebuild -project TranslatePop.xcodeproj -scheme TranslatePop -destination 'platform=macOS' build
```

### 2. 配置翻译接口

应用启动后，打开菜单栏图标，进入设置页，填写：

- `Provider 名称`
- `Base URL`
- `API Key`
- `Model（可选）`

说明：

- `Model` 可以留空
- 留空时会按供应商自动补默认值
- `API Key` 会写入 macOS Keychain

### 3. 配置权限

为了在其他应用中取词，你至少需要开启：

- `辅助功能`

说明：

- 自动取词依赖辅助功能权限
- 当前版本不要求必须开启屏幕录制权限
- 屏幕录制权限主要为后续 OCR 能力预留

## 接口配置示例

### Zhipu

- 供应商类型：`Zhipu`
- Base URL：
  `https://open.bigmodel.cn/api/paas/v4/chat/completions`
- Model：
  可以留空，默认会补 `glm-5`

### OpenAI Compatible

- 供应商类型：`OpenAI Compatible`
- Base URL：
  例如 `https://api.openai.com/v1`
- Model：
  可以留空，默认会补 `gpt-4.1-mini`

## 使用方式

1. 运行应用
2. 点击菜单栏图标打开设置页
3. 填写接口配置并保存
4. 授权辅助功能
5. 在任意软件中：
   - 双击单词
   - 或按住拖选文本
6. 在鼠标附近查看翻译弹窗

## 构建与测试

### Debug 构建

```bash
xcodebuild -project TranslatePop.xcodeproj -scheme TranslatePop -destination 'platform=macOS' build
```

### Release 构建

```bash
xcodebuild -project TranslatePop.xcodeproj -scheme TranslatePop -configuration Release -destination 'platform=macOS' build
```

### 运行测试

```bash
xcodebuild -project TranslatePop.xcodeproj -scheme TranslatePop -destination 'platform=macOS' test
```

## 打包

### 方式一：Xcode 图形界面

1. 打开 `TranslatePop.xcodeproj`
2. 选择 `TranslatePop` Scheme
3. 点击 `Product -> Archive`
4. 在 `Organizer` 中导出 `.app`

### 方式二：命令行构建产物

```bash
xcodebuild -project TranslatePop.xcodeproj -scheme TranslatePop -configuration Release -destination 'platform=macOS' build
```

生成的 `.app` 一般位于 `DerivedData/Build/Products/Release/` 下。

## 已知限制

- 不同应用对选中文本暴露程度不同，成功率会有差异
- 某些自绘控件、游戏窗口、特殊编辑器控件可能无法稳定读取选中文本
- 当前版本的 OCR 能力未开放给终端用户
- 智谱等第三方接口如果余额不足，会直接返回供应商错误
- 当前项目更适合站外分发，不适合直接走 Mac App Store 路线

## 权限说明

### 辅助功能

用途：

- 读取其他应用当前真正选中的文本
- 支持双击取词和拖选翻译

### 屏幕录制

用途：

- 为 OCR 截图识别预留

当前状态：

- 当前版本自动流程不依赖该权限

## 仓库结构

```text
TranslatePop/
├── TranslatePop/
│   ├── AppCoordinator.swift
│   ├── ContentView.swift
│   ├── Models.swift
│   ├── PermissionService.swift
│   ├── PopupPresenter.swift
│   ├── Protocols.swift
│   ├── SelectionCaptureService.swift
│   ├── SettingsStore.swift
│   ├── StatusBarController.swift
│   ├── TranslationService.swift
│   └── TranslatePopApp.swift
├── TranslatePopTests/
├── TranslatePopUITests/
└── TranslatePop.xcodeproj
```

## 后续可扩展方向

- 开放可控的 OCR 入口
- 全局快捷键触发翻译
- 历史记录与收藏
- 发音与词形分析
- 更丰富的供应商适配层
- 结构化翻译结果输出

## License

如需开源发布，建议补充正式的 License 文件。
