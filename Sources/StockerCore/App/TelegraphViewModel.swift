import Combine
import Foundation

// MARK: - 依赖协议

/// 自选股快照（@MainActor + Sendable 快照，Swift 6 隔离安全）
@MainActor
public protocol WatchlistProviding: AnyObject {
    var watchlistCodes: [SecurityID] { get }
}

/// 通知发送（协议化供测试注入 fake）
public protocol TelegraphNotificationSending: Sendable {
    func send(message: TelegraphMessage) async throws
    func requestAuthorization() async
}

// MARK: - ViewModel

@MainActor
public final class TelegraphViewModel: ObservableObject {
    @Published public var source: TelegraphSource {
        didSet { onSourceChanged() }
    }
    @Published public var refreshInterval: Int {
        didSet {
            preferences.refreshInterval = refreshInterval
            restartCoordinator()
        }
    }
    @Published public var notificationLevel: TelegraphNotificationLevel {
        didSet {
            preferences.notificationLevel = notificationLevel
            if notificationLevel.requiresAuthorization {
                Task { await notificationSender.requestAuthorization() }
            }
        }
    }
    @Published public var searchText = ""
    @Published public var selectedCategory: TelegraphCategory?
    @Published private(set) public var messages: [TelegraphMessage] = []
    @Published private(set) public var state: TelegraphCoordinatorState = .idle
    @Published private(set) public var feedError: String?
    @Published private(set) public var storageError: String?
    @Published private(set) public var notificationError: String?
    @Published private(set) public var dataGap = false
    @Published private(set) public var isBackfillPartial = false
    @Published private(set) public var isBackfilling = false
    @Published private(set) public var unreadCount = 0
    @Published public var selectedMessageID: String?
    @Published private(set) public var authorizationStatus: Bool?
    @Published private(set) public var lastUpdated: Date?

    /// 会话内通知边界（内存，不持久化——重启/暂停不补发积压）
    private var sessionWatermark: [TelegraphSource: TelegraphMarker] = [:]
    /// 续拉断点（持久化）
    private var fetchMarker: [TelegraphSource: TelegraphMarker] = [:]
    /// 已读边界（持久化）
    private var readMarker: [TelegraphSource: TelegraphMarker] = [:]
    /// 已读边界之后被单独阅读的消息（持久化）
    private var readMessageIDs: [TelegraphSource: Set<String>] = [:]
    /// 暂停期间积压不通知，恢复时静默合并推进
    private var isPaused = false
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    /// 通知点击可能早于目标数据加载，保留到缓存/feed 合并后再定位。
    private var pendingMessageID: String?
    private var gapAttempts = 0
    /// 补拉状态：慢速逐轮拉取，避免一次拉太多触发风控
    private var backfillNoProgressRounds = 0
    private var backfillStopped = false
    private var backfillPage = 0

    private let service: any TelegraphServiceProviding
    private let store: TelegraphStore
    private var preferences: TelegraphPreferences
    private let notificationSender: any TelegraphNotificationSending
    private weak var watchlist: (any WatchlistProviding)?

