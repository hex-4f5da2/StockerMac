import StockerCore
import SwiftUI

struct TelegraphView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var vm: TelegraphViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.source.supportsImportance {
                categoryBar
                Divider()
            }
            statusBanners
            messageList
        }
        .background(WindowModeResizer(mode: .fullSize))
    }

    // MARK: - 顶栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("数据源", selection: $vm.source) {
                ForEach(TelegraphSource.allCases, id: \.self) { source in
                    Text(source.shortTitle).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 214)

            TextField("搜索标题、正文", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 230)

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(lastUpdatedHelp)

            Button {
                vm.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Button {
                vm.togglePause()
            } label: {
                Image(systemName: vm.state == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(vm.state == .paused ? "继续接收电报" : "暂停接收电报")

            if vm.authorizationStatus != true, vm.notificationLevel.requiresAuthorization {
                Button {
                    Task { await requestAuthorization() }
                } label: {
                    Label("通知", systemImage: "bell.badge")
                }
                .help("启用系统通知")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var statusTitle: String {
        switch vm.state {
        case .bootstrapping: "连接中"
        case .paused: "已暂停"
        case .failed: "连接异常"
        case .idle: "准备中"
        case .backfilling: "补充历史"
        case .polling: "实时"
        }
    }

    private var statusColor: Color {
        switch vm.state {
        case .polling, .backfilling: .green
        case .paused: .orange
        case .failed: .red
        case .idle, .bootstrapping: .secondary
        }
    }

    private var lastUpdatedHelp: String {
        guard let lastUpdated = vm.lastUpdated else { return "等待首次更新" }
        return "最近更新：\(lastUpdated.formatted(date: .omitted, time: .standard))"
    }

    private func requestAuthorization() async {
        let service = NotificationService()
        await service.requestAuthorization()
        vm.refreshAuthorizationStatus(actual: await service.authorizationStatus())
    }

    // MARK: - 分类

    private var categoryBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    categoryChip(title: "全部", isSelected: vm.selectedCategory == nil) {
                        vm.selectedCategory = nil
                    }
                    ForEach(TelegraphCategory.allCases, id: \.self) { category in
                        categoryChip(title: category.title, isSelected: vm.selectedCategory == category) {
                            vm.selectedCategory = vm.selectedCategory == category ? nil : category
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if vm.unreadCount > 0 {
                Divider().frame(height: 16)
                Button("全部已读 · \(vm.unreadCount)") { vm.markAllRead() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StockerTheme.accent)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isSelected ? StockerTheme.accent : Color.primary.opacity(0.065),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态横幅

    @ViewBuilder
    private var statusBanners: some View {
        if let feedError = vm.feedError {
            banner(icon: "exclamationmark.triangle.fill", text: "暂时无法获取新电报，已保留现有内容：\(feedError)", color: .orange)
        }
        if let storageError = vm.storageError {
            banner(icon: "externaldrive.badge.exclamationmark", text: "本地保存异常：\(storageError)", color: .orange)
        }
        if let notificationError = vm.notificationError {
            banner(icon: "bell.slash.fill", text: notificationError, color: .orange)
        }
        if vm.dataGap {
            banner(icon: "ellipsis.circle.fill", text: "部分历史消息可能缺失，已继续接收最新电报", color: .blue)
        }
        if vm.isBackfillPartial {
            banner(icon: "clock.badge.questionmark", text: "受数据源限制，仅展示当前可获取的历史消息", color: .secondary)
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
    }

    // MARK: - 消息流

    private var messageList: some View {
        let watchlistCodes = Set(store.watchlistCodes)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(daySections) { section in
                        Section {
                            ForEach(section.messages) { message in
                                TelegraphMessageRow(
                                    message: message,
                                    isSelected: vm.selectedMessageID == message.id,
                                    isUnread: vm.isUnread(message),
                                    watchlistCodes: watchlistCodes
                                ) {
                                    vm.selectedMessageID = message.id
                                    vm.markRead(through: message)
                                }
                                    .id(message.id)
                                Divider().padding(.leading, 70)
                            }
                        } header: {
                            dayHeader(section.day, count: section.messages.count)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if vm.filteredMessages.isEmpty {
                    emptyState
                }
            }
            .onChange(of: vm.selectedMessageID) { _, newID in
                guard let newID, vm.filteredMessages.contains(where: { $0.id == newID }) else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        let searching = !vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ContentUnavailableView(
            searching ? "没有匹配的电报" : "暂无电报",
            systemImage: searching ? "magnifyingglass" : "newspaper",
            description: Text(searching ? "试试其他关键词或清除筛选条件" : "新消息会自动出现在这里")
        )
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(dayTitle(day))
                .font(.caption.weight(.semibold))
            Text("\(count) 条")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var daySections: [TelegraphDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: vm.filteredMessages) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: $0.ctime))
        }
        return grouped
            .map { TelegraphDaySection(day: $0.key, messages: $0.value.sorted { $0.ctime > $1.ctime }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month(.wide).day())
    }

}

private struct TelegraphDaySection: Identifiable {
    let day: Date
    let messages: [TelegraphMessage]
    var id: Date { day }
}

/// 行内悬停状态必须留在单行中。滚动时指针会依次进入不同的行；如果把该状态放在
/// TelegraphView，SwiftUI 会为每次进入/离开重算整个分组列表，长列表下会明显掉帧。
private struct TelegraphMessageRow: View {
    let message: TelegraphMessage
    let isSelected: Bool
    let isUnread: Bool
    let watchlistCodes: Set<SecurityID>
    let action: () -> Void

    @State private var isHovered = false

    private var displayTitle: String { message.displayTitle }
    private var displayBody: String { message.displayBody }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(timeString)
                        .font(.system(size: 12, weight: isUnread ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(isUnread ? StockerTheme.accent : .secondary)
                    if isUnread {
                        Circle()
                            .fill(StockerTheme.accent)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 48, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if message.isRed {
                            Text("重要")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(StockerTheme.accent, in: Capsule())
                        }
                        Text(displayTitle)
                            .font(.system(size: 14, weight: isUnread || message.isRed ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }

                    if !displayBody.isEmpty {
                        Text(displayBody)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .lineLimit(2)
                    }

                    if !message.stockList.isEmpty || message.readingNum > 0 {
                        metadata
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? StockerTheme.accent : Color.secondary.opacity(0.35))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? StockerTheme.accent.opacity(0.11) : (isHovered ? Color.primary.opacity(0.035) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(StockerTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(isUnread ? "未读，" : "")\(displayTitle)")
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            if !message.stockList.isEmpty {
                let watchlistCount = message.stockList.lazy.filter(watchlistCodes.contains).count
                Label {
                    Text(stockSummary(watchlistCount: watchlistCount))
                } icon: {
                    Image(systemName: watchlistCount > 0 ? "star.fill" : "chart.line.uptrend.xyaxis")
                }
                .foregroundStyle(watchlistCount > 0 ? StockerTheme.accent : Color.secondary.opacity(0.65))
            }
            if message.readingNum > 0 {
                Label(compactReadingCount, systemImage: "eye")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private var timeString: String {
        Date(timeIntervalSince1970: message.ctime)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }

    private func stockSummary(watchlistCount: Int) -> String {
        if watchlistCount > 0 { return "命中自选 \(watchlistCount) 只" }
        let codes = message.stockList.prefix(2).map(\.code).joined(separator: " · ")
        return message.stockList.count > 2 ? "\(codes) 等 \(message.stockList.count) 只" : codes
    }

    private var compactReadingCount: String {
        if message.readingNum >= 10_000 {
            return String(format: "%.1f万", Double(message.readingNum) / 10_000)
        }
        return "\(message.readingNum)"
    }
}
