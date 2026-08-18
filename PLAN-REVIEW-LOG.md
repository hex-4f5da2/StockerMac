# Plan Review Log: 电报快讯模块（财联社 + 东财双数据源）

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Codex

VERDICT: REVISE — 21 条意见（摘要）：

1. sidebar 绑定只表达股票筛选，加 "telegraph" tag 无效果 → 引入 AppRoute enum，side bar/内容/详情/工具栏都从路由切换
2. 通知点击无共享目标：delegate 访问不到独立 VM；冷启动回调早于窗口存在 → router 存 pending route，didReceive 派发到 MainActor，窗口注册后消费
3. 通知只有 identifier/title/body → userInfo 加 route/source/消息复合 ID
4. 电报设置无持久化所有者：扩展 PersistedState 会与 AppStore.persist() 重建整个 blob 互相覆盖 → 独立版本化 TelegraphPreferences key
5. 独立 VM 拿不到自选股变化 → 注入 watchlist provider 或订阅 AppStore.items
6. start() 忽略磁盘数据 → 先加载缓存展示，再合并最新页，失败不清缓存
7. 存储并发：同步 store 阻塞 MainActor；off-main 非 actor 有丢失风险 → TelegraphStore 用 actor + 原子临时文件替换
8. 轮询只拉最新 50 条会漏掉睡眠/断网积压 >1 页的消息 → 反向补页直到 session 高水位，带截断和最大页数保护
9. "轮询任务拉到的"不是可靠通知边界（补拉与轮询重叠/切源）→ 每源 session 水位线，只通知严格新于 (ctime, stableID) 的记录，按时间序
10. 取消语义缺失：改间隔/切源后旧任务仍在写 → 单一生命周期协调器 + 代际 token + stop() + 每网络 await 后检查取消
11. 分页无进展检测/重复游标/限速/重试上限 → 游标必须前进、页指纹去重、上限页数、指数退避+抖动
12. 模型混入 provider 特有字段（level/category/stockList 未定义）→ provider DTO 分开解码，规范化模型（isRed、多 tag、标准化证券、真实 fixture）
13. 原始 ID 跨源可能冲突 → 身份 = source:remoteID
14. 东财"仅加红"当"全部"违反用户选择、可能炸几百条通知 → 不支持的加红过滤 = 不通知（或明确确认后改全部）
15. 通知授权失败被静默丢弃；电报默认模式可能永不请求权限 → 电报启用动作显式请求权限 + 暴露拒绝状态 + 打开系统设置
16. 按天分文件未定时区/时间单位/7天是否含今天 → 统一规范化时间戳，Asia/Shanghai 公历分天，保留 = 今天 + 前 6 天
17. 仅启动清理不适用于常驻 app → 每日最多一次清理（append 后或上海午夜）
18. JSONP/远端文本不可信无大小/字段限制 → 响应与字段上限、校验 HTTP 与业务错误码、精确剥离 wrapper
19. 无 schema 版本/损坏恢复 → 版本化 envelope、容错解码、隔离损坏文件、surface 存储错误
20. Tests 不会自动跑（Package.swift 无 test target）→ 加 test target 或显式编译执行
21. 设置窗口固定 480×350 会裁剪 → 去固定高度/可滚动

### Claude's response

全部采纳（21/21）。逐条落位到 PLAN 修订：