    public init(
        source: TelegraphSource? = nil,
        service: any TelegraphServiceProviding,
        store: TelegraphStore,
        preferences: TelegraphPreferences = TelegraphPreferences(),
        notificationSender: any TelegraphNotificationSending,
        watchlist: (any WatchlistProviding)?
    ) {
        let prefs = preferences
        let initialSource = source ?? prefs.source
        self.source = initialSource
        self.refreshInterval = prefs.refreshInterval
        self.notificationLevel = prefs.notificationLevel
        self.service = service
        self.store = store
        self.preferences = prefs
        self.notificationSender = notificationSender
        self.watchlist = watchlist
        self.fetchMarker = [:]
        self.readMarker = [:]
        for s in TelegraphSource.allCases {
            fetchMarker[s] = prefs.fetchMarker(for: s)
            readMarker[s] = prefs.readMarker(for: s)
            readMessageIDs[s] = prefs.readMessageIDs(for: s)
            if prefs.gapState(for: s) { dataGap = true }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    /// 注入自选股快照源（AppStore 实现 WatchlistProviding）
    public func setWatchlist(_ provider: (any WatchlistProviding)?) {
        watchlist = provider
    }

    // MARK: 生命周期

    public func start() {
        guard pollTask == nil else { return }
        let gen = generation
        pollTask = Task { [weak self] in
            await self?.runCoordinator(generation: gen)
        }
    }

    public func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        state = .idle
    }

    public func restartCoordinator() {
        stop()
        start()
    }

    public func togglePause() {
        isPaused.toggle()
        if isPaused { state = .paused } else { restartCoordinator() }
    }

    // MARK: 协调器（单 per-source 状态机：bootstrap → backfill → poll）

    private func runCoordinator(generation: Int) async {
        await loadCache()
        guard !Task.isCancelled, generation == self.generation else { return }

        // 1. bootstrap：仅由成功的最新 feed 响应建立会话通知边界
        state = .bootstrapping
        do {
            let latest = try await service.fetchLatest(source)
            guard !Task.isCancelled else { return }
            try? await store.append(source, latest)
            await purgeIfDue()
            mergeMessages(latest)
            bootstrapSessionWatermark(from: latest)
            dataGap = false
            feedError = nil
            lastUpdated = Date()
        } catch {
            feedError = error.localizedDescription
        }
        state = .polling

        // 3. poll loop：每轮先处理最新消息与通知，再顺带慢慢补拉历史（不一次拉太多）
        while !Task.isCancelled, generation == self.generation {
            if isPaused { try? await Task.sleep(for: .seconds(1)); continue }
            await pollOnce(generation: generation)
            await backfillStep(generation: generation)
            try? await Task.sleep(for: .seconds(max(1, refreshInterval)))
        }
    }

    // MARK: 缓存与合并

    private func loadCache() async {
        let cached = await store.load(source)
        guard !cached.isEmpty else { return }
        // 首次 merge 后 bootstrap 已读边界：历史不计算未读
        if readMarker[source] == nil, let newest = cached.first {
            readMarker[source] = TelegraphMarker(ctime: newest.ctime, ids: [newest.id])
            preferences.setReadMarker(readMarker[source], for: source)
        }
        mergeMessages(cached)
        updateUnreadCount()
    }

    private func mergeMessages(_ fetched: [TelegraphMessage]) {
        let fetched = fetched.filter { $0.source == source }
        guard !fetched.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var insertedNewMessage = false
        for message in fetched where byID[message.id] == nil {
            byID[message.id] = message
            insertedNewMessage = true
        }
        // 轮询通常只返回已经展示过的记录。相同数据不再重新发布整份数组，避免
        // 用户滚动时列表因为后台刷新而做无意义的 diff 和重新布局。
        guard insertedNewMessage else { return }
        messages = byID.values.sorted { $0.ctime > $1.ctime }
        resolvePendingSelection()
    }

    private func bootstrapSessionWatermark(from latest: [TelegraphMessage]) {
        guard sessionWatermark[source] == nil, let newest = latest.first else { return }
        sessionWatermark[source] = TelegraphMarker(ctime: newest.ctime, ids: [newest.id])
    }

    // MARK: 补拉（温和模式：每轮轮询顺带拉 3 页、页间隔 1s，数据慢慢积累）

    private func needsBackfill() -> Bool {
        guard !backfillStopped else { return false }
        // 有历史缓存就不再补拉（重启/替换 App 后数据从磁盘加载，避免每次重复尝试）
        guard messages.isEmpty else { return false }
        return true
    }

    private func backfillStep(generation: Int) async {
        guard needsBackfill() else {
            if isBackfilling { isBackfilling = false }
            return
        }
        isBackfilling = true
        let target = Date().addingTimeInterval(-3 * 24 * 3600).timeIntervalSince1970
        var before = messages.last?.ctime ?? Date().timeIntervalSince1970

        for _ in 0..<3 {
            guard !Task.isCancelled, generation == self.generation else { return }
            if before <= target { break }
            let anchor: TelegraphFetchAnchor = source.usesTimePagination
                ? TelegraphFetchAnchor(olderThanCtime: before)
                : TelegraphFetchAnchor(page: backfillPage + 1)
            do {
                let page = try await service.fetchPage(source, anchor: anchor)
                guard !page.isEmpty else {
                    backfillNoProgressRounds += 1
                    break
                }
                try? await store.append(source, page)
                mergeMessages(page)
                if let oldest = page.last, oldest.ctime < before {
                    before = oldest.ctime
                    backfillPage += 1
                    fetchMarker[source] = TelegraphMarker(ctime: oldest.ctime, ids: [oldest.id])
                    preferences.setFetchMarker(fetchMarker[source], for: source)
                    backfillNoProgressRounds = 0
                } else {
                    backfillNoProgressRounds += 1
                }
                if source != .jin10, page.count < TelegraphService.pageSize {
                    backfillNoProgressRounds += 1
                    break
                }
                try? await Task.sleep(for: .milliseconds(1000))
            } catch {
                feedError = error.localizedDescription
                backfillNoProgressRounds += 1
                break
            }
        }

        if backfillNoProgressRounds >= 3 {
            // 接口不再推进（翻页受限/拉完）：停止补拉，标记部分历史
            backfillStopped = true
            if (messages.last?.ctime ?? 0) > target {
                isBackfillPartial = true
            }
            isBackfilling = false
        } else if before <= target {
            isBackfillPartial = false
            isBackfilling = false
        }
    }

    // MARK: 轮询 + 通知事务

    private func pollOnce(generation: Int) async {
        state = .polling
        do {
            var anchor: TelegraphFetchAnchor?
            var pageCount = 0
            var newestBatch: [TelegraphMessage] = []
            var allFetched: [TelegraphMessage] = []

            // 从最新向旧反向拉取，直到命中会话边界或页数上限
            while !Task.isCancelled, generation == self.generation, pageCount < 10 {
                let page = try await service.fetchPage(source, anchor: anchor)
                guard !page.isEmpty else { break }
                allFetched.append(contentsOf: page)
                if newestBatch.isEmpty { newestBatch = page }
                try? await store.append(source, page)
                mergeMessages(page)

                guard let boundary = sessionWatermark[source] else { break }
                let reachedBoundary = page.last.map { !boundary.isNewer(than: $0) } ?? true
                if reachedBoundary || (source != .jin10 && page.count < TelegraphService.pageSize) { break }

                anchor = source.usesTimePagination
                    ? TelegraphFetchAnchor(olderThanCtime: page.last?.ctime)
                    : TelegraphFetchAnchor(page: pageCount + 2)
                pageCount += 1
            }

            if pageCount >= 10 { handleUnreconciledGap() } else { gapAttempts = 0 }

            // 通知事务：仅通知严格新于会话边界的记录
            var newestProcessed: TelegraphMessage?
            for message in allFetched.sorted(by: { $0.ctime < $1.ctime }) {
                guard let boundary = sessionWatermark[source], boundary.isNewer(than: message) else { continue }
                let outcome = await notifyIfNeeded(message)
                if outcome == .failed { break }
                newestProcessed = message
            }
            // sent/suppressed 推进会话边界；failed 不越过，下一轮继续重试
            if let newestProcessed {
                sessionWatermark[source] = TelegraphMarker(ctime: newestProcessed.ctime, ids: [newestProcessed.id])
            }
            if let oldest = allFetched.last {
                fetchMarker[source] = TelegraphMarker(ctime: oldest.ctime, ids: [oldest.id])
                preferences.setFetchMarker(fetchMarker[source], for: source)
            }
            updateUnreadCount()
            lastUpdated = Date()
        } catch {
            feedError = error.localizedDescription
        }
    }

    private func handleUnreconciledGap() {
        gapAttempts += 1
        if gapAttempts >= 3 {
            // 缺口不可恢复：静默 rebaseline（不通知），持久化 gap 状态，防反复发现同一缺口
            if let newest = messages.first {
                sessionWatermark[source] = TelegraphMarker(ctime: newest.ctime, ids: [newest.id])
                fetchMarker[source] = TelegraphMarker(ctime: newest.ctime, ids: [newest.id])
                preferences.setFetchMarker(fetchMarker[source], for: source)
            }
            dataGap = true
            preferences.setGapState(true, for: source)
            gapAttempts = 0
        }
    }

    /// 通知判定：per-record outcome（sent/suppressed/failed）
    private func notifyIfNeeded(_ message: TelegraphMessage) async -> TelegraphNotificationOutcome {
        guard notificationLevel.requiresAuthorization else { return .suppressed }

        let shouldNotify: Bool
        switch notificationLevel {
        case .all:
            shouldNotify = true
        case .redOnly:
            // 东财源不支持重要标记；财联社加红与金十 important 均统一为 isRed。
            shouldNotify = message.source.supportsImportance && message.isRed
        case .redOrWatchlist:
            let watchlistHit = watchlist?.watchlistCodes.contains { message.stockList.contains($0) } ?? false
            shouldNotify = message.isRed || watchlistHit
        case .off:
            shouldNotify = false
        }
        guard shouldNotify else { return .suppressed }

        do {
            try await notificationSender.send(message: message)
            notificationError = nil
            return .sent
        } catch {
            notificationError = "通知发送失败：\(error.localizedDescription)"
            return .failed
        }
    }

    // MARK: 已读 / 未读

    public func markAllRead() {
        guard let newest = messages.first else { return }
        readMarker[source] = TelegraphMarker(ctime: newest.ctime, ids: [newest.id])
        preferences.setReadMarker(readMarker[source], for: source)
        readMessageIDs[source] = []
        preferences.setReadMessageIDs([], for: source)
        updateUnreadCount()
    }

    public func isUnread(_ message: TelegraphMessage) -> Bool {
        guard message.source == source, let marker = readMarker[source] else { return false }
        return marker.isNewer(than: message) && !(readMessageIDs[source]?.contains(message.id) ?? false)
    }

    /// 单条阅读不移动整体已读边界，避免点开最新一条时把其余未读全部清空。
    public func markRead(through message: TelegraphMessage) {
        guard message.source == source, isUnread(message) else { return }
        var ids = readMessageIDs[source] ?? []
        ids.insert(message.id)
        // 本地仅保留 7 天消息，额外限制集合体积，防止偏好无限增长。
        if ids.count > 500 {
            let activeIDs = Set(messages.prefix(500).map(\.id))
            ids.formIntersection(activeIDs)
        }
        readMessageIDs[source] = ids
        preferences.setReadMessageIDs(ids, for: source)
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        guard let marker = readMarker[source] else {
            unreadCount = 0
            return
        }
        let individuallyRead = readMessageIDs[source] ?? []
        unreadCount = messages.filter { marker.isNewer(than: $0) && !individuallyRead.contains($0.id) }.count
    }

    // MARK: 通知点击导航

    /// 消费通知点击：切源 → 定位消息（数据就绪后才应调用）
    public func selectMessage(source target: TelegraphSource, messageID: String) {
        pendingMessageID = messageID
        searchText = ""
        selectedCategory = nil
        if source != target { source = target }
        resolvePendingSelection()
    }

    public func message(byID id: String) -> TelegraphMessage? {
        messages.first { $0.id == id }
    }

    // MARK: 过滤（视图层）

    public var filteredMessages: [TelegraphMessage] {
        var result = messages
        if let selectedCategory {
            result = result.filter { $0.categories.contains(selectedCategory) }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.content.localizedCaseInsensitiveContains(keyword)
            }
        }
        return result
    }

