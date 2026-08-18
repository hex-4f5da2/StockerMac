# Plan: 电报快讯模块（财联社 + 东财双数据源）

_Locked via grill — by Claude + 用户 · Rev 6 (Codex R1: 21/21, R2: 16/16, R3: 15/15, R4: 9/9, R5: 7/7 采纳 · 5 轮评审全部收敛，无未决分歧)_

## Goal

在 StockerMac macOS 应用中新增「电报」快讯模块：以财联社电报为主数据源、东方财富 7×24 快讯为可切换备选；侧边栏新增「电报」入口，主区域展示快讯时间线（分类栏 + 搜索 + 展开正文）；按可配置间隔（10/30/60 秒，默认 30 秒）轮询新消息并发送系统通知（通知级别：全部 / 仅加红 / 加红+自选股 / 关，默认仅加红，显式 CTA 开启）；数据按天分文件持久化于 Application Support，保留 7 天（今天 + 前 6 天）自动清理；首次运行先显示磁盘缓存/最新一页，后台静默补拉最近 3 天历史（历史消息不通知）。

## Approach

0. **Target 结构**（Package.swift）
   - 新增 `.library(name: "StockerCore")`：Telegraph 的 models / service / store / preferences / viewmodel 全部放 `Sources/StockerCore/`
   - `StockerMac` executable 依赖 StockerCore；新增 `.testTarget("StockerMacTests", dependencies: ["StockerCore"], path: "Tests/StockerMacTests")`；CI 加 `swift test`；README 记录
   - watchlist 依赖：`@MainActor protocol WatchlistProviding` 返回 `Sendable` 快照（`[SecurityID]`），AppStore 扩展实现；`TelegraphServiceProviding` 协议标 `Sendable`
1. **模型** `Sources/StockerCore/Models/TelegraphModels.swift`
   - `TelegraphSource`（`cls` / `eastmoney`）
   - `SecurityID`：统一标识（market + code，如 `CN:600000` / `HK:00700` / `US:AAPL`），provider stockList 与 watchlist 快照同一格式，CN/HK/US 规范化测试
   - 规范化 `TelegraphMessage`：`id = "source:remoteID"`、ctime（秒级 Unix）、title、content（字段级超限截断 + 标记；响应 >2MB 整体拒绝）、isRed、**categories: Set<TelegraphCategory>（持久化规范化字段）**、stockList: [SecurityID]、readingNum、url、source
   - `TelegraphCategory`（财联社 7 分类）、`TelegraphNotificationLevel`（全部/仅加红/加红+自选股/关）
2. **服务层** `Sources/StockerCore/Networking/TelegraphService.swift`（actor，`TelegraphServiceProviding` 协议化，`Sendable`）
   - 财联社：`GET https://www.cls.cn/v1/roll/get_roll_list`，签名 `sign = md5(hex(sha1(参数按字典序扁平串)))`（已实测），固定 `os=web&sv=8.7.9&app=CailianpressWeb`，Referer `https://www.cls.cn/telegraph`；`last_time` 分页；DTO 单独解码 → 规范化（isRed/分类映射 fixture 验证后锁定）
   - 东财：`GET https://newsapi.eastmoney.com/kuaixun/v1/getlist_102_ajaxResult_50_{page}_.html`，JSONP 剥离锁定实测 fixture（`var ajaxResult=` 前缀 + JSON 对象 + 可选 `;`）
   - 防护：响应 >2MB 整体拒绝、HTTP/业务错误码校验、失败抛错
3. **持久化** `Sources/StockerCore/Persistence/TelegraphStore.swift`（actor，baseURL 注入）
   - 目录：`FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` + `/Stocker/`
   - 按天分文件（Asia/Shanghai 分天）：`telegraph-{source}-YYYYMMDD.json`，版本化 envelope
   - 串行 append/load/purge；原子写用 POSIX `rename(2)` / `FileManager.replaceItem`；逐条容错解码，坏记录隔离；`.corrupt` sidecar 纳入 7 天清理；存储错误 surface
   - 保留 = 今天 + 前 6 天；append 后检查，每日最多清理一次
4. **偏好** `Sources/StockerCore/Persistence/TelegraphPreferences.swift`：独立 UserDefaults key（数据源、间隔、通知级别、per-source fetch marker/read marker、gap 状态、授权状态缓存），**不与 PersistedState 混写**
5. **ViewModel** `Sources/StockerCore/App/TelegraphViewModel.swift`（@MainActor ObservableObject）
   - 所有权：`StockerMacApp` 一个 `@StateObject`，注入主场景 + Settings，coordinator 恰启动一次
   - **水位线/游标体系（per source）**：
     - `sessionWatermark`（内存）：通知边界，**仅由成功的最新 feed 响应 bootstrap**（首轮网络成功前通知处理不启用，杜绝陈旧缓存 bootstrap）
     - `fetchMarker`（持久化）+ `backfillCursor`：续拉断点，向更旧方向走
     - `pollCursor`：轮询游标，最新→旧反向拉取直到命中 session 边界
     - `readMarker`（持久化）：已读/未读边界；首次 merge 后 bootstrap
   - 启动：读磁盘缓存立即渲染 → 拉最新页增量合并（失败保留缓存 + 错误横幅）
   - 补拉：缓存不足 3 天时后台补拉（独立预算 ≤60 页/源/次、30s deadline、可取消），超限标记部分历史；历史不通知
   - **单 per-source coordinator 状态机**：bootstrap / latest merge / backfill / poll 串行化 + generation token；间隔/切源/暂停取消旧任务，每个网络 await 后检查取消
   - 轮询防护：页指纹去重 + 单轮最大 10 页 + 重试 3 次 + 指数退避（2s ×2^n + 抖动）；缺口有界（3 轮或 5 分钟）→ **gap rebaseline 原子执行：持久化 gap 状态 + 替换 fetchMarker**（防反复发现同一缺口）+ 可见警告
   - **暂停语义**：暂停积压不通知，恢复静默合并推进
   - **通知事务（per-record outcome）**：每条记录标记 `sent` / `suppressed`（关级别、东财加红、权限拒绝）/ `failed`；sent + suppressed 推进 sessionWatermark，failed 入重试队列（下次轮询重试，限次后放弃并 surface）；事务顺序 fetch → 判定/发送 → 推进 → 持久化 marker
   - 通知匹配：仅加红 = `isRed`；加红+自选股 = `isRed ∨ stockList ∩ watchlist ≠ ∅`；**东财源加红维度不通知**（自选股命中仍通知），设置注明
   - 授权：显式「启用通知」CTA 才 requestAuthorization；展示时实时查 `getNotificationSettings()` + 「打开系统设置」
   - 未读角标：readMarker 派生；`selectedTelegraphMessageID` + ScrollViewReader/展开 handoff；**pending 消费时消息缺失 → detail 显示「消息已不可用」+ 源 URL 可点**
