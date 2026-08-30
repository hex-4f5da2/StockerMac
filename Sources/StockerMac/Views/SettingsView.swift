import AppKit
import StockerCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var telegraphVM: TelegraphViewModel
    @State private var cacheSizeText = CacheManager.formattedCacheSize()
    @State private var isCleaningCache = false
    @State private var cacheCleanedMessage: String?

    var body: some View {
        Form {
            Section("行情数据") {
                Picker("数据模式", selection: $store.dataMode) {
                    ForEach(MarketDataMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.dataMode) { _, _ in store.applyMarketDataRoute() }

                if store.dataMode == .localStockDB {
                    HStack {
                        TextField("StockDB IP 或主机名", text: $store.stockDBHost)
                            .textFieldStyle(.roundedBorder)
                        Text(":").foregroundStyle(.secondary)
                        TextField("端口", value: $store.stockDBPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("应用") { store.applyMarketDataRoute() }
                    }
                    LabeledContent("当前路由") {
                        Text("http://\(store.stockDBHost):\(store.stockDBPort)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("默认连接本机；也可以填写局域网 StockDB 服务的 IP 和端口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("网络行情源", selection: $store.provider) {
                        ForEach(QuoteProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: store.provider) { _, _ in store.applyMarketDataRoute() }
                    Text("现价与搜索使用所选来源；分时和 K 线使用腾讯行情接口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let lastUpdated = store.lastUpdated {
                    Label("连接正常 · \(lastUpdated.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("通用") {

                Picker("涨跌颜色", selection: $store.colorPreference) {
                    ForEach(ColorSchemePreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: store.colorPreference) { _, _ in store.persist() }

                Picker("菜单栏待机", selection: $store.statusBarDisplayMode) {
                    ForEach(StatusBarDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: store.statusBarDisplayMode) { _, _ in store.persist() }

                VStack(alignment: .leading) {
                    HStack {
                        Text("自动刷新")
                        Spacer()
                        Text("\(Int(store.refreshInterval)) 秒").foregroundStyle(.secondary)
                    }
                    Slider(value: $store.refreshInterval, in: 5...60, step: 5)
                        .onChange(of: store.refreshInterval) { _, _ in store.restartRefreshLoop() }
                }
            }

            Section("存储与缓存") {
                HStack {
                    Text("网络临时缓存")
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                    Button(isCleaningCache ? "清理中…" : "立即清理") {
                        cleanCache()
                    }
                    .disabled(isCleaningCache)
                }
                if let cacheCleanedMessage {
                    Text(cacheCleanedMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text("清理缓存仅清除网络临时响应缓存，不会影响自选股、持仓、分组及提醒设置等个人数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if AppStore.telegraphEnabled {
                Section("电报") {
                    Picker("电报数据源", selection: $telegraphVM.source) {
                        ForEach(TelegraphSource.allCases, id: \.self) { Text($0.title).tag($0) }
                    }

                    Picker("更新间隔", selection: $telegraphVM.refreshInterval) {
                        Text("10 秒").tag(10)
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                    }

                    Picker("通知级别", selection: $telegraphVM.notificationLevel) {
                        ForEach(TelegraphNotificationLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }

                    HStack {
                        Text("通知权限")
                        Spacer()
                        switch telegraphVM.authorizationStatus {
                        case .some(true):
                            Text("已授权").foregroundStyle(.green)
                        case .some(false):
                            Button("打开系统设置") { openSystemSettings() }
                        case .none:
                            Button("启用通知") {
                                Task {
                                    let service = NotificationService()
                                    await service.requestAuthorization()
                                    telegraphVM.refreshAuthorizationStatus(actual: await service.authorizationStatus())
                                }
                            }
                        }
                    }
                    Text("默认仅通知重要消息；财联社使用加红标记，金十使用 important 标记。东方财富不支持该维度（自选股命中仍通知）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("行情来自公开接口，仅供信息展示，不构成投资建议。不同市场资产暂未进行汇率折算。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("Stocker 设置")
        .task {
            cacheSizeText = CacheManager.formattedCacheSize()
            guard AppStore.telegraphEnabled else { return }
            let service = NotificationService()
            telegraphVM.refreshAuthorizationStatus(actual: await service.authorizationStatus())
        }
    }

    private func cleanCache() {
        isCleaningCache = true
        CacheManager.clearCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            cacheSizeText = CacheManager.formattedCacheSize()
            isCleaningCache = false
            cacheCleanedMessage = "缓存已清理完成"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
