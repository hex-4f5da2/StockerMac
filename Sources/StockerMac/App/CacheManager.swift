import Foundation

enum CacheManager {
    /// 计算当前网络缓存大小（字节）
    static func currentCacheSizeBytes() -> Int {
        let cache = URLCache.shared
        return cache.currentDiskUsage + cache.currentMemoryUsage
    }

    /// 格式化缓存大小（如 "0 KB", "1.2 MB"）
    static func formattedCacheSize() -> String {
        let bytes = Int64(currentCacheSizeBytes())
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    /// 清空所有网络临时缓存
    static func clearCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}