- 采纳 1–3：新增 `AppRoute`（all/market/group/positions/telegraph…），sidebar 选择、内容区、工具栏统一走路由；`AppRouter` 持有 pending route，`didReceive` 派发 MainActor 消费；NotificationService 增加 versioned `userInfo`（route/source/messageID）
- 采纳 4：`TelegraphPreferences` 独立 UserDefaults key（数据源/间隔/通知级别/最后查看时间），不与 AppStore 的 PersistedState 混写
- 采纳 5：TelegraphVM 注入 `WatchlistProvider`（AppStore 暴露 items 只读快照，@MainActor 订阅）
- 采纳 6：启动先读磁盘缓存渲染，再拉最新页增量合并；网络失败保留缓存并显示错误横幅
- 采纳 7：TelegraphStore 为 actor，序列化 append/load/purge，临时文件 + rename 原子写
- 采纳 8–11：轮询以 session 水位线（最新已见 (ctime,id)）为目标反向拉取，游标严格前进 + 页指纹去重 + 最大页数/重试上限 + 指数退避（基础 2s×2^n + 抖动）；补拉任务与轮询任务共用生命周期协调器，generation token 取消
- 采纳 12：`cls`/`eastmoney` 各自 DTO 解码 → 规范化 `TelegraphMessage`（id=source:remoteID、isRed、tags[]、stockList 标准化为市场前缀代码）；加红判定用真实 fixture 验证后锁定
- 采纳 13：身份一律 `source:remoteID`
- 采纳 14（修正我的原方案）：东财源「仅加红」「加红+自选股」中加红部分不通知（自选股命中仍通知），设置面板注明；不再降级为「全部」
- 采纳 15：进入电报模块/变更通知级别时显式 requestAuthorization；设置面板显示授权状态 + 「打开系统设置」按钮
- 采纳 16–17：时间戳统一为秒级 Unix，按 Asia/Shanghai 分天文件；保留 = 今天 + 前 6 天；每日最多一次清理（append 后检查）
- 采纳 18：响应上限 2MB、字段长度截断（content 4000 字符）、仅剥离精确 JSONP wrapper、校验业务错误码
- 采纳 19：文件外层版本化 envelope（{version:1, messages:[...]}），逐条容错解码，坏文件隔离改名不删除，存储错误 surface 到视图
- 采纳 20：Package.swift 新增 `.testTarget("StockerMacTests")`（纯 stdlib），`swift test` 可跑解析/存储/水位线/通知判定测试；README 记录命令
- 采纳 21：设置窗口去掉固定高度，Form 放入滚动容器

## Round 2 — Codex

VERDICT: REVISE — 16 条意见（摘要）：

1. .testTarget 不能指向现有 Tests/（多个 @main 独立程序）；CI 只有 swift build → 新测试放独立 XCTest 目录，声明 target path，CI 加 swift test
2. (ctime, id) 水位线不安全：同一秒内 id 不保证单调，后到但 id 小的消息会被丢弃 → 记 maxCtime + 该秒已见 id 集合
3. 10 页轮询上限会永久丢消息：旧水位线在 10 页之外时，新页到达后停在新的页首水位线，缺口不再拉 → 不 commit 新水位线直到命中旧水位线，跨周期保留 catch-up 游标，或报告不可恢复缺口
4. 持久化授权状态不可靠（系统设置可外部改）→ 启动/激活/设置展示时查 getNotificationSettings()，持久化仅为缓存
5. 进入电报视图就请求授权 = 不请自来的弹窗 → 仅当用户选择非关通知级别/点显式启用按钮时请求
6. AppRoute 与 AppStore 双状态会发散（selectedMarket/group/positions 仍由 AppStore 拥有）→ 路由作为唯一筛选状态，或提供原子 setter 同步现有字段
7. delegate 拿不到 AppRouter（@NSApplicationDelegateAdaptor 无 environment）→ 具体桥接（app 赋值回调或 @MainActor 静态注册表），并测冷启动通知
8. TelegraphVM 所有权/注入未定义（主场景 + Settings 都要用）→ StockerMacApp 一个 @StateObject，注入所有场景，coordinator 启动一次
9. 视图设计段落丢失 → 恢复：最新优先、搜索/分类本地过滤、稳定展开 ID、数据源控件、loading/error/empty 状态
10. 服务端分类请求污染全量轮询水位线/缓存不完整 → 只轮询缓存未过滤全量流，分类 chips 本地过滤或完全独立游标
11. CLS 分类/股票代码映射未验证就决定 UI 与通知 → 每能力用 verified fixture 后才启用，不支持的过滤可见标记
12. 单一"最后查看时间"跨两源不够 + 秒级碰撞 → per-source last-seen 水位线（时间戳+边界 id 集），未读数由此派生
13. 东财 wrapper 语法未锁定 → 解析器锁定实际 fixture（赋值前缀+JSON 对象+可选分号）
14. NotificationService 用 try? 吞错 → send 抛错/返回 Result，通知错误与 feed/存储错误分开展示
15. 4000 字截断与"展开完整正文"矛盾 → 响应限制内保留完整正文，超限可见标记 + 源 URL
16. `~` 不会被 Foundation 展开 → FileManager.urls(for:.applicationSupportDirectory)，测试注入临时 base URL

