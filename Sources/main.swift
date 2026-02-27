import AppKit
import ApplicationServices
import Carbon
import IOKit.ps

@main
final class ElCapitanReskinApp: NSObject, NSApplicationDelegate {
    var dockOverlayController: DockOverlayController?
    private var topBarOverlayController: TopBarOverlayController?
    var overviewController: OverviewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AccessibilityService.shared.ensureTrusted(prompt: true)

        dockOverlayController = DockOverlayController()
        topBarOverlayController = TopBarOverlayController()
        overviewController = OverviewController()

        HotKeyService.shared.register()

        InvasiveSystemTweaks.applyRecommendedTweaks()

        MenuBarExtraController.shared.install()
    }
}

final class AccessibilityService {
    static let shared = AccessibilityService()

    func ensureTrusted(prompt: Bool) {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: prompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func windows(for app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }

    func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return "" }
        return title
    }

    func raise(window: AXUIElement) {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    func setFocusedWindow(_ window: AXUIElement, for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        raise(window: window)
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }
}

final class OverlayWindow: NSWindow {
    init(frame: CGRect, level: NSWindow.Level) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.level = level
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DockOverlayController {
    private let window: OverlayWindow
    private let viewController: DockViewController

    init() {
        let screenFrame = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 86
        let frame = CGRect(x: 0, y: 0, width: screenFrame.width, height: height)

        window = OverlayWindow(frame: frame, level: .statusBar)
        window.setFrameOrigin(CGPoint(x: screenFrame.minX, y: screenFrame.minY))

        viewController = DockViewController()
        window.contentViewController = viewController
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRunningApps),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRunningApps),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        updateRunningApps()
    }

    func toggleVisibility() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    @objc private func updateRunningApps() {
        viewController.update(runningApps: NSWorkspace.shared.runningApplications)
    }
}

final class DockViewController: NSViewController {
    private let blur = NSVisualEffectView()
    private let stack = NSStackView()
    private var itemViews: [DockItemView] = []

    private var pinnedBundleIDs: [String] = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.Music"
    ]

    override func loadView() {
        view = NSView()

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillProportionally
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        blur.addSubview(stack)
        view.addSubview(blur)

        blur.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blur.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            blur.heightAnchor.constraint(equalToConstant: 72),
            blur.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.95),

            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
    }

    func update(runningApps: [NSRunningApplication]) {
        let pinned = pinnedBundleIDs.compactMap { id in
            runningApps.first(where: { $0.bundleIdentifier == id }) ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id })
        }

        let runningNonPinned = runningApps
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let id = app.bundleIdentifier else { return true }
                return !pinnedBundleIDs.contains(id)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let items: [DockItem] = (pinned + runningNonPinned).compactMap { app in
            guard let url = app.bundleURL else { return nil }
            return DockItem(
                app: app,
                url: url,
                isRunning: app.isFinishedLaunching && !app.isTerminated
            )
        }

        rebuild(items: items)
    }

    private func rebuild(items: [DockItem]) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        for item in items {
            let v = DockItemView(item: item)
            v.onActivate = { [weak self] item in
                self?.activate(item: item)
            }
            itemViews.append(v)
            stack.addArrangedSubview(v)
        }
    }

    private func activate(item: DockItem) {
        if let app = item.app, app.isFinishedLaunching, !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: config)
    }
}

struct DockItem {
    let app: NSRunningApplication?
    let url: URL
    let isRunning: Bool
}

final class DockItemView: NSView {
    var onActivate: ((DockItem) -> Void)?

    private let item: DockItem
    private let imageView = NSImageView()
    private let runningDot = NSView()

    private var trackingArea: NSTrackingArea?

    init(item: DockItem) {
        self.item = item
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10

        imageView.image = item.app?.icon ?? NSWorkspace.shared.icon(forFile: item.url.path)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 2
        runningDot.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: item.isRunning ? 0.75 : 0).cgColor