    /// 该分类是否有可展示的消息（本地过滤基于持久化 categories）
    public func hasMessages(in category: TelegraphCategory) -> Bool {
        messages.contains { $0.categories.contains(category) }
    }

    public var supportedCategories: [TelegraphCategory] {
        TelegraphCategory.allCases.filter { hasMessages(in: $0) }
    }

    // MARK: 数据源切换

    private func onSourceChanged() {
        preferences.source = source
        // 切源：会话通知边界等待新源 bootstrap（成功 feed 后才建立）
        sessionWatermark[source] = nil
        messages = []
        unreadCount = 0
        dataGap = false
        feedError = nil
        storageError = nil
        notificationError = nil
        selectedMessageID = nil
        selectedCategory = nil
        lastUpdated = nil
        backfillNoProgressRounds = 0
        backfillStopped = false
        backfillPage = 0
        isBackfillPartial = false
        isBackfilling = false
        restartCoordinator()
    }

    private func resolvePendingSelection() {
        guard let pendingMessageID,
              let message = messages.first(where: { $0.id == pendingMessageID }) else { return }
        selectedMessageID = message.id
        self.pendingMessageID = nil
        markRead(through: message)
    }

    public func refreshNow() {
        restartCoordinator()
    }

    // MARK: 存储

    private func purgeIfDue() async {
        do {
            try await store.purge(source)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: 授权状态

    public func refreshAuthorizationStatus(actual: Bool?) {
        authorizationStatus = actual
        if let actual {
            preferences.authorizationCached = actual
        }
    }
}
