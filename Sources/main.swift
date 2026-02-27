import AppKit
import ApplicationServices

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
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

    private var timer: Timer?

    override func loadView() {
        view = NSView()

        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active

        leftLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        leftLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)

        rightLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        rightLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        rightLabel.alignment = .right

        view.addSubview(blur)
        view.addSubview(leftLabel)
        view.addSubview(rightLabel)

        blur.translatesAutoresizingMaskIntoConstraints = false
        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        rightLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            leftLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            leftLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            rightLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rightLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        updateClock()
    }

    func setFrontmost(app: NSRunningApplication?) {
        let name = app?.localizedName ?? ""
        leftLabel.stringValue = name.isEmpty ? "" : "\(name)"
    }

    private func updateClock() {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM  h:mm a"
        rightLabel.stringValue = df.string(from: Date())
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

final class HotKeyService {
    static let shared = HotKeyService()

    func register() {
        // Note: NSEvent global monitors only receive events while the app is running.
        // For a true always-on hotkey, implement Carbon HotKeys or an event tap.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+Option+E toggles overview
            if event.modifierFlags.contains([.command, .option]), event.charactersIgnoringModifiers?.lowercased() == "e" {
                DispatchQueue.main.async {
                    (NSApp.delegate as? ElCapitanReskinApp)?.overviewController?.toggle()
                }
            }

            // Cmd+Option+D toggles our Dock overlay visibility
            if event.modifierFlags.contains([.command, .option]), event.charactersIgnoringModifiers?.lowercased() == "d" {
                DispatchQueue.main.async {
                    (NSApp.delegate as? ElCapitanReskinApp)?.dockOverlayController?.toggleVisibility()
                }
            }
        }
    }
}

enum InvasiveSystemTweaks {
    static func applyRecommendedTweaks() {
        // These are invasive. They will be best-effort and may fail depending on permissions/system policies.
        hideDock()
        reduceDockDelay()
    }

    private static func hideDock() {
        // Auto-hide Dock and remove show/hide animation delay.
        run("defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
        run("killall", "Dock")
    }

    private static func reduceDockDelay() {
        run("defaults", "write", "com.apple.dock", "autohide-delay", "-float", "0")
        run("defaults", "write", "com.apple.dock", "autohide-time-modifier", "-float", "0.2")
        run("killall", "Dock")
    }

    private static func run(_ launchPath: String, _ args: String...) {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = [launchPath] + args
        try? p.run()
    }
}
