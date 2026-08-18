import Foundation

// MARK: - 存储错误

public enum TelegraphStoreError: LocalizedError, Sendable {
    case writeFailed(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let msg): "电报数据写入失败：\(msg)"
        case .loadFailed(let msg): "电报数据读取失败：\(msg)"
        }
    }
}

// MARK: - 按天分文件存储（actor 串行 + 原子写）

public actor TelegraphStore {
    private struct Envelope: Codable {
        let version: Int
        let messages: [TelegraphMessage]
    }

    private let baseURL: URL
    private let fileManager: FileManager
    /// Asia/Shanghai 日历（分天与清理的时区基准）
    private let shanghaiCalendar: Calendar
    private var lastPurgeDate: Date?

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        self.shanghaiCalendar = calendar
    }

    public static func defaultBaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stocker", isDirectory: true)
    }

    // MARK: 读写

    /// 读取某源全部按天文件（存在几天读几天），按 ctime 降序
    public func load(_ source: TelegraphSource) -> [TelegraphMessage] {
        let files = dayFiles(for: source)
        var messages: [TelegraphMessage] = []
        var seenIDs = Set<String>()
        for file in files.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: file.1) else { continue }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                // 损坏文件隔离（改名 .corrupt，纳入 7 天清理）
                quarantine(file.1)
                continue
            }
            for message in envelope.messages where seenIDs.insert(message.id).inserted {
                messages.append(message)
            }
        }
        return messages.sorted { $0.ctime > $1.ctime }
    }

    /// 增量写入：按天分组，当天文件与原内容合并（按 id 去重）后原子替换
    public func append(_ source: TelegraphSource, _ messages: [TelegraphMessage]) throws {
        guard !messages.isEmpty else { return }
        try ensureDirectory()
        let grouped = Dictionary(grouping: messages) { dayString(of: $0.ctime) }
        for (day, dayMessages) in grouped {
            let url = fileURL(source: source, day: day)
            var existing: [TelegraphMessage] = []
            if let data = try? Data(contentsOf: url),
               let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                existing = envelope.messages
            }
            let mergedIDs = Set(existing.map(\.id))
            var merged = existing
            for message in dayMessages where !mergedIDs.contains(message.id) {
                merged.append(message)
            }
            try atomicWrite(Envelope(version: 1, messages: merged), to: url)
        }
        try purgeIfDue(source)
    }

    /// 保留最近 keepDays 天（今天 + 前 keepDays-1 天），含 .corrupt sidecar
    public func purge(_ source: TelegraphSource, keepDays: Int = 7) throws {
        let cutoff = oldestRetainedDay(keepDays: keepDays)
        let allFiles = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        let prefix = source.filePrefix
        for file in allFiles where file.lastPathComponent.hasPrefix(prefix) {
            let name = file.lastPathComponent
                .replacingOccurrences(of: ".json", with: "")
                .replacingOccurrences(of: ".corrupt", with: "")
            guard let day = dayFromFile(name: name, prefix: prefix) else { continue }
            if day < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
        lastPurgeDate = Date()
    }

    /// 删除某天文件（测试与清理用）
    public func removeDay(_ source: TelegraphSource, day: String) throws {
        try? fileManager.removeItem(at: fileURL(source: source, day: day))
    }

    /// 今日已清理过则跳过（每日最多一次）
    private func purgeIfDue(_ source: TelegraphSource) throws {
        if let lastPurgeDate,
           shanghaiCalendar.isDate(lastPurgeDate, inSameDayAs: Date()) { return }
        try purge(source)
    }

    // MARK: 内部

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func fileURL(source: TelegraphSource, day: String) -> URL {
        baseURL.appendingPathComponent("\(source.filePrefix)-\(day).json")
    }

    private func dayFiles(for source: TelegraphSource) -> [(String, URL)] {
        guard let files = try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { file in
            let name = file.lastPathComponent
            guard name.hasPrefix(source.filePrefix + "-"), name.hasSuffix(".json"),
                  !name.hasSuffix(".corrupt") else { return nil }
            let day = String(name.dropFirst(source.filePrefix.count + 1).dropLast(5))
            guard day.count == 8, day.allSatisfy(\.isNumber) else { return nil }
            return (day, file)
        }
    }

    private func dayString(of timeInterval: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timeInterval)
        let comps = shanghaiCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private func oldestRetainedDay(keepDays: Int) -> String {
        let today = Date()
        guard let oldest = shanghaiCalendar.date(byAdding: .day, value: -(keepDays - 1), to: today) else {
            return dayString(of: today.timeIntervalSince1970)
        }
        return dayString(of: oldest.timeIntervalSince1970)
    }

    private func dayFromFile(name: String, prefix: String) -> String? {
        guard name.hasPrefix(prefix + "-"), name.count == prefix.count + 9 else { return nil }
        let day = String(name.dropFirst(prefix.count + 1))
        return (day.count == 8 && day.allSatisfy(\.isNumber)) ? day : nil
    }

    /// 原子写：临时文件 + POSIX rename（覆盖已存在目标）
    private func atomicWrite(_ envelope: Envelope, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(envelope)
        let tempURL = url.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if rename(tempURL.path, url.path) != 0 {
            // rename 失败（如跨设备）回退 FileManager.replaceItem（同样具备替换语义）
            do {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } catch {
                throw TelegraphStoreError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func quarantine(_ file: URL) {
        let corruptURL = URL(fileURLWithPath: file.path + ".corrupt")
        try? fileManager.moveItem(at: file, to: corruptURL)
    }
}
