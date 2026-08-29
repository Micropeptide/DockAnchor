import Cocoa
import ApplicationServices

// MARK: - Persistence

enum Keys {
    static let enabled = "dockAnchorEnabled"
    static let guardPixels = "dockAnchorGuardPixels"
    /// [screen-set signature: stable display id] — a remembered anchor choice
    /// per *combination* of connected displays, so switching between e.g. a
    /// home monitor setup and an office one restores each one's own choice.
    static let profiles = "dockAnchorProfiles"
}

let defaults = UserDefaults.standard

// MARK: - App metadata

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    static let githubRepo = "Micropeptide/DockAnchor"
    static let repoURL = URL(string: "https://github.com/\(githubRepo)")!
    static let authorName = "Micropeptide"
    static let authorURL = URL(string: "https://github.com/Micropeptide")!
}

func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let num = screen.deviceDescription[key] as? NSNumber else { return 0 }
    return CGDirectDisplayID(num.uint32Value)
}

/// A display's CGDirectDisplayID is only a session-local handle — it can
/// change across reboots or reconnects. For anything persisted, identify a
/// physical display by the stable UUID CoreGraphics derives from its EDID
/// (the same identity macOS itself uses to remember display arrangement).
func stableDisplayID(_ screen: NSScreen) -> String {
    let cgID = screenDisplayID(screen)
    if let uuidRef = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue() {
        return "uuid:\(CFUUIDCreateString(nil, uuidRef) as String)"
    }
    return "id:\(cgID)"
}

/// Identifies the current *combination* of connected displays, so a
/// remembered anchor choice is scoped to the set it was made for.
func currentScreenSetSignature() -> String {
    NSScreen.screens.map(stableDisplayID).sorted().joined(separator: "|")
}

// MARK: - Dock guard

/// Watches global mouse movement and, whenever the pointer approaches the
/// bottom edge of any display other than the chosen "anchor" display, clamps
/// it a few pixels short of the true edge. macOS only reveals the Dock on a
/// display once the pointer actually touches its bottom-most pixel row, so
/// this prevents the reveal on every other screen without affecting normal
/// cursor movement anywhere else.
final class DockGuard {
    static let shared = DockGuard()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var guardPixels: CGFloat {
        let v = defaults.object(forKey: Keys.guardPixels) as? Double ?? 3
        return CGFloat(v)
    }

    private var profiles: [String: String] {
        get { defaults.dictionary(forKey: Keys.profiles) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.profiles) }
    }

    /// The screen the Dock should be pinned to for the *current* set of
    /// connected displays. Falls back to the screen carrying the menu bar
    /// (screens[0]) if this exact combination has no remembered choice yet.
    func anchorScreen() -> NSScreen {
        let signature = currentScreenSetSignature()
        if let savedID = profiles[signature],
           let match = NSScreen.screens.first(where: { stableDisplayID($0) == savedID }) {
            return match
        }
        return NSScreen.screens[0]
    }

    /// Remembers `screen` as the anchor for the current combination of
    /// connected displays specifically (not globally).
    func setAnchorScreen(_ screen: NSScreen) {
        var p = profiles
        p[currentScreenSetSignature()] = stableDisplayID(screen)
        profiles = p
        refreshCachedAnchor()
    }

    // The event tap runs on every mouse-moved event, so it reads this cached
    // id rather than resolving anchorScreen()'s UUIDs/dictionary lookup live.
    private var cachedAnchorID: CGDirectDisplayID = 0

    func refreshCachedAnchor() {
        cachedAnchorID = screenDisplayID(anchorScreen())
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { return }

        refreshCachedAnchor()

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let instance = Unmanaged<DockGuard>.fromOpaque(refcon).takeUnretainedValue()
            return instance.handle(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            isRunning = false
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard enabled else { return Unmanaged.passUnretained(event) }

        let screens = NSScreen.screens
        guard screens.count > 1 else { return Unmanaged.passUnretained(event) }

        let anchorID = cachedAnchorID

        // The primary screen's Cocoa frame always has origin (0,0); its height
        // is exactly the constant needed to flip any screen's Cocoa frame
        // (bottom-left origin, y up) into CGEvent's global display space
        // (top-left origin, y grows downward).
        let primaryHeight = screens[0].frame.height
        var location = event.location
        var moved = false

        for screen in screens {
            guard screenDisplayID(screen) != anchorID else { continue }
            let f = screen.frame
            let top = primaryHeight - f.origin.y - f.height
            let bottom = top + f.height
            let left = f.origin.x
            let right = f.origin.x + f.width

            // Require the point to actually lie within this screen's own
            // bounds — not just past its bottom threshold with no ceiling.
            // Without the y-upper-bound, a screen stacked directly beneath
            // this one (sharing part of its x-range) would have its entire
            // area misread as "past this screen's bottom edge".
            guard location.x >= left, location.x < right,
                  location.y >= top, location.y < bottom else { continue }

            let ceiling = bottom - guardPixels
            if location.y >= ceiling {
                location.y = ceiling
                moved = true
            }
        }

        if moved {
            event.location = location
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
    static let label = "com.dockanchor.agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() {
        let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: plistURL)
        runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func disable() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func runLaunchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }
}

