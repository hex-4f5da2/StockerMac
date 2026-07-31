import AppKit
import SwiftUI
import Carbon.HIToolbox

struct StockSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var results: [SearchSuggestion] = []
    @State private var addedIDs = Set<String>()
    @State private var targetGroupID: UUID?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedResultID: String?
    @FocusState private var isKeywordFocused: Bool

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
                    .keyboardShortcut(.cancelAction)
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
                    .focused($isKeywordFocused)
                    .onSubmit { submitSearchOrSelection() }
                    .background {
                        SearchArrowKeyHandler(isEnabled: isKeywordFocused) { offset in
                            moveSelection(by: offset)
                        }
                    }
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
                            addAllResults()
                        }
                        .controlSize(.small)
                        .disabled(remainingResults.isEmpty)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9)

                    Divider()

                    ScrollViewReader { proxy in
                        List(results, selection: $selectedResultID) { result in
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
                                    addResult(result)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(isAdded)
                            }
                            .padding(.vertical, 5)
                            .tag(result.id)
                            .id(result.id)
                        }
                        .listStyle(.inset)
                        .onChange(of: selectedResultID) { _, resultID in
                            guard let resultID else { return }
                            Task { @MainActor in
                                proxy.scrollTo(resultID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            targetGroupID = store.selectedGroupID.flatMap { selectedID in
                store.groups.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            focusKeywordUsingEnglishInput()
        }
        .onChange(of: keyword) { _, _ in
            searchTask?.cancel()
            selectedResultID = nil
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

    private func submitSearchOrSelection() {
        if let selectedResult {
            addResult(selectedResult)
        } else {
            performSearch()
        }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        guard let selectedResultID,
              let currentIndex = results.firstIndex(where: { $0.id == selectedResultID }) else {
            self.selectedResultID = results.first?.id
            return
        }
        let nextIndex = min(max(currentIndex + offset, results.startIndex), results.index(before: results.endIndex))
        self.selectedResultID = results[nextIndex].id
    }

    private func addResult(_ result: SearchSuggestion) {
        let added = store.add([result], toGroup: targetGroupID)
        guard !added.isEmpty else { return }
        resetSearch()
    }

    private func addAllResults() {
        let added = store.add(remainingResults, toGroup: targetGroupID)
        guard !added.isEmpty else { return }
        resetSearch()
    }

    private func resetSearch() {
        searchTask?.cancel()
        keyword = ""
        results = []
        addedIDs = []
        selectedResultID = nil
        isSearching = false
        focusKeywordUsingEnglishInput()
    }

    private func focusKeywordUsingEnglishInput() {
        if let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(source)
        }
        Task { @MainActor in
            isKeywordFocused = true
        }
    }

    private func searchNow() async {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selectedResultID = nil
            isSearching = false
            return
        }
        let input = keyword
        isSearching = true
        let found = await store.search(input)
        guard !Task.isCancelled, input == keyword else { return }
        results = found
        addedIDs = []
        selectedResultID = found.first?.id
        isSearching = false
    }

    private var selectedResult: SearchSuggestion? {
        guard let selectedResultID else { return nil }
        return results.first { $0.id == selectedResultID }
    }

    private var remainingResults: [SearchSuggestion] {
        results.filter { !addedIDs.contains($0.id) }
    }
}

private struct SearchArrowKeyHandler: NSViewRepresentable {
    let isEnabled: Bool
    let onMove: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onMove: onMove)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var isEnabled: Bool
        var onMove: (Int) -> Void
        private var monitor: Any?

        init(isEnabled: Bool, onMove: @escaping (Int) -> Void) {
            self.isEnabled = isEnabled
            self.onMove = onMove
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      event.window === self.hostView?.window else {
                    return event
                }

                let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(blockedModifiers).isEmpty else {
                    return event
                }

                switch Int(event.keyCode) {
                case kVK_UpArrow:
                    self.onMove(-1)
                    return nil
                case kVK_DownArrow:
                    self.onMove(1)
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