        addSubview(imageView)
        addSubview(runningDot)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        runningDot.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 52),
            heightAnchor.constraint(equalToConstant: 52),

            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            imageView.widthAnchor.constraint(equalToConstant: 44),
            imageView.heightAnchor.constraint(equalToConstant: 44),

            runningDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            runningDot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            runningDot.widthAnchor.constraint(equalToConstant: 8),
            runningDot.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let trackingArea { addTrackingArea(trackingArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        animateHover(hover: true)
    }

    override func mouseExited(with event: NSEvent) {
        animateHover(hover: false)
    }

    private func animateHover(hover: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: hover ? 0.10 : 0).cgColor
            animator().setFrameSize(CGSize(width: hover ? 60 : 52, height: hover ? 60 : 52))
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?(item)
    }
}

final class TopBarOverlayController {
    private let window: OverlayWindow
    private let viewController: TopBarViewController

    init() {
        let screenFrame = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 28
        let frame = CGRect(x: 0, y: screenFrame.maxY - height, width: screenFrame.width, height: height)

        window = OverlayWindow(frame: frame, level: .statusBar)
        window.setFrameOrigin(CGPoint(x: screenFrame.minX, y: screenFrame.maxY - height))
        window.hasShadow = false

        viewController = TopBarViewController()
        window.contentViewController = viewController
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateFrontmost),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        updateFrontmost()
    }

    @objc private func updateFrontmost() {
        viewController.setFrontmost(app: AccessibilityService.shared.frontmostApplication())
    }
}

final class TopBarViewController: NSViewController {
    private let blur = NSVisualEffectView()

    private let appleButton = NSButton(title: "", target: nil, action: nil)
    private let appNameLabel = NSTextField(labelWithString: "")

    private let rightStack = NSStackView()
    private let batteryLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")

    private var timer: Timer?

    override func loadView() {
        view = NSView()

        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active

        appleButton.bezelStyle = .texturedRounded
        appleButton.isBordered = false
        appleButton.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        appleButton.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        appleButton.target = self
        appleButton.action = #selector(openAppleMenu)

        appNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        appNameLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)

        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 10

        batteryLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        batteryLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)

        clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        clockLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)

        rightStack.addArrangedSubview(batteryLabel)
        rightStack.addArrangedSubview(clockLabel)

        view.addSubview(blur)
        view.addSubview(appleButton)
        view.addSubview(appNameLabel)
        view.addSubview(rightStack)

        blur.translatesAutoresizingMaskIntoConstraints = false
        appleButton.translatesAutoresizingMaskIntoConstraints = false
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            appleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            appleButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            appNameLabel.leadingAnchor.constraint(equalTo: appleButton.trailingAnchor, constant: 10),
            appNameLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
            self?.updateBattery()
        }
        updateClock()
        updateBattery()
    }

    func setFrontmost(app: NSRunningApplication?) {
        let name = app?.localizedName ?? ""
        appNameLabel.stringValue = name
    }

    @objc private func openAppleMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "About ElCapitanReskin", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Toggle Overview", action: #selector(toggleOverview), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Dock", action: #selector(toggleDock), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: appleButton)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    @objc private func toggleOverview() {
        (NSApp.delegate as? ElCapitanReskinApp)?.overviewController?.toggle()
    }

    @objc private func toggleDock() {
        (NSApp.delegate as? ElCapitanReskinApp)?.dockOverlayController?.toggleVisibility()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateClock() {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM  h:mm a"
        clockLabel.stringValue = df.string(from: Date())
    }

    private func updateBattery() {
        let percent = BatteryService.shared.currentBatteryPercent()
        if let percent {
            batteryLabel.stringValue = "\(percent)%"
        } else {
            batteryLabel.stringValue = ""
        }
    }
}

final class OverviewController {
    private var window: OverlayWindow?

    func toggle() {
        if let window {
            window.orderOut(nil)
            self.window = nil
            return
        }

        guard let screen = NSScreen.main else { return }
        let win = OverlayWindow(frame: screen.frame, level: .screenSaver)
        win.hasShadow = false
        win.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.35)

