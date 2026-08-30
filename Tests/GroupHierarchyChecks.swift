import Foundation

/// 两级分组强度引擎检查：树口径、等权平均、排序规则与 parentID 清洗。
@main
enum GroupHierarchyChecks {
    static func main() throws {
        let battery = StockGroup(name: "电池")
        let ai = StockGroup(name: "AI算力")
        let gold = StockGroup(name: "黄金")
        let solid = StockGroup(name: "固态", parentID: battery.id)
        let lithium = StockGroup(name: "锂矿", parentID: battery.id)
        let vc = StockGroup(name: "VC电解液", parentID: battery.id)
        let cpo = StockGroup(name: "CPO", parentID: ai.id)
        let groups = [gold, battery, solid, lithium, vc, ai, cpo]

        let batteryStock = WatchItem(code: "600000", name: "电池龙头", market: .cn)
        let solidA = WatchItem(code: "600001", name: "固态A", market: .cn)
        let solidB = WatchItem(code: "600002", name: "固态B", market: .cn)
        let solidNoQuote = WatchItem(code: "600003", name: "固态C", market: .cn)
        let lithiumA = WatchItem(code: "600004", name: "锂矿A", market: .cn)
        let cpoA = WatchItem(code: "600005", name: "CPOA", market: .cn)
        let items = [batteryStock, solidA, solidB, solidNoQuote, lithiumA, cpoA]

        let memberships: [String: Set<UUID>] = [
            batteryStock.id: [battery.id],
            solidA.id: [solid.id],
            solidB.id: [solid.id, lithium.id], // 多重归属：既属固态又属锂矿
            solidNoQuote.id: [solid.id],
            lithiumA.id: [lithium.id],
            cpoA.id: [cpo.id]
        ]

        func quote(_ item: WatchItem, percentage: Double) -> Quote {
            Quote(
                code: item.code,
                name: item.name,
                market: item.market,
                current: 10,
                opening: 10,
                close: 10,
                low: 10,
                high: 10,
                change: 0,
                percentage: percentage,
                updatedAt: ""
            )
        }

        let quotes: [String: Quote] = {
            let all: [Quote] = [
                quote(batteryStock, percentage: 2),
                quote(solidA, percentage: 4),
                quote(solidB, percentage: 6),
                quote(lithiumA, percentage: 0),
                quote(cpoA, percentage: 8)
            ]
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()

        // MARK: treeIDs

        precondition(GroupOrdering.treeIDs(of: battery.id, in: groups) == [battery.id, solid.id, lithium.id, vc.id])
        precondition(GroupOrdering.treeIDs(of: solid.id, in: groups) == [solid.id])
        precondition(GroupOrdering.treeIDs(of: UUID(), in: groups).isEmpty)

        // MARK: 等权平均与成员数（树口径）

        // 固态：4 与 6 的均值；无行情的固态C跳过
        precondition(GroupOrdering.averagePercentage(of: solid.id, items: items, groups: groups, memberships: memberships, quotes: quotes) == 5)
        // 电池：直接成员 +2、固态 +4、双重归属 +6、锂矿 0（固态C 无行情跳过，CPO 不在电池范围）-> (2+4+6+0)/4 = 3
        precondition(GroupOrdering.averagePercentage(of: battery.id, items: items, groups: groups, memberships: memberships, quotes: quotes) == 3)
        precondition(GroupOrdering.averagePercentage(of: gold.id, items: items, groups: groups, memberships: memberships, quotes: quotes) == nil)
        // 成员数：多重归属去重 -> 电池 5、固态 3、锂矿 2
        precondition(GroupOrdering.memberCount(of: battery.id, items: items, groups: groups, memberships: memberships) == 5)
        precondition(GroupOrdering.memberCount(of: solid.id, items: items, groups: groups, memberships: memberships) == 3)
        precondition(GroupOrdering.memberCount(of: lithium.id, items: items, groups: groups, memberships: memberships) == 2)

        // MARK: buildSections 排序

        let sections = GroupOrdering.buildSections(items: items, groups: groups, memberships: memberships, quotes: quotes)
        precondition(sections.map(\.group.name) == ["AI算力", "电池", "黄金"]) // 强者在前（AI 均值 8 > 电池 3），无行情沉底
        precondition(sections[0].averagePercentage == 8)
        precondition(sections[1].averagePercentage == 3)
        precondition(sections[2].averagePercentage == nil)
        precondition(sections[1].memberCount == 5)
        // 二级标签同样按强度降序排：固态 5、锂矿 3、VC 无行情
        precondition(sections[1].children.map(\.name) == ["固态", "锂矿", "VC电解液"])
        precondition(sections[0].children.map(\.name) == ["CPO"])

        // MARK: 同值稳定排序

        let tieSolid = StockGroup(name: "固态2", parentID: battery.id)
        let tieItems = [solidA, solidB]
        // 两组平均同为 5（成员相同），保持存储顺序（固态2 在前）
        let tieMemberships: [String: Set<UUID>] = [
            solidA.id: [tieSolid.id, solid.id],
            solidB.id: [solid.id, tieSolid.id]
        ]
        let tieQuotes: [String: Quote] = [
            quote(solidA, percentage: 4).id: quote(solidA, percentage: 4),
            quote(solidB, percentage: 6).id: quote(solidB, percentage: 6)
        ]
        let tieSections = GroupOrdering.buildSections(items: tieItems, groups: [battery, tieSolid, solid], memberships: tieMemberships, quotes: tieQuotes)
        // 固态2 与 固态 平均同为 5，保持存储顺序（固态2 在前）
        precondition(tieSections[0].children.map(\.name) == ["固态2", "固态"])

        // MARK: 置顶锁定：置顶排最前，置顶二级在所属一级块内置顶

        let pinnedBattery = StockGroup(name: "置顶电池", isPinned: true)
        let pinnedSolid = StockGroup(name: "置顶固态", parentID: battery.id, isPinned: true)
        let pinnedAI2 = StockGroup(name: "置顶AI", isPinned: true)
        let pinnedSections = GroupOrdering.buildSections(
            items: items,
            groups: groups + [pinnedBattery, pinnedSolid, pinnedAI2],
            memberships: memberships,
            quotes: quotes
        )
        precondition(pinnedSections.prefix(2).map(\.group.name) == ["置顶电池", "置顶AI"])
        // 置顶的固态应在电池块内最前
        let batterySection = pinnedSections.first { $0.group.name == "电池" }!
        precondition(batterySection.children.first?.name == "置顶固态")
        // 非置顶一级仍按强弱排：AI(8) 仍在电池(3) 前，但置顶电池一直在最前
        let nonPinnedOnly = pinnedSections.filter { !$0.group.isPinned }
        precondition(nonPinnedOnly.map(\.group.name) == ["AI算力", "电池", "黄金"])

        // MARK: sanitizeGroups

        let parent = StockGroup(name: "一级")
        let child = StockGroup(name: "二级", parentID: parent.id)
        let grandchild = StockGroup(name: "孙级", parentID: child.id) // 指向二级，应提升
        let dangling = StockGroup(name: "悬空", parentID: UUID()) // 父不存在，应提升
        let sanitized = GroupOrdering.sanitizeGroups([parent, child, grandchild, dangling])
        precondition(sanitized[0].parentID == nil)
        precondition(sanitized[1].parentID == parent.id)
        precondition(sanitized[2].parentID == nil)
        precondition(sanitized[3].parentID == nil)

        print("Group hierarchy checks passed: tree scope, equal-weight average, deduped count, strength ordering, tie stability and parentID sanitize")
    }
}
