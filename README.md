# Stocker for macOS

独立的 macOS 原生股票行情客户端。使用 Swift、SwiftUI 和 AppKit 构建，通过新浪财经与腾讯财经行情接口获取数据，不依赖 JetBrains 插件代码。

## 当前功能

- A 股、港股、美股自选列表
- 总览顶部固定展示上证指数实时点位与涨跌幅
- 自定义分组、拖拽排序、多分组归属和未分组筛选
- 菜单栏轮播持仓行情，点击后精简展示股票名称、现价和涨跌幅
- 菜单栏待机支持“股票名 + 涨跌幅”轮播或浅色 Stocker 图标
- 小窗模式：进入前选择分组，仅展示股票名称和涨跌幅，支持窗口置顶
- 新浪 / 腾讯双数据源切换
- 股票代码、名称、拼音搜索
- 使用英文逗号一次查询并批量添加多只股票
- 按当前市场或分组批量选择、搜索并删除股票，删除前二次确认
- 5–60 秒自动刷新、手动刷新和暂停
- 成本价、持仓数量、今日盈亏、累计盈亏
- 一键清空全部仓位，自动保留成本、数量、清仓价和时间历史
- 红涨绿跌 / 绿涨红跌 / 单色模式
- 本地持久化，无需账号
- 快捷键：`⌘D` 添加股票，搜索窗口中 `⌘S` 完成，`⌘W` 收起主窗口

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

分组持久化和旧数据迁移检查：

```bash
swiftc Sources/StockerMac/Models/StockModels.swift \
  Tests/GroupingChecks.swift -o .build/grouping-checks
.build/grouping-checks
```

> 行情接口仅供信息展示，不构成投资建议。公开行情接口可能调整或限制访问；跨市场资产汇总目前不做汇率折算。