### Claude's response

全部采纳（16/16），关键修订：

- 采纳 1：新测试放 `Tests/StockerMacTests/` 独立 XCTest 目录（不碰现有 @main 检查程序），Package.swift 声明 testTarget path，CI 加 `swift test`
- 采纳 2/12：通知水位线与 lastSeen 统一为 per-source `(maxCtime, Set<id>@maxCtime)`，未读数由此派生
- 采纳 3：轮询不 commit 新水位线直到命中旧水位线；跨周期保留 catch-up 游标，连续多轮无法收敛则报告缺口横幅
- 采纳 4：授权状态启动/激活/设置展示时实时查询 `getNotificationSettings()`，UserDefaults 仅缓存
- 采纳 5：授权请求仅发生在用户选择非「关」通知级别时
- 采纳 6（结构调整）：放弃独立 AppRoute/AppRouter——路由状态并入 AppStore（新增 `showingTelegraph`，原子 setter 沿用 selectAll 体系），单一状态源无发散；工具栏/内容区据此切换
- 采纳 7：通知点击桥沿用项目已有 `MainWindowRegistry` 静态注册表模式：@MainActor `PendingNotificationRouter` 静态持有 pending 动作，didReceive 写入，窗口/电报 VM 就绪后消费（含冷启动场景）
- 采纳 8：`StockerMacApp` 一个 `@StateObject` TelegraphVM，注入主场景与 Settings，coordinator 恰启动一次
- 采纳 9：恢复完整视图章节（最新优先、搜索/分类本地过滤、稳定展开 ID、数据源控件、loading/error/empty 状态）
- 采纳 10：只轮询/缓存未过滤全量流；分类 chips 全部本地过滤（加红用 isRed，其余分类字段在 DTO 中保留原始 tag 判定）；不做服务端分类请求，杜绝游标污染
- 采纳 11：加红/自选股匹配/分类显示用 verified fixture 后才启用，不支持的过滤显示为禁用态
- 采纳 13：东财解析器锁定实测 fixture（`var ajaxResult=` 前缀 + JSON 对象 + 可选尾部 `;`）
- 采纳 14：NotificationService.send 改为 `throws`，电报模块单独展示通知错误
- 采纳 15：content 完整保留（响应 2MB 上限内），超限才截断且可见标记 + 提供源 URL
- 采纳 16：存储目录用 `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`，TelegraphStore 注入 baseURL 供测试

## Round 3 — Codex

VERDICT: REVISE — 15 条意见（摘要）：

