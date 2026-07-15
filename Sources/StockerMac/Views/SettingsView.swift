import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Picker("行情数据源", selection: $store.provider) {
                ForEach(QuoteProvider.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: store.provider) { _, _ in store.restartRefreshLoop() }

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

            Text("行情来自公开接口，仅供信息展示，不构成投资建议。不同市场资产暂未进行汇率折算。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 350)
        .navigationTitle("Stocker 设置")
    }
}
