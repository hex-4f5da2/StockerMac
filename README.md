# Stocker for macOS

独立的 macOS 原生股票行情客户端。使用 Swift、SwiftUI 和 AppKit 构建，通过新浪财经与腾讯财经行情接口获取数据，不依赖 JetBrains 插件代码。

## 当前功能

- A 股、港股、美股自选列表
- 行情与自定义分组顶部展示上证、深证、科创、创业、北证五类指数；持仓摘要仅在“我的持仓”展示
- 自定义分组、拖拽/名称排序、多分组归属和未分组筛选
- 分组平均涨跌幅每变动 1 个百分点发送系统通知
- 个股目标价格通知，按设置时现价自动判断涨到/跌到且仅当日有效
- 菜单栏轮播持仓行情，点击后精简展示股票名称、现价和涨跌幅
- 菜单栏待机支持“股票名 + 涨跌幅”轮播或浅色 Stocker 图标
- 独立行情图窗口：A 股支持分时、五日、1/5/15/30/60/120 分钟及日/周/月/年 K；港股、美股支持日/周/月/年 K，并展示成交量、均线、MACD 和可用行情概览
- 小窗模式：进入前选择分组，仅展示股票名称和涨跌幅，支持窗口置顶
- 新浪 / 腾讯双数据源切换
- 电报快讯模块：财联社 / 东方财富 / 金十 A股三数据源一键切换，10/30/60 秒轮询，按“全部 / 仅重要 / 重要+自选股 / 关”发送系统通知（默认仅重要），本地分类筛选、搜索、日期分组、未读标记、关联股票跳转，数据按天持久化保留 7 天
- 股票代码、名称、拼音搜索
- “全部自选”支持按股票名称或代码即时筛选
- 使用英文逗号一次查询并批量添加多只股票
- 按当前市场或分组批量选择、搜索并删除股票，删除前二次确认
- 5–60 秒自动刷新、手动刷新和暂停
- 成本价、持仓数量、今日盈亏、累计盈亏
- 支持单只股票清仓，自动保留成本、数量、清仓价和时间历史
- 红涨绿跌 / 绿涨红跌 / 单色模式
- 本地持久化，无需账号
- 快捷键：`⌘E` 打开选中股票行情图，`⌘W` 关闭行情图/收起主窗口，`⌘D` 添加股票，`Esc` 关闭添加窗口

## 运行

需要 macOS 14+ 与 Xcode 16+。克隆仓库后，可以在 Xcode 中直接打开 `Package.swift`，选择 `StockerMac` scheme 运行；也可以使用命令行：

```bash
swift run StockerMac
```

编译检查：

```bash
swift build
```

生成可双击运行的 `.app`（输出到 `dist/Stocker.app`）：

```bash
./Scripts/build-app.sh
open dist/Stocker.app
```

## 项目结构

```text
StockerMac/
├── App/                 # Info.plist 与应用图标
├── Scripts/             # 应用打包脚本
├── Sources/StockerMac/  # SwiftUI 应用源码与状态栏逻辑
├── Tests/               # 解析、分组、批量操作和真实接口检查
└── Package.swift        # Swift Package 配置
```

项目没有依赖第三方 Swift Package，行情数据和用户配置均由应用直接处理。

在只有 Command Line Tools、没有完整 Xcode 测试框架的环境中，可以直接执行解析器检查：

```bash
swiftc Sources/StockerMac/Models/StockModels.swift \
  Sources/StockerMac/Networking/QuoteParser.swift \
  Tests/ParserChecks.swift -o .build/parser-checks
.build/parser-checks
```

仓库还附带了 `Tests/LiveAPIChecks.swift`，用于对两个真实行情源做端到端检查。

电报模块检查（签名、双数据源解析、存储、水位线、通知事务）：

```bash
swiftc -parse-as-library Sources/StockerCore/Models/*.swift \
  Sources/StockerCore/Networking/*.swift \
  Sources/StockerCore/Persistence/*.swift \
  Sources/StockerCore/App/*.swift \
  Tests/TelegraphChecks.swift -o .build/telegraph-checks
.build/telegraph-checks
```

> 电报数据来自财联社与东方财富公开接口。财联社接口签名（`md5(sha1(参数扁平串))`）由网页前端逆向而来，若官方调整签名或启用风控（当前状态：仅返回最新约 20 条、历史翻页受限），电报模块会显示错误横幅并保留历史数据，可手动切换另一数据源（东方财富不受影响）。公开接口可能调整或限制访问，仅供信息展示，不构成投资建议。

分组持久化和旧数据迁移检查：

```bash
swiftc Sources/StockerMac/Models/StockModels.swift \
  Tests/GroupingChecks.swift -o .build/grouping-checks
.build/grouping-checks
```

> 行情接口仅供信息展示，不构成投资建议。公开行情接口可能调整或限制访问；跨市场资产汇总目前不做汇率折算。
