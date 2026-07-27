import SwiftUI

struct StockSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var results: [SearchSuggestion] = []
    @State private var addedIDs = Set<String>()
    @State private var targetGroupID: UUID?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加自选").font(.title2.bold())
                    Text("支持代码、名称和拼音；多个关键词请用英文逗号分隔")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(20)

            HStack {
                Label("加入分组", systemImage: "folder")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("加入分组", selection: $targetGroupID) {
                    Text("暂不分组").tag(Optional<UUID>.none)
                    ForEach(store.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("例如：600000, 00700, AAPL", text: $keyword)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()

            if keyword.isEmpty {
                ContentUnavailableView("搜索股票", systemImage: "text.magnifyingglass", description: Text("从 A 股、港股和美股中查找"))
            } else if results.isEmpty && !isSearching {
                ContentUnavailableView.search(text: keyword)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("找到 \(results.count) 个结果")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("全部添加") {
                            addedIDs.formUnion(store.add(remainingResults, toGroup: targetGroupID))
                        }
                        .controlSize(.small)
                        .disabled(remainingResults.isEmpty)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9)

                    Divider()

                    List(results) { result in
                        HStack(spacing: 12) {
                            Text(result.market.shortTitle)
                                .font(.caption.bold()).foregroundStyle(StockerTheme.accent)
                                .frame(width: 34, height: 25)
                                .background(StockerTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name).fontWeight(.medium)
                                Text(result.code).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let isAdded = addedIDs.contains(result.id)
                            Button(isAdded ? "已添加" : "添加") {
                                addedIDs.formUnion(store.add([result], toGroup: targetGroupID))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isAdded)
                        }
                        .padding(.vertical, 5)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            targetGroupID = store.selectedGroupID.flatMap { selectedID in
                store.groups.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
        }
        .onChange(of: keyword) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await searchNow()
            }
        }
        .onDisappear { searchTask?.cancel() }
        .onExitCommand { dismiss() }
    }

    private func performSearch() {
        searchTask?.cancel()
        searchTask = Task { await searchNow() }
    }

    private func searchNow() async {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            isSearching = false
            return
        }
        let input = keyword
        isSearching = true
        let found = await store.search(input)
        guard !Task.isCancelled, input == keyword else { return }
        results = found
        addedIDs = []
        isSearching = false
    }

    private var remainingResults: [SearchSuggestion] {
        results.filter { !addedIDs.contains($0.id) }
    }
}
