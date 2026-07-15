import AppKit
import SwiftUI

struct CompactGroupView: View {
    @EnvironmentObject private var store: AppStore

    let groupID: UUID
    @Binding var isAlwaysOnTop: Bool
    let onRestore: () -> Void

    private var group: StockGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var rows: [QuoteRow] {
        store.allRows.filter { store.belongsToGroup(itemID: $0.id, groupID: groupID) }
    }

    private let percentageColumnWidth: CGFloat = 72
    private let controlsColumnWidth: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView("分组暂无股票", systemImage: "folder", description: Text("退出小窗后可向分组添加股票"))
                } else {
                    HStack(spacing: 6) {
                        Text("股票")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("涨跌幅")
                            .frame(width: percentageColumnWidth, alignment: .leading)
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
                        .frame(width: controlsColumnWidth, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    Divider()

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(spacing: 6) {
                                    Text(row.displayName)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if row.quote != nil {
                                        TrendText(value: row.percentage, text: Formatters.percent(row.percentage))
                                            .fontWeight(.semibold)
                                            .frame(width: percentageColumnWidth, alignment: .leading)
                                    } else {
                                        Text("—")
                                            .foregroundStyle(.secondary)
                                            .frame(width: percentageColumnWidth, alignment: .leading)
                                    }
                                    Color.clear.frame(width: controlsColumnWidth, height: 1)
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
        .frame(minWidth: 220, minHeight: 150)
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

            if store.groups.isEmpty {
                ContentUnavailableView("还没有分组", systemImage: "folder.badge.plus", description: Text("请先在左侧边栏创建分组"))
            } else {
                List(store.groups, selection: $selection) { group in
                    HStack {
                        Label(group.name, systemImage: "folder")
                        Spacer()
                        Text("\(store.itemCount(in: group.id)) 只")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if selection == group.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(StockerTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .tag(group.id)
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
            if selection == nil { selection = store.groups.first?.id }
        }
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
            let height = min(440, max(150, 32 + rowCount * 34))
            contentSize = NSSize(width: 230, height: height)
            window.contentMinSize = NSSize(width: 220, height: 150)
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