1. lastSeen 过载：既是轮询水位线又是已读水位线；进入视图推进 ingestion 会吞掉 catch-up 消息 → 分离 pollWatermark / 不可变 catchUpTarget / 持久化 readWatermark（per source）
2. 东财跨轮询持久化页码不安全（新消息插入移动所有后续页）→ 用 item-ID anchor + 重叠重扫恢复，绝不裸页码；测 catch-up 间插入
3. 10 页上限缺口行为未定义（水位线是否推进/通知是否重复）→ 收敛前保留旧水位线，或显式 rebaseline 不通知 + 记录 data-gap 状态
4. 默认级别非「关」但授权只在用户"选择"时请求 → 新用户永不触发 → 显式「启用通知」CTA，授权只从该动作请求
5. testTarget 缺 dependencies → .testTarget(name: "StockerMacTests", dependencies: ["StockerMac"], path: ...) + @testable import
6. 测试未覆盖最险机制 → 注入 service/clock 的确定性测试：东财页移动、generation 取消、中断补拉、切源、暂停/恢复、冷启动路由
7. didReceive 是 nonisolated，不能直接改 @MainActor 静态 router → Task { @MainActor in ... } 派发
8. 电报模式第三列 InspectorView 未定义 → content + detail 同时替换（detail 显示选中消息详情）或独立两列 NavigationSplitView
9. DTO 原始字段不持久化 → 缓存消息重启丢分类 → TelegraphMessage 持久化规范化 Set<TelegraphCategory>，过滤只基于持久化字段
10. 首次激活源时历史算未读 → 初始 merge 后 bootstrap readWatermark，历史补拉不计未读
11. 暂停/恢复语义未定义 → 明确：暂停积压消息不通知（恢复静默合并推进），策略进水位线测试
12. 2MB 策略矛盾（模型说截断/服务说抛错；截断 JSON 不可解析）→ 响应超限整体拒绝；字段级超限才截断并标记
13. 源 URL 来自不可信数据无校验 → 仅打开 HTTPS + provider host 白名单
14. .corrupt sidecar 无限积累 → 同样按 7 天保留策略清理
15. 关联股票跳转对不在自选列表的代码无效 → 仅自选内直接导航，未知代码走搜索/添加确认

### Claude's response

全部采纳（15/15）：

- 采纳 1/10/11：per-source 三水位线（pollWatermark、catchUpTarget、readWatermark）；首次 merge 后 bootstrap readWatermark；暂停 = 积压不通知、恢复静默推进
- 采纳 2：东财轮询同样用"已见最新 id 锚点 + 重叠重扫"（与财联社 last_time 语义对齐），弃页码恢复
- 采纳 3：缺口未收敛不推进 pollWatermark（不重复通知），data-gap 横幅；收敛前按旧水位线持续重试
- 采纳 4：电报视图顶栏「启用通知」CTA（默认级别仍为仅加红但未授权前不发），授权仅从 CTA 触发
- 采纳 5：testTarget 显式 dependencies: ["StockerMac"] + @testable import
- 采纳 6：测试清单扩展：东财页移动插入、generation 取消、中断补拉恢复、切源、暂停/恢复、冷启动路由（注入 service/clock）
- 采纳 7：didReceive 先 completionHandler 再 Task { @MainActor in ... }
- 采纳 8：电报模式下 content + detail 双列替换（detail 显示选中电报详情）
- 采纳 9：TelegraphMessage 持久化 Set<TelegraphCategory> 规范化字段，过滤只基于持久化字段
- 采纳 12：响应 >2MB 整体拒绝；字段超限截断 + 标记
- 采纳 13：外链仅 HTTPS + 白名单 host（cls.cn / eastmoney.com）
- 采纳 14：.corrupt sidecar 纳入 7 天清理
- 采纳 15：关联股票仅自选内可跳，未知走搜索/添加确认

## Round 4 — Codex

VERDICT: REVISE — 9 条意见（摘要）：

