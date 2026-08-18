import Foundation

// 电报模块检查程序：签名固定向量 / 两源解析 / SecurityID / 存储 / 水位线 / 通知事务
// 编译运行：
//   swiftc -parse-as-library Sources/StockerCore/Models/*.swift Sources/StockerCore/Networking/*.swift \
//     Sources/StockerCore/Persistence/*.swift Sources/StockerCore/App/*.swift \
//     Tests/TelegraphChecks.swift -o .build/telegraph-checks
//   .build/telegraph-checks

@main
struct TelegraphChecks {
    static var failures = 0
    static var checks = 0

    @MainActor
    static func main() async {
        checkCLSSignature()
        checkCLSParse()
        checkEastmoneyParse()
        checkJin10Parse()
        checkSecurityID()
        checkClassifier()
        checkPresentationText()
        await checkStore()
        checkMarker()
        await checkNotificationTransactions()

        if failures == 0 {
            print("✅ telegraph-checks: \(checks) 项检查全部通过")
        } else {
            print("❌ telegraph-checks: \(checks) 项中 \(failures) 项失败")
            exit(1)
        }
    }

    static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if condition {
            print("  ✅ \(name)")
        } else {
            failures += 1
            print("  ❌ \(name)")
        }
    }

    static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegraphChecks-\(UUID().uuidString)", isDirectory: true)
    }

    static func makeMessage(_ id: String, ctime: TimeInterval, source: TelegraphSource = .cls,
                            isRed: Bool = false, stocks: [SecurityID] = []) -> TelegraphMessage {
        TelegraphMessage(id: "\(source.rawValue):\(id)", source: source, ctime: ctime,
                         title: "标题 \(id)", content: "正文 \(id)",
                         isRed: isRed, categories: isRed ? [.red] : [], stockList: stocks)
    }

    // MARK: 签名固定向量（与真实接口实测比对值一致）

    static func checkCLSSignature() {
        print("== CLS 签名 ==")
        let sign = CLSSignature().sign(params: [
            "app": "CailianpressWeb",
            "category": "",
            "last_time": "0",
            "os": "web",
            "refresh_type": "1",
            "rn": "20",
            "sv": "8.7.9",
        ])
        // 2026-08-08 实测: 该签名请求返回 errno:0
        check(sign == "cc63740dbc5af37fa447dcb29c47812e", "固定向量匹配实测值")

        let a = CLSSignature().sign(params: ["app": "CailianpressWeb", "os": "web", "rn": "20"])
        let b = CLSSignature().sign(params: ["rn": "20", "os": "web", "app": "CailianpressWeb"])
        check(a == b, "参数顺序无关")
        check(a != CLSSignature().sign(params: ["app": "CailianpressWeb", "rn": "21"]), "参数变化影响签名")
    }

    // MARK: 财联社 DTO

    static func checkCLSParse() {
        print("== 财联社 DTO 解析 ==")
        let json = """
        {"errno":0,"msg":"","data":{"roll_data":[
        {"id":2449030,"ctime":1786152953,"title":"济南再发5000万汽车购新补贴 8月20日起申报",
         "content":"【济南再发5000万汽车购新补贴】财联社8月8日电。",
         "brief":"摘要","level":"C","reading_num":37693,"category":0,
         "stock_list":["SH600000","00700","AAPL","GB_NVDA"],
         "shareurl":"https://www.cls.cn/detail/2449030"},
        {"id":2449031,"ctime":1786152954,"title":"","content":"【重磅】重大事项。",
         "level":"A","reading_num":100,"category":1,"stock_list":null,
         "shareurl":"https://evil.example.com/x"}
        ]}}
        """
        do {
            let messages = try CLSDTO.parse(data: Data(json.utf8))
            check(messages.count == 2, "解析两条")
            let first = messages[0]
            check(first.id == "cls:2449030" && first.ctime == 1786152953, "id 与时间戳")
            check(first.title == "济南再发5000万汽车购新补贴 8月20日起申报", "标题")
            check(!first.isRed, "category=0/level=C 不加红")
            check(first.stockList.map(\.rawValue) == ["CN:600000", "HK:00700", "US:AAPL", "US:NVDA"], "股票代码规范化")
            check(first.url == "https://www.cls.cn/detail/2449030", "白名单 URL 保留")
            let second = messages[1]
            check(second.isRed, "level=A + category=1 加红")
            check(second.url == nil, "非白名单 URL 过滤")
        } catch {
            check(false, "解析失败: \(error)")
        }

        do {
            _ = try CLSDTO.parse(data: Data(#"{"errno":10012,"msg":"签名错误"}"#.utf8))
            check(false, "业务错误应抛错")
        } catch {
            check(true, "业务错误抛错")
        }
    }

    // MARK: 东财 DTO

    static func checkEastmoneyParse() {
        print("== 东财 DTO 解析 ==")
        let jsonp = """
        var ajaxResult={"rc":0,"me":"","LivesList":[
        {"id":"202608083835796415","title":"腾讯大力把WorkBuddy送上牌桌",
         "digest":"【腾讯大力把WorkBuddy送上牌桌】一位腾讯CSIG人士告诉界面新闻。",
         "showtime":"2026-08-08 09:42:00","column":"100,102,103,105",
         "url_w":"https://finance.eastmoney.com/a/202608083835796415.html"},
        {"id":"202608083835796416","title":"","digest":"另一条快讯",
         "showtime":"2026-08-08 09:41:03","column":"102",
         "url_w":"http://insecure.example.com/a.html"}
        ]};
        """
        do {
            let messages = try EastmoneyDTO.parse(data: Data(jsonp.utf8))
            check(messages.count == 2, "解析两条（含尾部分号）")
            let first = messages[0]
            check(first.id == "eastmoney:202608083835796415", "id 前缀")
            check(first.ctime == 1786153320, "showtime → 秒级时间戳 (09:42:00+08)")
            check(!first.isRed, "东财不加红")
            check(first.url == "https://finance.eastmoney.com/a/202608083835796415.html", "白名单 https 保留")
            check(messages[1].url == nil, "http 非 https 过滤")
        } catch {
            check(false, "解析失败: \(error)")
        }

        do {
            _ = try EastmoneyDTO.parse(data: Data(#"{"not":"jsonp"}"#.utf8))
            check(false, "错误 wrapper 应抛错")
        } catch {
            check(true, "错误 wrapper 抛错")
        }
    }

    // MARK: 金十 A股 DTO

    static func checkJin10Parse() {
        print("== 金十 A股 DTO 解析 ==")
        let json = #"""
        {"status":200,"message":"OK","data":[
          {"channel":[3,4,5],"data":{"content":"中际旭创短线跳水，现跌超4%。<font>详情</font>","title":"","source_link":""},
           "extras":{"ad":false},"id":"20260807141719234800","important":1,
           "kinds":[{"id":14}],"remark":[{"symbol":"300308.SZ","type":"quotes"}],"time":"2026-08-07 14:17:19","type":0},
          {"channel":[1,3],"data":{"content":"海外快讯","title":""},"extras":{"ad":false},
           "id":"global","important":0,"kinds":[{"id":31}],"remark":[],"time":"2026-08-07 14:16:00","type":0},
          {"channel":[1,2,3],"data":{"content":"美国非农就业数据预期","title":""},"extras":{"ad":false},
           "id":"macro-with-stock-kind","important":0,"kinds":[{"id":14}],
           "remark":[{"symbol":"601166.SH","type":"quotes"}],"time":"2026-08-07 14:15:30","type":0},
          {"channel":[4],"data":{"content":"广告","title":""},"extras":{"ad":true},
           "id":"ad","important":0,"kinds":[{"id":14}],"remark":[],"time":"2026-08-07 14:15:00","type":0}
        ]}
        """#
        do {
            let messages = try Jin10DTO.parse(data: Data(json.utf8))
            check(messages.count == 1, "仅保留 A股快讯并过滤海外宏观与广告")
            guard let first = messages.first else { return }
            check(first.id == "jin10:20260807141719234800" && first.source == .jin10, "id 与来源")
            check(first.isRed && first.categories.contains(.red), "important 映射重要消息")
            check(first.content == "中际旭创短线跳水，现跌超4%。详情", "清理 HTML 标签")
            check(first.stockList.map(\.rawValue) == ["CN:300308"], "remark 股票代码规范化")
            check(first.url == "https://flash.jin10.com/detail/20260807141719234800", "生成官方详情链接")
            check(first.ctime == 1786083439, "北京时间解析")
        } catch {
            check(false, "金十解析失败: \(error)")
        }

        do {
            _ = try Jin10DTO.parse(data: Data(#"{"status":403,"message":"forbidden","data":[]}"#.utf8))
            check(false, "金十业务错误应抛错")
        } catch {
            check(true, "金十业务错误抛错")
        }
    }

    // MARK: SecurityID

    static func checkSecurityID() {
        print("== SecurityID 规范化 ==")
        check(SecurityID.parse("SH600000") == SecurityID(market: .cn, code: "600000"), "SH 前缀")
        check(SecurityID.parse("sz000001") == SecurityID(market: .cn, code: "000001"), "小写 sz")
        check(SecurityID.parse("300750") == SecurityID(market: .cn, code: "300750"), "6 位数字 → CN")
        check(SecurityID.parse("00700") == SecurityID(market: .hk, code: "00700"), "5 位数字 → HK")
        check(SecurityID.parse("9988") == SecurityID(market: .hk, code: "9988"), "4 位数字 → HK")
        check(SecurityID.parse("AAPL") == SecurityID(market: .us, code: "AAPL"), "字母 → US")
        check(SecurityID.parse("gb_nvda") == SecurityID(market: .us, code: "NVDA"), "gb_ 前缀")
        check(SecurityID.parse("300308.SZ") == SecurityID(market: .cn, code: "300308"), "金十 SZ 后缀")
        check(SecurityID.parse("600000.SH") == SecurityID(market: .cn, code: "600000"), "金十 SH 后缀")
        check(SecurityID.parse("") == nil && SecurityID.parse("   ") == nil, "空值返回 nil")
    }

    static func checkPresentationText() {
        print("== 展示文本 ==")
        let repeated = TelegraphMessage(
            id: "cls:presentation", source: .cls, ctime: 1,
            title: "标题", content: "【标题】正文内容", isRed: false, categories: []
        )
        check(repeated.displayTitle == "标题", "保留独立标题")
        check(repeated.displayBody == "正文内容", "移除正文重复标题")

        let embedded = TelegraphMessage(
            id: "cls:embedded", source: .cls, ctime: 1,
            title: "", content: "【重磅消息】后续正文", isRed: true, categories: [.red]
        )
        check(embedded.displayTitle == "重磅消息", "从正文提取标题")
        check(embedded.displayBody == "后续正文", "提取标题后保留正文")
        check(embedded.summary(limit: 2) == "后续…", "通知摘要带省略号")
    }

    // MARK: 内容分类器

    static func checkClassifier() {
        print("== 内容分类器 ==")
        // 公司
        check(TelegraphClassifier.classify(title: "某公司中标亿元项目", content: "").contains(.company), "公司：中标")
        check(TelegraphClassifier.classify(title: "", content: "【XX股份】股东计划增持不低于1亿元").contains(.company), "公司：增持")
        // 看盘
        check(TelegraphClassifier.classify(title: "沪指午后翻红", content: "两市成交额突破万亿").contains(.market), "看盘：沪指/成交额")
        check(!TelegraphClassifier.classify(title: "某地发放汽车补贴", content: "补贴资金额度5000万元").contains(.market), "看盘：资金补贴不误命中")
        // 港美股
        check(TelegraphClassifier.classify(title: "美股收盘", content: "纳指涨1.2%").contains(.hkUs), "港美股：美股/纳指")
        check(TelegraphClassifier.classify(title: "", content: "美联储官员表示将维持利率不变").contains(.hkUs), "港美股：美联储")
        // 基金
        check(TelegraphClassifier.classify(title: "多只ETF份额增长", content: "公募基金积极布局").contains(.fund), "基金：ETF/公募")
        // 提醒
        check(TelegraphClassifier.classify(title: "新股申购提示", content: "今日3只新股申购").contains(.reminder), "提醒：新股申购")
        check(!TelegraphClassifier.classify(title: "列车恢复开行", content: "停运列车恢复").contains(.reminder), "提醒：恢复不误命中")
        // 多分类
        let multi = TelegraphClassifier.classify(title: "恒指低开", content: "港股ETF净流入")
        check(multi.contains(.hkUs) && multi.contains(.fund), "多分类并存")
        // 无命中
        check(TelegraphClassifier.classify(title: "台风登陆", content: "多地发布预警").isEmpty, "无命中为空集")
    }

    // MARK: 存储（每场景独立临时目录，避免互相污染）

    static func checkStore() async {
        print("== TelegraphStore ==")

        // roundtrip：写入读取 + ctime 降序
        do {
            let store = TelegraphStore(baseURL: makeTempDir())
            let now = Date().timeIntervalSince1970
            try await store.append(.cls, [makeMessage("1", ctime: now), makeMessage("2", ctime: now - 100)])
            let loaded = await store.load(.cls)
            check(loaded.count == 2 && loaded.first?.id == "cls:1", "写入/读取 roundtrip（ctime 降序，新在前）")
        } catch {
            check(false, "roundtrip 异常: \(error)")
        }

        // append 去重合并
        do {
            let store = TelegraphStore(baseURL: makeTempDir())
            let now = Date().timeIntervalSince1970
            try await store.append(.cls, [makeMessage("1", ctime: now)])
            try await store.append(.cls, [makeMessage("1", ctime: now), makeMessage("3", ctime: now - 50)])
            let loaded = await store.load(.cls)
            check(loaded.count == 2, "append 按 id 去重合并")
        } catch {
            check(false, "去重异常: \(error)")
        }

        // rename 覆盖已有日文件（同一天连续写两次）
        do {
            let store = TelegraphStore(baseURL: makeTempDir())
            let now = Date().timeIntervalSince1970
            try await store.append(.cls, [makeMessage("a", ctime: now)])
            try await store.append(.cls, [makeMessage("b", ctime: now - 10)])
            let loaded = await store.load(.cls)
            check(loaded.count == 2, "原子写覆盖已有日文件")
        } catch {
            check(false, "覆盖写入异常: \(error)")
        }

        // 7 天清理
        do {
            let store = TelegraphStore(baseURL: makeTempDir())
            let cal = Calendar(identifier: .gregorian)
            for dayOffset in 0...8 {
                guard let date = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
                try await store.append(.cls, [makeMessage("d\(dayOffset)", ctime: date.timeIntervalSince1970)])
            }
            try await store.purge(.cls, keepDays: 7)
            let loaded = await store.load(.cls)
            check(loaded.count == 7, "purge 保留今天 + 前 6 天")
        } catch {
            check(false, "purge 异常: \(error)")
        }

        // 损坏文件隔离
        do {
            let dir = makeTempDir()
            let store = TelegraphStore(baseURL: dir)
            let now = Date().timeIntervalSince1970
            try await store.append(.cls, [makeMessage("ok", ctime: now)])
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let dayFile = files.first(where: {
                $0.lastPathComponent.hasPrefix("telegraph-cls") && !$0.lastPathComponent.hasSuffix(".tmp")
            })!
            try "not json".write(to: dayFile, atomically: true, encoding: .utf8)
            let loaded = await store.load(.cls)
            check(loaded.isEmpty, "损坏文件被跳过")
            let after = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            check(after.contains { $0.lastPathComponent.hasSuffix(".corrupt") }, "损坏文件隔离为 .corrupt")
        } catch {
            check(false, "隔离异常: \(error)")
        }

        // 时区分天（Asia/Shanghai）
        do {
            let dir = makeTempDir()
            let store = TelegraphStore(baseURL: dir)
            try await store.append(.cls, [makeMessage("tz", ctime: 1786152953)])
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            check(files.contains { $0.lastPathComponent == "telegraph-cls-20260808.json" },
                  "按 Asia/Shanghai 分天 (20260808)")
        } catch {
            check(false, "时区异常: \(error)")
        }
    }

    // MARK: 水位线

    static func checkMarker() {
        print("== 水位线 ==")
        let marker = TelegraphMarker(ctime: 1000, ids: ["cls:z"])
        check(marker.isNewer(than: makeMessage("b", ctime: 1001)), "ctime 更新判为新")
        check(marker.isNewer(than: makeMessage("a", ctime: 1000)), "同秒未见 id 判为新")
        check(!marker.isNewer(than: makeMessage("z", ctime: 1000)), "同秒已见 id 判为旧")
        check(!marker.isNewer(than: makeMessage("z", ctime: 999)), "更旧 ctime 判为旧")
    }

    // MARK: 通知事务（fake service/sender）

    @MainActor
    static func checkNotificationTransactions() async {
        print("== 通知事务 ==")

        /// 可变 service：bootstrap 后追加新消息，模拟"轮询期间到达"
        final class GrowingService: TelegraphServiceProviding, @unchecked Sendable {
            private let lock = NSLock()
            private var batch: [TelegraphMessage]
            init(_ batch: [TelegraphMessage]) { self.batch = batch }
            func fetchLatest(_ source: TelegraphSource) async throws -> [TelegraphMessage] {
                lock.lock(); defer { lock.unlock() }
                return batch
            }
            func fetchPage(_ source: TelegraphSource, anchor: TelegraphFetchAnchor?) async throws -> [TelegraphMessage] {
                lock.lock(); defer { lock.unlock() }
                return batch
            }
            func add(_ messages: [TelegraphMessage]) {
                lock.lock(); defer { lock.unlock() }
                batch.append(contentsOf: messages)
            }
        }

        final class FakeSender: TelegraphNotificationSending, @unchecked Sendable {
            let queue = DispatchQueue(label: "fake")
            var sentIDs: [String] = []
            var failIDs: Set<String> = []
            func send(message: TelegraphMessage) async throws {
                if failIDs.contains(message.id) { throw TelegraphServiceError.badResponse }
                queue.sync { sentIDs.append(message.id) }
            }
            func requestAuthorization() async {}
            var sent: [String] { queue.sync { sentIDs } }
        }

        @MainActor
        final class FakeWatchlist: WatchlistProviding {
            let codes: [SecurityID]
            init(_ codes: [SecurityID]) { self.codes = codes }
            var watchlistCodes: [SecurityID] { codes }
        }

        func tempStore() -> TelegraphStore {
            TelegraphStore(baseURL: makeTempDir())
        }

        let base = Date().timeIntervalSince1970

        // 仅加红：bootstrap 后新到达的加红通知、普通 suppressed
        do {
            let service = GrowingService([makeMessage("old", ctime: base - 200, isRed: false)])
            let sender = FakeSender()
            let vm = TelegraphViewModel(
                service: service,
                store: tempStore(),
                notificationSender: sender,
                watchlist: FakeWatchlist([])
            )
            vm.refreshInterval = 1
            vm.notificationLevel = .redOnly
            vm.start()
            try await Task.sleep(for: .milliseconds(500))  // bootstrap
            service.add([
                makeMessage("red", ctime: base, isRed: true),
                makeMessage("plain", ctime: base - 50, isRed: false),
            ])
            try await Task.sleep(for: .milliseconds(1200))  // 下一轮 poll
            vm.stop()
            check(sender.sent == ["cls:red"], "仅加红：新到达加红被通知，普通被抑制")
        } catch { check(false, "仅加红异常: \(error)") }

        // 东财 + 仅加红：加红维度不通知（自选股命中仍通知——东财无股票字段，此处验证抑制）
        do {
            let service = GrowingService([makeMessage("em-old", ctime: base - 200, source: .eastmoney)])
            let sender = FakeSender()
            let vm = TelegraphViewModel(
                service: service,
                store: tempStore(),
                notificationSender: sender,
                watchlist: FakeWatchlist([])
            )
            vm.refreshInterval = 1
            vm.notificationLevel = .redOnly
            vm.start()
            try await Task.sleep(for: .milliseconds(500))
            service.add([makeMessage("em-red", ctime: base, source: .eastmoney, isRed: true)])
            try await Task.sleep(for: .milliseconds(1200))
            vm.stop()
            check(!sender.sent.contains("eastmoney:em-red"), "东财加红不通知")
        } catch { check(false, "东财降级异常: \(error)") }

        // 加红+自选股：自选股命中通知
        do {
            let watchStock = SecurityID(market: .cn, code: "600519")
            let watchlist = FakeWatchlist([watchStock])  // 需强引用，vm 只持有 weak
            let service = GrowingService([makeMessage("old", ctime: base - 200)])
            let sender = FakeSender()
            let vm = TelegraphViewModel(
                service: service,
                store: tempStore(),
                notificationSender: sender,
                watchlist: watchlist
            )
            vm.refreshInterval = 1
            vm.notificationLevel = .redOrWatchlist
            vm.start()
            try await Task.sleep(for: .milliseconds(500))
            service.add([makeMessage("hit", ctime: base, stocks: [watchStock])])
            try await Task.sleep(for: .milliseconds(1200))
            vm.stop()
            check(sender.sent.contains("cls:hit"), "自选股命中通知")
        } catch { check(false, "自选股异常: \(error)") }

        // 关级别：不发送
        do {
            let service = GrowingService([makeMessage("old", ctime: base - 200, isRed: true)])
            let sender = FakeSender()
            let vm = TelegraphViewModel(
                service: service,
                store: tempStore(),
                notificationSender: sender,
                watchlist: FakeWatchlist([])
            )
            vm.refreshInterval = 1
            vm.notificationLevel = .off
            vm.start()
            try await Task.sleep(for: .milliseconds(500))
            service.add([makeMessage("any", ctime: base, isRed: true)])
            try await Task.sleep(for: .milliseconds(1200))
            vm.stop()
            check(sender.sent.isEmpty, "关级别不发送")
        } catch { check(false, "关级别异常: \(error)") }

        // 发送失败 → failed，错误被 surface
        do {
            let service = GrowingService([makeMessage("old", ctime: base - 200, isRed: false)])
            let sender = FakeSender()
            sender.failIDs = ["cls:f1"]
            let vm = TelegraphViewModel(
                service: service,
                store: tempStore(),
                notificationSender: sender,
                watchlist: FakeWatchlist([])
            )
            vm.refreshInterval = 1
            vm.notificationLevel = .redOnly
            vm.start()
            try await Task.sleep(for: .milliseconds(500))
            service.add([makeMessage("f1", ctime: base, isRed: true)])
            try await Task.sleep(for: .milliseconds(1200))
            vm.stop()
            check(!sender.sent.contains("cls:f1"), "发送失败不推进")
            check(vm.notificationError != nil, "通知错误被 surface")
        } catch { check(false, "失败重试异常: \(error)") }
    }
}