        let vc = OverviewViewController()
        win.contentViewController = vc
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

struct AppLaunchItem {
    let url: URL
    let title: String
}

final class ApplicationIndex {
    static let shared = ApplicationIndex()

    private var cached: [URL]?

    func allApplications() -> [URL] {
        if let cached { return cached }

        // Fast-ish index from common locations. (No Spotlight dependency.)
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var apps: [URL] = []
        for root in roots {
            let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in paths where url.pathExtension == "app" {
                apps.append(url)
            }
        }

        let deduped = Array(Set(apps)).sorted { $0.path < $1.path }
        cached = deduped
        return deduped
    }
}

final class LauncherController {
    static let shared = LauncherController()

    private var window: OverlayWindow?

    func toggle() {
        if let window {
            window.orderOut(nil)
            self.window = nil
            return
        }

        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 620
        let origin = CGPoint(x: screen.frame.midX - width / 2, y: screen.frame.midY + 160)
        let win = OverlayWindow(frame: CGRect(origin: origin, size: CGSize(width: width, height: 160)), level: .floating)
        win.hasShadow = true

        let vc = LauncherViewController()
        win.contentViewController = vc
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(vc.searchField)

        self.window = win
    }
}

final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let blur = NSVisualEffectView()
    let searchField = NSSearchField()
    let tableView = NSTableView()

    private var results: [AppLaunchItem] = []

    override func loadView() {
        view = NSView()

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14

        searchField.placeholderString = "Search apps"
        searchField.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        searchField.focusRingType = .none
        searchField.delegate = self

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.title = ""
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self

        scroll.documentView = tableView

        blur.addSubview(searchField)
        blur.addSubview(scroll)
        view.addSubview(blur)

        blur.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            searchField.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: blur.topAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -10)
        ])

        updateResults(query: "")
    }

    func controlTextDidChange(_ obj: Notification) {
        updateResults(query: searchField.stringValue)
    }

    private func updateResults(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let apps = ApplicationIndex.shared.allApplications()

        if q.isEmpty {
            results = apps.prefix(20).map { AppLaunchItem(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
        } else {
            results = apps
                .map { AppLaunchItem(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
                .filter { $0.title.lowercased().contains(q) }
                .prefix(30)
                .map { $0 }
        }

        tableView.reloadData()

        if tableView.selectedRow < 0, results.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]

        let v = NSTableCellView()
        let img = NSImageView()
        img.image = NSWorkspace.shared.icon(forFile: item.url.path)
        img.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: item.title)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)

        v.addSubview(img)
        v.addSubview(label)
        img.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 20),
            img.heightAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])

        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // no-op; we activate on Return
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            view.window?.orderOut(nil)
            return
        }

        if event.keyCode == 36 { // Return
            let row = tableView.selectedRow
            if row >= 0, row < results.count {
                let item = results[row]
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: item.url, configuration: config)
                view.window?.orderOut(nil)
            }
            return
        }

        super.keyDown(with: event)
    }
}

final class OverviewViewController: NSViewController {
    private let title = NSTextField(labelWithString: "Window Overview")
    private let hint = NSTextField(labelWithString: "Press Esc to close")

    private let scrollView = NSScrollView()
    private let listStack = NSStackView()

    override func loadView() {
        view = NSView()

        title.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)

        hint.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        hint.textColor = NSColor(calibratedWhite: 1, alpha: 0.75)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = listStack

        view.addSubview(title)
        view.addSubview(hint)
        view.addSubview(scrollView)

        title.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
            scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrollView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.65),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36)
        ])

        rebuildWindowList()
    }

    private func rebuildWindowList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in apps {
            let windows = AccessibilityService.shared.windows(for: app)
            for window in windows {
                let title = AccessibilityService.shared.title(of: window)
                let button = OverviewWindowButton(app: app, window: window, title: title)
                button.onSelect = { [weak self] app, window in
                    AccessibilityService.shared.setFocusedWindow(window, for: app)
                    self?.view.window?.orderOut(nil)
                }
                listStack.addArrangedSubview(button)
            }
        }

        if listStack.arrangedSubviews.isEmpty {
            let label = NSTextField(labelWithString: "No windows found. Ensure Accessibility permission is granted.")
            label.textColor = NSColor(calibratedWhite: 1, alpha: 0.75)
            listStack.addArrangedSubview(label)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            view.window?.orderOut(nil)
        }
    }
}

