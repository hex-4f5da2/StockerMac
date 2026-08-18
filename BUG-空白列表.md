# Bug 报告：⌘W 关闭窗口后重新打开，中间股票列表空白

## 现象

1. 主窗口打开，股票列表正常显示（179 行）
2. 按 `⌘W`（被 `StockerApplication.sendEvent` 拦截 → `MainWindowRegistry.collapse()` → `window.orderOut(nil)`）
3. 重新打开窗口（Dock 点击触发 `applicationShouldHandleReopen` → `makeKeyAndOrderFront` + `restoreFrame`）
4. **中间股票列表区域空白**（ScrollView 区域），但以下区域**全部正常**：
   - 顶部指数卡片、搜索框
   - 左侧边栏（导航 + 分组网格，也是 ScrollView 结构）
   - 右侧详情面板
5. 空白**持续存在**：等待 10 秒不恢复、最小化再恢复不恢复
6. 复现率：在 `/Applications/Stocker.app`（release 打包版）多次复现

## 关键证据（调试日志 + 截图对比）

在 `DashboardView.body` 和 `QuoteTable` 的 `GeometryReader` 内加了文件日志：

```
[stock-debug] body rows=179 all=179 ung=false pos=false grp=nil tel=false sel=nil
[stock-debug] table rows=179 geo=(737.5, 563.0)
```

- **数据层完全正常**：`store.rows` = 179，所有筛选状态正常
- **布局层完全正常**：QuoteTable 的 GeometryReader 尺寸 737×563（正常），`body` 在 reopen 后**持续被调用**（SwiftUI 认为视图活跃）
- **但屏幕显示空白** → 视图树在渲染，画面没有提交（Core Animation 层问题）

## 已尝试的修复（均无效）

| 尝试 | 结果 |
|------|------|
| 移除 `LazyVStack(pinnedViews: [.sectionHeaders])`，改普通 Section 结构 | ❌ 无效 |
| `LazyVStack` → 普通 `VStack`（非懒加载） | ❌ 无效（用户确认仍复现） |
| 等待 10 秒 / 最小化恢复 | ❌ 不恢复 |

## 排除的假设

- ~~数据/状态问题~~：rows=179 正常
- ~~布局尺寸问题~~：geo=737×563 正常
- ~~LazyVStack 懒加载失效~~：换成 VStack 仍空白
- ~~pinned section header~~：移除仍空白
- 侧边栏 ScrollView 正常 → 不是所有 ScrollView 都受影响

## 高度怀疑的方向

1. **`MainWindowRegistry.collapse()` 的窗口管理方式**：`orderOut(nil)` 隐藏窗口。SwiftUI 的 hosting view 在窗口 orderOut 后其 `CAMetalLayer`/layer-backed view 可能失效，恢复时 **layer 内容没有重新提交**。这是"body 执行但画面不更新"最吻合的解释。
   - 建议验证：空白状态下 `CGWindowListCopyWindowInfo` 查该窗口的 layer；或用 `window.displayIfNeeded()` / `contentView?.layer?.setNeedsDisplay()` 手动触发重绘看是否恢复。
2. **`restoreFrame()` 的时序竞争**：
   ```swift
   static func restoreFrame() {
       window.setFrame(frameBeforeCollapse, display: true)
       DispatchQueue.main.async { window.setFrame(frameBeforeCollapse, display: true) }
   }
   ```
   reopen 时 `makeKeyAndOrderFront` 与 `setFrame` 的竞争可能导致窗口以异常状态显示。
3. **`WindowModeResizer(mode: .fullSize)`**（`CompactGroupView.swift:188`）：`updateNSView` 中 `guard appliedMode != mode` —— 若视图树重建（Coordinator 重置），会强制 `setContentSize(1280×780)` + `contentMinSize(1060×680)`，与当前窗口尺寸（默认 1000×640、min 900×600）冲突，可能引发布局/合成异常。
4. **⌘W 拦截的发送时机**：`sendEvent` 拦截发生在 AppKit 层，`orderOut` 时窗口可能处于 key 状态，`NSApp.keyWindow` 变化后 SwiftUI 场景状态（scenePhase/window）未同步。

## 建议的修复路径（按优先级）

1. **改变隐藏方式**：`collapse()` 不用 `orderOut`，改用：
   - `window.setIsVisible(false)` 或 `window.alphaValue = 0` + `isMovableByWindowBackground` 移出屏幕，或
   - `window.miniaturize(nil)`（最小化到 Dock，系统保证恢复重绘）
2. **恢复时强制重绘**：`makeKeyAndOrderFront` 后加 `window.displayIfNeeded()`、`window.contentView?.needsDisplay = true`、或触发一次 `window.setFrame`（display: true）。
3. **验证 layer**：空白时用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` 检查窗口 layer 状态，确认是否合成层丢失。
4. **兜底方案**：若确认是 SwiftUI + orderOut 的合成 bug，可在 `applicationShouldHandleReopen` 里重建 ContentView 根视图（切换 `.id`）强制 SwiftUI 重绘。

## 复现脚本（已可自动化）

```bash
# 1. 前置 Stocker
osascript -e 'tell application "System Events" to tell process "StockerMac" to set frontmost to true'
# 2. ⌘W
osascript -e 'tell application "System Events" to tell process "StockerMac" to keystroke "w" using command down'
# 3. 重新打开（触发 applicationShouldHandleReopen）
osascript -e 'tell application "Stocker" to reopen'
# 4. 截图验证（需要屏幕录制权限）
screencapture -x /tmp/check.png
```

## 当前代码状态

- `Sources/StockerMac/App/StockerMacApp.swift`：`StockerApplication.sendEvent`（⌘W 拦截）、`MainWindowRegistry`（collapse/restoreFrame）、`applicationShouldHandleReopen`
- `Sources/StockerMac/Views/DashboardView.swift`：QuoteTable 已改为 `VStack`（非懒加载）
- `Sources/StockerMac/Views/CompactGroupView.swift:188`：`WindowModeResizer`（窗口尺寸管理）
