import AppKit
import SwiftUI

struct CompactGroupView: View {
    @EnvironmentObject private var store: AppStore

    let groupID: UUID
    @Binding var isAlwaysOnTop: Bool
    @Binding var percentageSortMode: QuotePercentageSortMode
    let onRestore: () -> Void

    private var group: StockGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var rows: [QuoteRow] {
        percentageSortMode.sorted(store.rowsForGroup(groupID))
    }

    private let nameColumnWidth: CGFloat = 82
    private let percentageColumnWidth: CGFloat = 72
    private let columnSpacing: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView("分组暂无股票", systemImage: "folder", description: Text("退出小窗后可向分组添加股票"))
                } else {
                    HStack(spacing: 6) {
                        Text(group?.name ?? "小窗行情")
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 2) {
                            Button {
                                isAlwaysOnTop.toggle()
                            } label: {
                                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                                    .foregroundStyle(isAlwaysOnTop ? StockerTheme.accent : .secondary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .help(isAlwaysOnTop ? "取消窗口置顶" : "将小窗保持在其他窗口上方")
                            .accessibilityLabel(isAlwaysOnTop ? "取消窗口置顶" : "窗口置顶")

                            Button(action: onRestore) {
                                Image(systemName: "rectangle.expand.vertical")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .help("退出小窗模式")
                            .accessibilityLabel("恢复完整窗口")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    Divider()

                    HStack(spacing: columnSpacing) {
                        Text("股票")
                            .frame(width: nameColumnWidth, alignment: .leading)
                        QuotePercentageSortMenu(selection: $percentageSortMode)
                            .frame(width: percentageColumnWidth, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                    Divider()

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(spacing: columnSpacing) {
                                    Text(row.displayName)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .frame(width: nameColumnWidth, alignment: .leading)

                                    if row.quote != nil {
                                        TrendText(value: row.percentage, text: Formatters.percent(row.percentage))
                                            .fontWeight(.semibold)
                                            .frame(width: percentageColumnWidth, alignment: .trailing)
                                    } else {
                                        Text("—")
                                            .foregroundStyle(.secondary)
                                            .frame(width: percentageColumnWidth, alignment: .trailing)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 34)

                                if row.id != rows.last?.id {
                                    Divider().padding(.leading, 10)
                                }
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(minWidth: 180, minHeight: 150)
        .background(WindowModeResizer(mode: .compact(
            rowCount: rows.count,
            title: group?.name ?? "小窗行情",
            isAlwaysOnTop: isAlwaysOnTop
        )))
    }
}

struct CompactGroupPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UUID?
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("选择小窗分组").font(.title2.bold())
                Text("小窗中只展示该分组的股票名称和涨跌幅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            if store.groupSections.isEmpty {
                ContentUnavailableView("还没有分组", systemImage: "folder.badge.plus", description: Text("请先在左侧边栏创建分组"))
            } else {
                List(selection: $selection) {
                    ForEach(store.groupSections) { section in
                        compactGroupRow(
                            name: section.group.name,
                            icon: "folder",
                            count: section.memberCount,
                            tag: section.group.id
                        )
                        ForEach(section.children) { child in
                            compactGroupRow(
                                name: child.name,
                                icon: "tag",
                                count: store.itemCount(in: child.id),
                                tag: child.id
                            )
                            .padding(.leading, 16)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("进入小窗", action: onEnter)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .onAppear {
            if selection == nil { selection = store.groupSections.first?.group.id }
        }
    }

    private func compactGroupRow(name: String, icon: String, count: Int, tag: UUID) -> some View {
        HStack {
            Label {
                Text(name)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(count) 只")
                .font(.caption)
                .foregroundStyle(.secondary)
            if selection == tag {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(StockerTheme.accent)
            }
        }
        .contentShape(Rectangle())
        .tag(tag)
    }
}

enum WindowDisplayMode: Equatable {
    case fullSize
    case compact(rowCount: Int, title: String, isAlwaysOnTop: Bool)
}

struct WindowModeResizer: NSViewRepresentable {
    let mode: WindowDisplayMode

    final class Coordinator {
        var appliedMode: WindowDisplayMode?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.appliedMode != mode else { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            resize(window)
            context.coordinator.appliedMode = mode
        }
    }

    private func resize(_ window: NSWindow) {
        guard MainWindowRegistry.register(window) else { return }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let contentSize: NSSize
        switch mode {
        case .fullSize:
            contentSize = NSSize(width: 1280, height: 780)
            window.contentMinSize = NSSize(width: 1060, height: 680)
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            window.level = .normal
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            setStandardWindowButtons(hidden: false, in: window)
        case let .compact(rowCount, title, isAlwaysOnTop):
            let height = min(440, max(176, 58 + rowCount * 34))
            contentSize = NSSize(width: 180, height: height)
            window.contentMinSize = NSSize(width: 180, height: 176)
            window.styleMask.remove([.titled, .closable, .miniaturizable])
            window.title = title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = isAlwaysOnTop ? .floating : .normal
            setStandardWindowButtons(hidden: true, in: window)
        }

        guard abs(window.contentView?.frame.width ?? 0 - contentSize.width) > 1
                || abs(window.contentView?.frame.height ?? 0 - contentSize.height) > 1 else { return }

        let top = window.frame.maxY
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = window.frame
        frame.size = frameSize
        frame.origin.y = top - frameSize.height
        window.setFrame(frame, display: true, animate: true)
    }

    private func setStandardWindowButtons(hidden: Bool, in window: NSWindow) {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = hidden
        }
    }
}
