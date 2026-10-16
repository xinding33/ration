import AppKit
import Combine
import RationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = UsageModel()
    let updates = Updates()
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController!
    private var menuIsOpen = false
    private var observers: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?
    private let text = UsageText()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { NSApp.terminate(nil); return }

        LoginItem.refresh()
        settings = SettingsWindowController(model: model, updates: updates)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // The icon's colors follow the menu bar's appearance, so redraw it when that changes.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.refreshIcon()
                if self.menuIsOpen { self.rebuildMenu() }
            }
            .store(in: &observers)
        refreshIcon()
        model.start()
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) { model.prepareToQuit() }

    /// Opening Ration again from Finder shows Settings, since the menu bar item is all there is otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    // MARK: Icon

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        func ring(_ service: Service) -> RingIcon.Ring? {
            model.tracks(service) ? RingIcon.Ring(percent: model.state(service).usage?.tightest?.usedPercent) : nil
        }
        button.image = RingIcon.image(outer: ring(.claude), inner: ring(.chatGPT))
        let summary = model.trackedServices.map { service -> String in
            guard let tightest = model.state(service).usage?.tightest else { return "\(service.name): no numbers yet" }
            return "\(service.name) \(text.percent(tightest.usedPercent)) used"
        }
        let label = summary.isEmpty ? appName : summary.joined(separator: " · ")
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        model.menuOpened()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let now = Date()
        let tracked = model.trackedServices
        if tracked.isEmpty {
            add("Choose What to Track…", to: menu, action: #selector(openAccounts))
        }
        for (index, service) in tracked.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let state = model.state(service)
            menu.addItem(viewItem(ServiceHeaderView(name: service.name, plan: state.usage?.plan)))
            if let usage = state.usage {
                for window in usage.windows {
                    menu.addItem(viewItem(UsageRowView(window, resets: text.resets(window.resetsAt, now: now))))
                }
                if usage.windows.isEmpty { add("No limits reported", to: menu).isEnabled = false }
            } else if state.problem == nil {
                add(state.checking ? "Checking…" : "No numbers yet", to: menu).isEnabled = false
            }
            if let problem = state.problem {
                let fixable = problem.kind == .signIn || problem.kind == .codexLogin
                let item = add(problem.short, to: menu, action: fixable ? #selector(openAccounts) : nil)
                item.isEnabled = fixable
                item.toolTip = problem.detail
            }
        }
        menu.addItem(.separator())
        add("Settings…", to: menu, action: #selector(openSettings), key: ",")
        add("Quit Ration", to: menu, action: #selector(quit), key: "q")
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        // macOS adds its own symbols to items like Settings…, which this short menu doesn't need.
        // The setting is in the macOS 27 SDK, which comes with Swift 6.4.
        #if compiler(>=6.4)
        if #available(macOS 27, *) { item.preferredImageVisibility = .hidden }
        #endif
        menu.addItem(item)
        return item
    }

    @objc private func openSettings() { settings.show() }
    @objc private func openAccounts() { settings.show(tab: .accounts) }
    @objc private func quit() { NSApp.terminate(nil) }
}