// MARK: - Update checking

enum UpdateFrequency: String, CaseIterable {
    case weekly, monthly, never

    var title: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .never: return "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        case .never: return nil
        }
    }
}

/// Checks GitHub Releases for a newer tagged version than the running build.
/// Never downloads or installs anything itself — it only surfaces a link, so
/// the user always chooses when and whether to actually update.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private enum DefaultsKeys {
        static let frequency = "dockAnchorUpdateFrequency"
        static let lastCheck = "dockAnchorLastUpdateCheck"
    }

    var onUpdateFound: (() -> Void)?
    private(set) var latestVersion: String?
    private(set) var latestReleaseURL: URL?
    private(set) var isChecking = false

    var frequency: UpdateFrequency {
        get { UpdateFrequency(rawValue: defaults.string(forKey: DefaultsKeys.frequency) ?? "weekly") ?? .weekly }
        set { defaults.set(newValue.rawValue, forKey: DefaultsKeys.frequency) }
    }

    private var lastCheck: Date? {
        get { defaults.object(forKey: DefaultsKeys.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: DefaultsKeys.lastCheck) }
    }

    /// Called periodically; only actually hits the network if due per `frequency`.
    func checkIfDue() {
        guard let interval = frequency.interval else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < interval { return }
        checkNow()
    }

    func checkNow(completion: ((Result<Bool, Error>) -> Void)? = nil) {
        guard !isChecking else { return }
        isChecking = true
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                self.lastCheck = Date()
            }
            if let error = error {
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURLString = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString) else {
                DispatchQueue.main.async { completion?(.success(false)) }
                return
            }
            let cleanTag = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let isNewer = cleanTag.compare(AppInfo.version, options: .numeric) == .orderedDescending
            DispatchQueue.main.async {
                if isNewer {
                    self.latestVersion = cleanTag
                    self.latestReleaseURL = htmlURL
                    self.onUpdateFound?()
                }
                completion?(.success(isNewer))
            }
        }
        task.resume()
    }
}

