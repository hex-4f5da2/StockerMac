import AppKit
import Combine
import SwiftUI

@MainActor
enum StatusBarInstaller {
    private static var controller: StatusBarController?

    static func install(store: AppStore) {
        guard controller == nil else { return }
        controller = StatusBarController(store: store)
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let store: AppStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let tickerLabel = NonVibrantTextField(labelWithString: "")
    private let tickerIcon = NonVibrantImageView()
    private let tickerContent = PassthroughStackView()
    private var currentIndex = 0
    private var cancellables = Set<AnyCancellable>()

    init(store: AppStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.image = nil
            button.title = ""

            tickerIcon.image = statusIconImage()
                ?? NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "持仓实时行情")
            tickerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            tickerIcon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tickerIcon.widthAnchor.constraint(equalToConstant: 17),
                tickerIcon.heightAnchor.constraint(equalToConstant: 17)
            ])

            tickerLabel.lineBreakMode = .byClipping
            tickerLabel.maximumNumberOfLines = 1

            tickerContent.orientation = .horizontal
            tickerContent.alignment = .centerY
            tickerContent.spacing = 5
            tickerContent.addArrangedSubview(tickerIcon)
            tickerContent.addArrangedSubview(tickerLabel)
            tickerContent.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(tickerContent)
            NSLayoutConstraint.activate([
                tickerContent.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                tickerContent.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPortfolioView().environmentObject(store)
        )

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.refreshStatusItem()
                }
            }
            .store(in: &cancellables)

        Timer.publish(every: 4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.showNextPosition() }
            }
            .store(in: &cancellables)

        refreshStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showNextPosition() {
        let count = store.positionRows.count
        currentIndex = count == 0 ? 0 : (currentIndex + 1) % count
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        if store.statusBarDisplayMode == .icon {
            setIconOnlyMode()
            updatePopoverSize()
            return
        }

        let rows = store.positionRows
        guard !rows.isEmpty else {
            setTickerTitle("Stocker", color: .labelColor)
            updatePopoverSize()
            return
        }

        let row = rows[currentIndex % rows.count]
        let title = "\(row.displayName) \(Formatters.percent(row.percentage))"
        setTickerTitle(title, color: trendColor(for: row.percentage))
        updatePopoverSize()
    }

    private func setTickerTitle(_ title: String, color: NSColor) {
        tickerLabel.isHidden = false
        tickerContent.spacing = 5
        tickerContent.isHidden = false
        statusItem.button?.image = nil
        tickerIcon.isHidden = false
        tickerIcon.image = statusIconImage()
            ?? NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "持仓实时行情")
        tickerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]
        )
        tickerLabel.attributedStringValue = attributedTitle
        tickerIcon.contentTintColor = color
        statusItem.length = ceil(attributedTitle.size().width) + 31
    }

    private func setIconOnlyMode() {
        tickerContent.isHidden = true
        if let image = statusIconImage() {
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Stocker")
        }
        statusItem.length = NSStatusItem.squareLength
    }

    private func statusIconImage() -> NSImage? {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("StockerMac_StockerMac.bundle")
            .appendingPathComponent("StatusIcon.png")
        let iconURL = packagedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "StatusIcon", withExtension: "png")
        if let url = iconURL,
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.accessibilityDescription = "Stocker"
            return image
        }
        return nil
    }

    private func updatePopoverSize() {
        let count = store.positionRows.count
        let height = count == 0 ? 205 : min(330, 68 + count * 34)
        popover.contentSize = NSSize(width: 360, height: height)
    }

    private func trendColor(for value: Double) -> NSColor {
        guard store.colorPreference != .monochrome else { return .labelColor }
        if value == 0 { return .secondaryLabelColor }
        let up: NSColor = store.colorPreference == .redUp ? .systemRed : .systemGreen
        let down: NSColor = store.colorPreference == .redUp ? .systemGreen : .systemRed
        return value > 0 ? up : down
    }
}

@MainActor
private final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class NonVibrantTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
}

@MainActor
private final class NonVibrantImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}
