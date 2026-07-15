import SwiftUI

struct BatchDeleteView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let candidateIDs: [String]

    @State private var selectedIDs = Set<String>()
    @State private var searchText = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()

            if candidateRows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(candidateRows) { row in
                    Toggle(isOn: selectionBinding(for: row.id)) {
                        HStack(spacing: 12) {
                            Text(row.item.market.shortTitle)
                                .font(.caption.bold())
                                .foregroundStyle(StockerTheme.accent)
                                .frame(width: 34, height: 25)
                                .background(StockerTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.displayName).fontWeight(.medium)
                                Text("\(row.item.code) · \(row.item.market.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if row.hasPosition {
                                Label("有持仓", systemImage: "briefcase.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(width: 600, height: 600)
        .alert("确认删除 \(selectedIDs.count) 只股票？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                store.remove(selectedIDs)
                dismiss()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("批量删除").font(.title2.bold())
                Text("从“\(store.selectedCollectionTitle)”中选择要移除的股票")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(allCandidatesSelected ? "取消全选" : "全选") {
                if allCandidatesSelected {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(candidateIDs)
                }
            }
            .disabled(candidateIDs.isEmpty)
        }
        .padding(20)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或代码", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text(selectedIDs.isEmpty ? "尚未选择股票" : "已选择 \(selectedIDs.count) 只")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("删除所选", role: .destructive) { isConfirmingDelete = true }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
        }
        .padding(16)
    }

    private var allRows: [QuoteRow] {
        let candidates = Set(candidateIDs)
        return store.allRows.filter { candidates.contains($0.id) }
    }

    private var candidateRows: [QuoteRow] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allRows }
        return allRows.filter {
            $0.displayName.localizedCaseInsensitiveContains(keyword)
                || $0.item.code.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var allCandidatesSelected: Bool {
        !candidateIDs.isEmpty && Set(candidateIDs).isSubset(of: selectedIDs)
    }

    private var selectedPositionCount: Int {
        allRows.filter { selectedIDs.contains($0.id) && $0.hasPosition }.count
    }

    private var deleteConfirmationMessage: String {
        let base = "所选股票将从自选和所有分组中移除。"
        guard selectedPositionCount > 0 else { return base + "此操作无法撤销。" }
        return base + "其中 \(selectedPositionCount) 只有持仓记录，持仓数据也会一并删除。此操作无法撤销。"
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected { selectedIDs.insert(id) }
                else { selectedIDs.remove(id) }
            }
        )
    }
}