// MARK: - App delegate / menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusItem.zSharedStatusBar()
        buildStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        requestAccessibilityIfNeeded()
        DockGuard.shared.start()

        // Accessibility grants only take effect for a running process once the
        // system re-checks trust; poll briefly so the guard turns on right
        // after the user flips the switch in System Settings, no relaunch needed.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                DockGuard.shared.start()
            }
            self?.rebuildMenu()
        }

        UpdateChecker.shared.onUpdateFound = { [weak self] in self?.rebuildMenu() }
        UpdateChecker.shared.checkIfDue()
        // The app can stay running for weeks as a login item; re-evaluate
        // whether a check is due periodically rather than only at launch.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            UpdateChecker.shared.checkIfDue()
        }
    }

    private func buildStatusItem() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockAnchor") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback in case this symbol is ever unavailable on some OS version.
                button.title = "▤"
            }
        }
        rebuildMenu()
    }

    /// Fires when displays are connected/disconnected/rearranged — re-resolve
    /// which screen counts as the anchor for this (possibly new) combination.
    @objc private func screenParametersChanged() {
        DockGuard.shared.refreshCachedAnchor()
        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()

        let trusted = AXIsProcessTrusted()
        let statusText: String
        if !trusted {
            statusText = "Accessibility permission needed"
        } else if !DockGuard.shared.enabled {
            statusText = "Guarding paused"
        } else {
            statusText = "Anchored to: \(DockGuard.shared.anchorScreen().localizedName)"
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        if !trusted {
            let grant = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Guard Dock", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = DockGuard.shared.enabled ? .on : .off
        menu.addItem(toggle)

        let screenMenu = NSMenu()
        let currentAnchorID = DockGuard.shared.anchorScreen()
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(selectAnchorScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screenDisplayID(screen)
            item.state = (screenDisplayID(screen) == screenDisplayID(currentAnchorID)) ? .on : .off
            screenMenu.addItem(item)
        }
        let screenParent = NSMenuItem(title: "Anchor Screen", action: nil, keyEquivalent: "")
        menu.setSubmenu(screenMenu, for: screenParent)
        menu.addItem(screenParent)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isInstalled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        if let latest = UpdateChecker.shared.latestVersion {
            let banner = NSMenuItem(title: "Update available: v\(latest)", action: #selector(openLatestRelease), keyEquivalent: "")
            banner.target = self
            menu.addItem(banner)
        }

        let checkNow = NSMenuItem(
            title: UpdateChecker.shared.isChecking ? "Checking…" : "Check for Updates Now",
            action: #selector(checkForUpdatesNow), keyEquivalent: "")
        checkNow.target = self
        checkNow.isEnabled = !UpdateChecker.shared.isChecking
        menu.addItem(checkNow)

        let freqMenu = NSMenu()
        for freq in UpdateFrequency.allCases {
            let item = NSMenuItem(title: freq.title, action: #selector(selectUpdateFrequency(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = freq.rawValue
            item.state = (UpdateChecker.shared.frequency == freq) ? .on : .off
            freqMenu.addItem(item)
        }
        let freqParent = NSMenuItem(title: "Check for Updates", action: nil, keyEquivalent: "")
        menu.setSubmenu(freqMenu, for: freqParent)
        menu.addItem(freqParent)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About DockAnchor", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit DockAnchor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        DockGuard.shared.enabled.toggle()
        rebuildMenu()
    }

    @objc private func selectAnchorScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID,
              let screen = NSScreen.screens.first(where: { screenDisplayID($0) == id }) else { return }
        DockGuard.shared.setAnchorScreen(screen)
        rebuildMenu()
    }

    @objc private func toggleLoginItem() {
        if LoginItem.isInstalled {
            LoginItem.disable()
        } else {
            LoginItem.enable()
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdatesNow() {
        rebuildMenu() // reflect "Checking…" immediately
        UpdateChecker.shared.checkNow { [weak self] result in
            guard let self = self else { return }
            self.rebuildMenu()
            if case .success(let found) = result, !found {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "DockAnchor \(AppInfo.version) is the latest version."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            } else if case .failure = result {
                let alert = NSAlert()
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Check your internet connection and try again."
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func openLatestRelease() {
        if let url = UpdateChecker.shared.latestReleaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectUpdateFrequency(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let freq = UpdateFrequency(rawValue: raw) else { return }
        UpdateChecker.shared.frequency = freq
        rebuildMenu()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DockAnchor"
        alert.informativeText = """
        Version \(AppInfo.version)

        Keeps the Dock pinned to one display when you're using multiple monitors — the pointer never triggers a Dock reveal on any screen but the one you choose.

        by \(AppInfo.authorName)
        """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Visit GitHub")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppInfo.authorURL)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func requestAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options: NSDictionary = [promptKey: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

private extension NSStatusItem {
    static func zSharedStatusBar() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
