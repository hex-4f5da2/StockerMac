import Foundation

/// 侧边栏分组块：一级分组 + 其下按强度排序的二级分组。
struct GroupStrengthSection: Identifiable, Equatable, Sendable {
    let group: StockGroup
    let children: [StockGroup]
    /// 一级平均涨幅；nil 表示名下暂无行情（排在末尾）。
    let averagePercentage: Double?
    /// 名下股票数（直接归属 + 各二级归属的并集，去重）。
    let memberCount: Int

    var id: UUID { group.id }
}

/// 分组强度引擎：等权平均涨幅排序，纯函数便于独立测试。
enum GroupOrdering {
    /// groupID 的生效范围：一级 = 自身 + 全部二级；二级 = 自身；不存在返回空集。
    static func treeIDs(of groupID: UUID, in groups: [StockGroup]) -> Set<UUID> {
        guard groups.contains(where: { $0.id == groupID }) else { return [] }
        let childIDs = groups.filter { $0.parentID == groupID }.map(\.id)
        return Set([groupID] + childIDs)
    }

    /// 等权平均涨幅：无行情的成员跳过；范围无效或全部无行情返回 nil。
    static func averagePercentage(
        of groupID: UUID,
        items: [WatchItem],
        groups: [StockGroup],
        memberships: [String: Set<UUID>],
        quotes: [String: Quote]
    ) -> Double? {
        let scope = treeIDs(of: groupID, in: groups)
        guard !scope.isEmpty else { return nil }
        let percentages = items.compactMap { item -> Double? in
            guard let itemMemberships = memberships[item.id], !itemMemberships.intersection(scope).isEmpty else {
                return nil
            }
            return quotes[item.id]?.percentage
        }
        guard !percentages.isEmpty else { return nil }
        return percentages.reduce(0, +) / Double(percentages.count)
    }

    /// 名下股票数（并集去重）。
    static func memberCount(
        of groupID: UUID,
        items: [WatchItem],
        groups: [StockGroup],
        memberships: [String: Set<UUID>]
    ) -> Int {
        let scope = treeIDs(of: groupID, in: groups)
        guard !scope.isEmpty else { return 0 }
        return items.reduce(into: 0) { count, item in
            if let itemMemberships = memberships[item.id], !itemMemberships.intersection(scope).isEmpty {
                count += 1
            }
        }
    }

    /// 一级之间与一级内部二级标签的统一排序：
    /// 置顶锁定层 > 有行情（降序）层 > 无行情层；同层同值保持原顺序。
    static func buildSections(
        items: [WatchItem],
        groups: [StockGroup],
        memberships: [String: Set<UUID>],
        quotes: [String: Quote]
    ) -> [GroupStrengthSection] {
        let sectionEntries: [(element: GroupStrengthSection, average: Double?, isPinned: Bool)] = groups
            .filter { $0.parentID == nil }
            .map { primary in
                let children = rankedSorted(
                    groups.filter { $0.parentID == primary.id }
                        .map { child in
                            (
                                element: child,
                                average: averagePercentage(
                                    of: child.id,
                                    items: items,
                                    groups: groups,
                                    memberships: memberships,
                                    quotes: quotes
                                ),
                                isPinned: child.isPinned
                            )
                        }
                )
                let section = GroupStrengthSection(
                    group: primary,
                    children: children,
                    averagePercentage: averagePercentage(
                        of: primary.id,
                        items: items,
                        groups: groups,
                        memberships: memberships,
                        quotes: quotes
                    ),
                    memberCount: memberCount(of: primary.id, items: items, groups: groups, memberships: memberships)
                )
                return (element: section, average: section.averagePercentage, isPinned: primary.isPinned)
            }
        return rankedSorted(sectionEntries)
    }

    /// parentID 悬空或指向二级（会形成三级）时提升为一级。
    static func sanitizeGroups(_ groups: [StockGroup]) -> [StockGroup] {
        let primaryIDs = Set(groups.filter { $0.parentID == nil }.map(\.id))
        return groups.map { group in
            guard let parentID = group.parentID, primaryIDs.contains(parentID) else {
                var promoted = group
                promoted.parentID = nil
                return promoted
            }
            return group
        }
    }

    /// 置顶层 > 有行情降序层 > 无行情层；同层同值保持原顺序。
    private static func rankedSorted<Element>(_ entries: [(element: Element, average: Double?, isPinned: Bool)]) -> [Element] {
        var pinned: [(index: Int, element: Element)] = []
        var quoted: [(index: Int, element: Element, average: Double)] = []
        var unquoted: [(index: Int, element: Element)] = []
        for (index, entry) in entries.enumerated() {
            if entry.isPinned {
                pinned.append((index, entry.element))
            } else if let average = entry.average {
                quoted.append((index, entry.element, average))
            } else {
                unquoted.append((index, entry.element))
            }
        }
        quoted.sort { lhs, rhs in
            if lhs.average != rhs.average { return lhs.average > rhs.average }
            return lhs.index < rhs.index
        }
        return pinned.map(\.element) + quoted.map(\.element) + unquoted.map(\.element)
    }
}
