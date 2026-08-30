import Foundation

/// AppStore 层级行为检查：二级创建、聚合过滤、细分名、级联删除与选中态。
@main
@MainActor
enum GroupHierarchyStoreChecks {
    static func main() {
        let defaults = UserDefaults.standard
        let key = "StockerMac.PersistedState.v1"
        let originalData = defaults.data(forKey: key)
        defer {
            if let originalData { defaults.set(originalData, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let battery = StockGroup(name: "电池")
        let initial = PersistedState(
            items: [],
            provider: .tencent,
            refreshInterval: 10,
            colorPreference: .redUp,
            groups: [battery]
        )
        defaults.set(try! JSONEncoder().encode(initial), forKey: key)

        let store = AppStore()

        // 建二级分组：父级合法 -> 固态挂到电池下
        guard let solid = store.createGroup(named: "固态", parentID: battery.id) else {
            preconditionFailure("创建二级分组失败")
        }
        precondition(solid.parentID == battery.id)
        precondition(store.selectedGroupID == solid.id)
        precondition(store.groupSections.count == 1)
        precondition(store.groupSections[0].children.map(\.name) == ["固态"])

        // 父级是二级 -> 拒绝嵌套，回退为一级
        let nested = store.createGroup(named: "嵌套", parentID: solid.id)
        precondition(nested?.parentID == nil, "父级为二级时应创建为一级")

        // 重名拒绝（跨级全局唯一）
        precondition(store.createGroup(named: "固态") == nil)

        // 加股票：一直接挂电池，一挂固态
        let direct = SearchSuggestion(code: "SH600000", name: "电池龙头", market: .cn)
        let solidStock = SearchSuggestion(code: "SH600001", name: "固态A", market: .cn)
        _ = store.add([direct], toGroup: battery.id)
        store.selectGroup(solid.id)
        _ = store.add([solidStock], toGroup: solid.id)

        // 选中二级：只看固态成员
        precondition(store.selectedGroupID == solid.id)
        precondition(store.rows.map(\.id) == [solidStock.id])
        precondition(store.selectedCollectionTitle == "电池 · 固态")

        // 选中一级：聚合名下全部（直接 + 二级）
        store.selectGroup(battery.id)
        precondition(Set(store.rows.map(\.id)) == Set([direct.id, solidStock.id]))
        precondition(store.itemCount(in: battery.id) == 2)

        // 细分列：直接挂一级的显示为空，固态成员显示「固态」
        precondition(store.subgroupNames(for: direct.id, underPrimary: battery.id).isEmpty)
        precondition(store.subgroupNames(for: solidStock.id, underPrimary: battery.id) == ["固态"])

        // 小窗聚合口径
        precondition(Set(store.rowsForGroup(battery.id).map(\.id)) == Set([direct.id, solidStock.id]))
        precondition(store.rowsForGroup(solid.id).map(\.id) == [solidStock.id])

        // 级联删除：删电池连带固态，股票保留、脱离分组关系
        store.deleteGroup(battery.id)
        precondition(store.groupSections.map(\.group.name) == ["嵌套"])
        precondition(store.selectedGroupID == nil)
        precondition(store.items.count == 2)
        precondition(store.items.allSatisfy { store.groupIDs(for: $0.id).isEmpty })
        precondition(store.ungroupedItemCount == 2)

        // MARK: 移动分组（挂靠/提升）

        // 重建：电池 + AI 两个一级，固态挂在电池下，股票挂在固态
        guard let battery2 = store.createGroup(named: "电池"),
              let ai2 = store.createGroup(named: "AI算力"),
              let solid2 = store.createGroup(named: "固态", parentID: battery2.id) else {
            preconditionFailure("重建分组失败")
        }
        precondition(solid2.parentID == battery2.id)
        store.toggleMembership(itemID: solidStock.id, groupID: solid2.id)
        precondition(store.itemCount(in: battery2.id) == 1)

        // 挂靠：固态 移到 AI 下，股票跟随
        store.moveGroup(solid2.id, underParent: ai2.id)
        precondition(store.parentGroup(of: solid2.id)?.id == ai2.id)
        precondition(store.itemCount(in: battery2.id) == 0)
        precondition(store.itemCount(in: ai2.id) == 1)
        precondition(store.belongsToGroup(itemID: solidStock.id, groupID: solid2.id))

        // 提升：固态 变回一级
        store.moveGroup(solid2.id, underParent: nil)
        precondition(store.parentGroup(of: solid2.id) == nil)
        precondition(store.itemCount(in: ai2.id) == 0)

        // 带二级的一级挂靠：固态（现在是一级且无子级）下再建 VC，然后把固态挂到电池下 -> VC 自动升一级
        _ = store.createGroup(named: "VC电解液", parentID: solid2.id)
        precondition(store.childGroups(of: solid2.id).count == 1)
        store.moveGroup(solid2.id, underParent: battery2.id)
        precondition(store.parentGroup(of: solid2.id)?.id == battery2.id)
        precondition(store.childGroups(of: solid2.id).isEmpty, "原二级应升级为一级")
        precondition(store.groups.first { $0.name == "VC电解液" }?.parentID == nil)
        precondition(store.itemCount(in: battery2.id) == 1, "股票跟随挂靠")

        // 无效目标：挂到自己、挂到二级 -> 拒绝
        store.moveGroup(solid2.id, underParent: solid2.id)
        precondition(store.parentGroup(of: solid2.id)?.id == battery2.id)
        guard let vcGroup = store.groups.first(where: { $0.name == "VC电解液" }) else {
            preconditionFailure("找不到 VC电解液")
        }
        store.moveGroup(vcGroup.id, underParent: solid2.id)
        precondition(vcGroup.parentID == nil)

        store.flushPersistForTesting()
        let saved = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(saved.groups.contains { $0.name == "固态" && $0.parentID == battery2.id })
        precondition(saved.groups.contains { $0.name == "VC电解液" && $0.parentID == nil })
        precondition(saved.groups.allSatisfy { group in
            group.parentID == nil || saved.groups.contains { parent in
                parent.id == group.parentID && parent.parentID == nil
            }
        }, "所有 parentID 都必须指向一级分组")

        // MARK: 置顶锁定（AppStore 语义）

        guard let topGroup = store.groups.first(where: { $0.name == "电池" }) else {
            preconditionFailure("找不到 电池 分组")
        }
        precondition(!topGroup.isPinned)
        store.toggleGroupPinned(topGroup.id)
        precondition(store.groups.first(where: { $0.id == topGroup.id })?.isPinned == true)
        precondition(store.groupSections.first?.group.id == topGroup.id, "置顶后应在最前")
        store.flushPersistForTesting()
        let pinSaved = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(pinSaved.groups.first(where: { $0.id == topGroup.id })?.isPinned == true)
        store.toggleGroupPinned(topGroup.id)
        precondition(store.groups.first(where: { $0.id == topGroup.id })?.isPinned == false)

        print("Group hierarchy store checks passed: secondary creation, aggregate filtering, subgroup names, cascade delete, group moving and selection fallback")
    }
}