1. pollWatermark 持久化与"仅通知轮询期间到达"矛盾：重启/暂停后新会话会通知积压消息 → 会话通知水位线不持久化，启动/切源/恢复时静默 bootstrap；持久化独立 fetch/read marker
2. 东财"已见最新 id 锚点"歧义：锚最新 id 会让游标停在第一页 → 锚定**最老**已见 id + 重叠扫描 + 精确前进规则
3. provider 不再保留旧水位线时"持续重试"会永久 data-gap → 有界年龄/尝试阈值后标记不可恢复，静默 rebaseline + 可见警告
4. 启动补拉与轮询并发未串行化 → 单 per-source coordinator 状态机（bootstrap/latest merge/backfill/poll 全走一个）
5. 通知非崩溃幂等：发送成功未 commit 水位线崩溃 → 重发；先 commit 后发送失败 → 丢失 → 明确"发送成功→推进"事务顺序 + 崩溃等价中断测试
6. 通知点击缺选中状态契约 → selectedTelegraphMessageID + ScrollViewReader/展开 handoff，数据就绪才消费 pending
7. 东财 3 天补拉可能 ~90 页，仅轮询有上限 → 补拉独立 deadline/页数/重试预算/取消 + 部分历史状态
8. FileManager.moveItem 目标已存在会失败，不原子 → POSIX rename(2) 或 FileManager.replaceItem + 覆盖已有日文件测试
9. executable target @testable import 可能被 SwiftPM 拒绝 → 确认 CI 或把 models/services/coordinators 拆到可测试 library target

### Claude's response

全部采纳（9/9），其中两项引起结构修订：

- 采纳 1：会话通知水位线（session watermark）不持久化——启动/切源/恢复静默 bootstrap 到已见最新；持久化 fetch marker（续拉）与 read marker（未读）分开
- 采纳 2：东财锚定最老已见 id 边界 + 重叠扫描 + 精确前进规则（老边界单调推进）
- 采纳 3：data-gap 有界（如 3 轮尝试或 5 分钟）→ 不可恢复缺口警告 + 静默 rebaseline
- 采纳 4：单 per-source coordinator 状态机串行化全部拉取（bootstrap/merge/backfill/poll），generation token 覆盖
- 采纳 5：事务顺序锁定「fetch → 通知成功（throws 通过）→ 推进 session watermark → 持久化 fetch marker」；崩溃等价测试覆盖
- 采纳 6：`selectedTelegraphMessageID` + ScrollViewReader handoff，pending 在数据就绪后消费
- 采纳 7：补拉独立预算（≤60 页/源/次 + 30s 上限），超限标记部分历史（视图注明）
- 采纳 8：原子写改用 POSIX `rename(2)`（via Darwin）/ `FileManager.replaceItem`，测试覆盖覆盖已有日文件
- 采纳 9（结构修订）：新增 `.library(target: "StockerCore")`——Telegraph 的 models/service/store/preferences/viewmodel 全部放入 `Sources/StockerCore/`；`StockerMac` executable 依赖 StockerCore；tests 依赖 StockerCore（纯 library，@testable 无 SwiftPM 限制）。watchlist 依赖抽象为 `protocol WatchlistProviding { var watchlistCodes: Set<String> { get } }`（AppStore 扩展实现），TelegraphViewModel 只依赖协议，不依赖 AppStore

## Round 5 — Codex

VERDICT: REVISE — 7 条意见（摘要）：

1. 轮询算法方向混述："以最老已见 id 为锚反向拉取"对轮询不正确/含糊 → 轮询 = 最新→旧直到 session 边界；补拉 = 从 fetchMarker 往更旧走；两游标分开定义
2. 通知事务不能统一"send 成功"路径：关级别/东财加红/权限拒绝（suppressed）也要推进边界；单条 send 失败不能导致已发送消息重复 → per-record outcome（sent/suppressed/failed），sent+suppressed 推进，failed 只重试
3. session bootstrap 若来自陈旧磁盘缓存（首轮网络失败时），连通后会通知会话前消息 → bootstrap 只从成功的最新 feed 响应建立；成功前禁用通知处理
4. WatchlistProviding.watchlistCodes 无统一标识契约（消息用市场前缀码，WatchItem 用 00700/AAPL 等）→ 定义 SecurityID 统一格式（含市场），provider 列表与 watchlist 快照同格式 + CN/HK/US 规范化测试
5. WatchlistProviding 未标注 Swift 6 隔离/Sendable；@MainActor AppStore 见证可能不满足 nonisolated 要求 → 协议 @MainActor 或返回 Sendable 快照；注入的 service 协议 Sendable
6. 长期断网后 fetchMarker 可能超出 provider 保留历史 → gap rebaseline 必须原子替换 fetchMarker + 持久化 gap 状态，否则反复发现同一缺口
7. 通知点击时消息已被清理/源缓存无此消息 → detail 显示「消息已不可用」+ 保留源 URL，pending 不悬挂