6. **路由与集成**
   - 路由并入 AppStore：`showingTelegraph` 原子 setter（与其他选择互斥）
   - 电报模式 content + detail 双列替换（detail 显示选中电报完整详情）
   - 通知点击桥：@MainActor `PendingNotificationRouter` 静态注册表：`didReceive` 先 completionHandler 再 `Task { @MainActor in ... }` 写入 pending（source + messageID），窗口/VM 就绪后消费（含冷启动）
   - `NotificationService.send` 改 `throws` + versioned `userInfo`（source、messageID）
   - `SettingsView` 新增「电报」段（间隔 10/30/60、通知级别、数据源、授权状态+打开系统设置、启用通知 CTA），去固定高度改可滚动
   - 外链：仅 HTTPS + host 白名单（cls.cn / eastmoney.com）
7. **视图** `Sources/StockerMac/Views/TelegraphView.swift`
   - 顶栏：数据源下拉 + 搜索框 + 暂停/恢复 + 补拉进度 + 启用通知 CTA
   - 分类栏：仅财联社源，7 分类 chips 本地过滤（基于持久化 categories；判定不了禁用态）
   - 列表：最新优先；时间 `HH:mm` + 粗体标题（无标题取正文首句）+ 两行摘要；加红红点；行内展开（稳定展开 ID 集）
   - 关联股票：仅自选内直接跳转，未知代码走搜索/添加确认
   - 状态：loading / error（feed/存储/通知分开）/ empty / data-gap / 部分历史 各类横幅与占位
8. **测试** `Tests/StockerMacTests/`（XCTest，注入 service/clock）
   - 用例：签名固定向量、两源 fixture 解析（JSONP wrapper 边界）、isRed/分类映射、SecurityID CN/HK/US 规范化、存储 roundtrip（临时 baseURL）+ rename 覆盖已有日文件、7 天清理（时区边界 + .corrupt sidecar）、水位线（同秒碰撞、session bootstrap 仅网络成功、东财页移动插入）、通知事务（sent/suppressed/failed、崩溃等价）、generation 取消、中断补拉恢复、切源、暂停/恢复、gap rebaseline、冷启动路由、pending 消费消息缺失

## Key decisions & tradeoffs

- **财联社签名逆向**：`md5(sha1(参数扁平串))` 来自网页前端 JS 逆向（实测 200 + errno:0）。脆弱点：算法更换/CloudWAF 升级 → 错误横幅，不自动降级，手动切东财
- **轮询仅限 app 运行时**：菜单栏 app 无后台常驻保证
- **通知默认「仅加红」+ CTA 开启**：全量一天 300–500 条会轰炸；未授权前不通知
- **东财降级**：无分类栏；「仅加红」加红维度不通知（尊重"想安静"）
- **session watermark 仅由网络成功 bootstrap**：重启/暂停/首轮失败均不补发积压通知
- **per-record outcome 事务**：suppressed 与 sent 同权推进，failed 重试，通知不重不漏
- **双游标 + 单 coordinator 状态机**：poll/backfill 方向明确、串行化，杜绝并发竞争
- **拆 StockerCore library**：可测试（executable @testable 有 SwiftPM 限制）；WatchlistProviding @MainActor + Sendable 快照，Swift 6 隔离安全
- **按天分文件 + envelope + rename 原子写 + .corrupt 清理 + gap 状态持久化**：清理、原子性、恢复路径均有真实保证
- **不引入 SQLite/第三方依赖**：延续项目零依赖风格

## Risks / open questions

- 财联社 isRed/分类映射依赖真实 fixture 验证；stockList → SecurityID 映射规则用真实数据确认
- 东财历史可能不足 3 天（按实际存，注明）；补拉预算超限标记部分历史
- 通知授权被拒：展示状态与跳转，不反复打扰
- 签名逆向长期稳定性：财联社改算法时电报降级为只读历史（错误横幅），等人工跟进

## Out of scope

- 历史数据回测（用户明确排除）
- 消息图片/视频渲染（本次仅文本，后续可加）
- 点赞/评论/分享互动
- 语音电报、独立声音/横幅开关（跟随系统通知设置）
- 后台常驻轮询