final class OverviewWindowButton: NSView {
    var onSelect: ((NSRunningApplication, AXUIElement) -> Void)?

    private let app: NSRunningApplication
    private let window: AXUIElement

    private let blur = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(app: NSRunningApplication, window: AXUIElement, title: String) {
        self.app = app
        self.window = window
        super.init(frame: .zero)

        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10

        iconView.image = app.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.stringValue = (app.localizedName ?? "") + (title.isEmpty ? "" : " — \(title)")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(blur)
        blur.addSubview(iconView)
        blur.addSubview(titleLabel)

        blur.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),

            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: blur.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onSelect?(app, window)
    }
}

final class BatteryService {
    static let shared = BatteryService()

    func currentBatteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for ps in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }
            return Int((Double(current) / Double(max)) * 100.0)
        }

        return nil
    }
}

final class MenuBarExtraController {
    static let shared = MenuBarExtraController()

    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "⌘"

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Dock", action: #selector(toggleDock), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Overview", action: #selector(toggleOverview), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Launcher", action: #selector(toggleLauncher), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleDock() {
        (NSApp.delegate as? ElCapitanReskinApp)?.dockOverlayController?.toggleVisibility()
    }

    @objc private func toggleOverview() {
        (NSApp.delegate as? ElCapitanReskinApp)?.overviewController?.toggle()
    }

    @objc private func toggleLauncher() {
        LauncherController.shared.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyHandler: Any?
    private var hotKeys: [UInt32: EventHotKeyRef?] = [:]

    private enum HotKeyID: UInt32 {
        case overview = 1
        case toggleDock = 2
        case launcher = 3
    }

    func register() {
        registerCarbonHotKeys()
    }

    private func registerCarbonHotKeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        hotKeyHandler = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkCom = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkCom)
            let id = hkCom.id

            DispatchQueue.main.async {
                guard let appDelegate = NSApp.delegate as? ElCapitanReskinApp else { return }
                switch id {
                case HotKeyID.overview.rawValue:
                    appDelegate.overviewController?.toggle()
                case HotKeyID.toggleDock.rawValue:
                    appDelegate.dockOverlayController?.toggleVisibility()
                case HotKeyID.launcher.rawValue:
                    LauncherController.shared.toggle()
                default:
                    break
                }
            }

            return noErr
        }, 1, &eventSpec, nil, nil)

        registerHotKey(id: .overview, keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | optionKey))
        registerHotKey(id: .toggleDock, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey))
        registerHotKey(id: .launcher, keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))
    }

    private func registerHotKey(id: HotKeyID, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x454C4350), id: id.rawValue) // 'ELCP'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeys[id.rawValue] = ref
    }
}

enum InvasiveSystemTweaks {
    static func applyRecommendedTweaks() {
        // These are invasive. They will be best-effort and may fail depending on permissions/system policies.
        hideDock()
        reduceDockDelay()
        showScrollBarsAlways()
        enableReduceTransparency(false)
    }

    private static func hideDock() {
        run("defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
        run("killall", "Dock")
    }

    private static func reduceDockDelay() {
        run("defaults", "write", "com.apple.dock", "autohide-delay", "-float", "0")
        run("defaults", "write", "com.apple.dock", "autohide-time-modifier", "-float", "0.2")
        run("killall", "Dock")
    }

    private static func showScrollBarsAlways() {
        run("defaults", "write", "NSGlobalDomain", "AppleShowScrollBars", "-string", "Always")
    }

    private static func enableReduceTransparency(_ enabled: Bool) {
        run("defaults", "write", "com.apple.universalaccess", "reduceTransparency", "-bool", enabled ? "true" : "false")
    }

    private static func run(_ launchPath: String, _ args: String...) {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = [launchPath] + args
        try? p.run()
    }
}