### Claude's response

全部采纳（7/7）：

- 采纳 1：双游标明确：pollCursor（最新→旧，锚 session 边界）与 backfillCursor（fetchMarker → 更旧），在 coordinator 状态机中分状态实现
- 采纳 2：per-record outcome 枚举（sent/suppressed/failed）；suppressed（关级别、东财加红、权限拒绝）计入推进；failed 记入重试队列（下次轮询重试，限次后放弃并 surface）
- 采纳 3：session 通知边界仅由成功的最新 feed 响应 bootstrap；首次网络成功前通知处理不启用
- 采纳 4：新增 `SecurityID`（market + code 规范化，如 `CN:600000` / `HK:00700` / `US:AAPL`），provider stockList 与 watchlist 快照统一为该格式，规范化测试覆盖三市场
- 采纳 5：`WatchlistProviding` 标 `@MainActor` 并返回 `Sendable` 快照；`TelegraphServiceProviding` 协议标 `Sendable`，测试 fake 安全跨 actor
- 采纳 6：gap rebaseline 原子执行：持久化 gap 状态 + 替换 fetchMarker，防反复发现同一缺口
- 采纳 7：pending 消费时消息缺失 → detail 显示「消息已不可用」+ 源 URL 可点

## Act 3 — Build（Claude 实现，已交付）

按 Rev 6 完成全部实现并验证：

**交付内容**
- `Package.swift`：新增 `StockerCore` library（Telegraph 全部逻辑）+ executable 依赖
- `Sources/StockerCore/`：TelegraphModels（含 SecurityID 规范化）/ TelegraphService（财联社+东财）/ TelegraphStore（actor 按天文件+rename 原子写）/ TelegraphPreferences（独立 key）/ TelegraphViewModel（三水位线+coordinator+per-record 通知事务）
- `Sources/StockerMac/`：AppStore 路由（showingTelegraph）/ NotificationService throws+userInfo / PendingNotificationRouter / StockerMacApp 注入与冷启动消费 / TelegraphView + TelegraphDetailView / ContentView sidebar 电报入口 / SettingsView 电报段
- `Tests/TelegraphChecks.swift`：44 项检查全部通过（swiftc 手动编译，延续项目模式；环境无 XCTest，未采用 testTarget，CI 已加编译运行步骤）

**实现中的两个关键修正（超出 plan 的发现）**
1. 签名输入修正：网页前端 `n.sync()` 返回 SHA-1 **原始字节**（非 hex 字符串），md5 作用于字节——固定向量测试锁死（与实测签名一致）
2. 接口迁移：财联社 `/v1/roll/get_roll_list` 在实现期间被服务端风控（10012 签名错误，前端 JS 未更新但服务端校验变化）；逆向网页 30s 轮询逻辑后发现主接口实为 `/api/cache`（`lastTime`/`last_time` 双参数名语义：最新页用当前时间戳、翻页用最老 ctime 闭区间），已切换并实测通过（无需 cookie）

**验证结果**
- swift build：通过
- .build/telegraph-checks：44/44 通过（签名固定向量 / 两源 fixture 解析 / SecurityID / 存储 roundtrip+原子覆盖+7天清理+corrupt 隔离+时区分天 / 水位线同秒碰撞 / 通知事务 sent/suppressed/failed）
- 真实接口冒烟：财联社 20 条实时电报 ✓、东财 50 条实时快讯 ✓
