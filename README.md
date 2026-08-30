# Stocker for macOS

独立的 macOS 原生 A 股客户端。使用 Swift、SwiftUI 和 AppKit 构建，只读取本机
`127.0.0.1:7899` 的 StockDB；新浪/腾讯采集由独立的 StockerCollector 后台进程负责。

## 当前功能

- A 股自选列表（上海、深圳、北京）
- 行情与自定义分组顶部展示上证、深证、科创、创业、北证五类指数；持仓摘要仅在“我的持仓”展示
- 两级自定义分组（一级概念 + 二级细分），侧边栏按分组平均涨跌幅自动排序（每分钟更新，强者靠前，置顶分组固定排在同层最前）；点一级分组聚合查看名下全部股票并在列表显示「所属细分」列，分组可随时挂靠到其他一级或提升为一级（股票与提醒自动跟随），支持多分组归属和未分组筛选
- 分组平均涨跌幅每变动 1 个百分点发送系统通知
- 个股目标价格通知，按设置时现价自动判断涨到/跌到且仅当日有效
- 菜单栏轮播持仓行情，点击后精简展示股票名称、现价和涨跌幅
- 菜单栏待机支持“股票名 + 涨跌幅”轮播或浅色 Stocker 图标
- 独立行情图窗口：支持分时、五日、1/5/15/30/60/120 分钟及日/周/月/年 K，并展示成交量、均线、MACD 和行情概览
- 小窗模式：进入前选择分组，仅展示股票名称和涨跌幅，支持窗口置顶
- 本地 StockDB 行情源；盘中数据超过 30 秒未更新会明确提示采集器异常
- 行情数据路由：可在“本地/局域网 StockDB”和“新浪/腾讯网络行情”之间切换；StockDB 支持自定义 IP 与端口
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

需要 macOS 14+、Xcode 16+、已运行的 StockDB 服务和 StockerCollector。先启动采集器：

```bash
cd /Users/z/work/stockdb/realtime
./collector_ctl.sh install
```

然后在 Xcode 中直接打开 `Package.swift`，选择 `StockerMac` scheme 运行；也可以使用命令行：

```bash
swift run StockerMac
```

### 数据路由

设置页默认使用 `http://127.0.0.1:7899`。如果 StockDB 运行在局域网另一台机器，可填写
该机器的 IP 和端口。服务端必须把 `stockdb.conf` 的 `server.ip` 从 `127.0.0.1` 改为
局域网 IP 或 `0.0.0.0`，并允许对应端口通过防火墙。不要把无认证的 StockDB 端口暴露到公网。

选择“网络行情”后，现价与搜索直接使用新浪或腾讯；分时及 K 线使用腾讯接口。本地采集器
可以继续独立运行，切回 StockDB 后立即恢复本地数据读取。

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

项目没有依赖第三方 Swift Package。行情来自本地 StockDB，用户配置由应用直接持久化。

本地数据端到端检查：

```bash
swiftc -parse-as-library Sources/StockerMac/Models/StockModels.swift \
  Sources/StockerMac/Models/KLineModels.swift \
  Sources/StockerMac/Networking/LocalStockDBClient.swift \
  Tests/LocalStockDBChecks.swift -o .build/local-stockdb-checks
.build/local-stockdb-checks
```

在只有 Command Line Tools、没有完整 Xcode 测试框架的环境中，可以直接执行解析器检查：

```bash
swiftc Sources/StockerMac/Models/StockModels.swift \
  Sources/StockerMac/Networking/QuoteParser.swift \
  Tests/ParserChecks.swift -o .build/parser-checks
.build/parser-checks
```

`Tests/LocalStockDBChecks.swift` 会验证本地个股/指数行情、拼音搜索、242 点分时、历史 K 线和成交量额。

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
swiftc -parse-as-library Sources/StockerMac/Models/StockModels.swift \
  Tests/GroupingChecks.swift -o .build/grouping-checks
.build/grouping-checks
```

两级分组强度引擎检查（树口径、等权平均、排序与 parentID 清洗）：

```bash
swiftc Sources/StockerMac/Models/StockModels.swift \
  Sources/StockerMac/Models/GroupOrdering.swift \
  Tests/GroupHierarchyChecks.swift -o .build/group-hierarchy-checks
.build/group-hierarchy-checks
```

AppStore 层级行为检查（二级创建、聚合过滤、级联删除；需先 `swift build`）：

```bash
swift build
swiftc -parse-as-library -I .build/debug/Modules \
  Sources/StockerMac/Models/*.swift \
  Sources/StockerMac/Networking/QuoteService.swift \
  Sources/StockerMac/Networking/QuoteParser.swift \
  Sources/StockerMac/Networking/LocalStockDBClient.swift \
  Sources/StockerMac/Persistence/StateStore.swift \
  Sources/StockerMac/Views/Theme.swift \
  Sources/StockerMac/App/AppStore.swift \
  Sources/StockerMac/App/NotificationService.swift \
  Tests/GroupHierarchyStoreChecks.swift \
  .build/debug/StockerCore.build/*.o -o .build/group-hierarchy-store-checks
.build/group-hierarchy-store-checks
```

> 行情仅供信息展示，不构成投资建议。后台采集所用公开接口可能调整或限制访问。
