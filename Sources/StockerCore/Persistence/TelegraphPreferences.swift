import Foundation

/// 电报模块偏好：独立 UserDefaults key，不与 AppStore 的 PersistedState 混写
/// （避免 AppStore.persist() 全量重建覆盖电报字段）
/// 仅在 @MainActor 上下文使用（ViewModel 持有），无需 Sendable
public struct TelegraphPreferences {
    private enum Keys {
        static let source = "StockerMac.Telegraph.source"
        static let interval = "StockerMac.Telegraph.refreshInterval"
        static let notificationLevel = "StockerMac.Telegraph.notificationLevel"
        static let fetchMarkers = "StockerMac.Telegraph.fetchMarkers"
        static let readMarkers = "StockerMac.Telegraph.readMarkers"
        static let readMessageIDs = "StockerMac.Telegraph.readMessageIDs"
        static let gapStates = "StockerMac.Telegraph.gapStates"
        static let authorizationCached = "StockerMac.Telegraph.authorizationCached"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: 数据源 / 间隔 / 通知级别

    public var source: TelegraphSource {
        get { defaults.string(forKey: Keys.source).flatMap(TelegraphSource.init(rawValue:)) ?? .cls }
        set { defaults.set(newValue.rawValue, forKey: Keys.source) }
    }

    public var refreshInterval: Int {
        get { max(10, min(60, defaults.integer(forKey: Keys.interval) == 0 ? 30 : defaults.integer(forKey: Keys.interval))) }
        set { defaults.set(newValue, forKey: Keys.interval) }
    }

    public var notificationLevel: TelegraphNotificationLevel {
        get { defaults.string(forKey: Keys.notificationLevel).flatMap(TelegraphNotificationLevel.init(rawValue:)) ?? .redOnly }
        set { defaults.set(newValue.rawValue, forKey: Keys.notificationLevel) }
    }

    // MARK: 水位线（per source）

    /// 续拉断点：最老已见 (ctime, ids)
    public func fetchMarker(for source: TelegraphSource) -> TelegraphMarker? {
        readMarker(for: Keys.fetchMarkers, source: source)
    }

    public func setFetchMarker(_ marker: TelegraphMarker?, for source: TelegraphSource) {
        writeMarker(marker, for: Keys.fetchMarkers, source: source)
    }

    /// 已读边界
    public func readMarker(for source: TelegraphSource) -> TelegraphMarker? {
        readMarker(for: Keys.readMarkers, source: source)
    }

    public func setReadMarker(_ marker: TelegraphMarker?, for source: TelegraphSource) {
        writeMarker(marker, for: Keys.readMarkers, source: source)
    }

    /// 已读边界之后被单独点开的消息；边界负责批量已读，ID 集合负责逐条已读。
    public func readMessageIDs(for source: TelegraphSource) -> Set<String> {
        guard let values = defaults.stringArray(forKey: "\(Keys.readMessageIDs).\(source.rawValue)") else { return [] }
        return Set(values)
    }

    public func setReadMessageIDs(_ ids: Set<String>, for source: TelegraphSource) {
        let key = "\(Keys.readMessageIDs).\(source.rawValue)"
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }

    // MARK: gap 状态（持久化防反复发现同一缺口）

    public func gapState(for source: TelegraphSource) -> Bool {
        defaults.bool(forKey: "\(Keys.gapStates).\(source.rawValue)")
    }

    public func setGapState(_ value: Bool, for source: TelegraphSource) {
        defaults.set(value, forKey: "\(Keys.gapStates).\(source.rawValue)")
    }

    // MARK: 授权状态缓存（非权威，展示时实时查 getNotificationSettings）

    public var authorizationCached: Bool? {
        get {
            guard defaults.object(forKey: Keys.authorizationCached) != nil else { return nil }
            return defaults.bool(forKey: Keys.authorizationCached)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.authorizationCached)
            } else {
                defaults.removeObject(forKey: Keys.authorizationCached)
            }
        }
    }

    // MARK: 内部

    private func readMarker(for key: String, source: TelegraphSource) -> TelegraphMarker? {
        guard let data = defaults.data(forKey: "\(key).\(source.rawValue)"),
              let marker = try? JSONDecoder().decode(TelegraphMarker.self, from: data) else { return nil }
        return marker
    }

    private func writeMarker(_ marker: TelegraphMarker?, for key: String, source: TelegraphSource) {
        let fullKey = "\(key).\(source.rawValue)"
        guard let marker else {
            defaults.removeObject(forKey: fullKey)
            return
        }
        if let data = try? JSONEncoder().encode(marker) {
            defaults.set(data, forKey: fullKey)
        }
    }
}
