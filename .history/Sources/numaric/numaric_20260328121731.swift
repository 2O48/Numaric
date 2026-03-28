import AppKit

private struct HotKey: Codable {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
}

private struct Settings: Codable {
    let hotKey: HotKey
}

private let defaultHotKey = HotKey(keyCode: 40, modifiers: [.maskCommand, .maskAlternate])

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleMenuItem = NSMenuItem(
        title: "启用小键盘", action: #selector(toggleState(_:)), keyEquivalent: "")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureMonitor: Any?
    private var settingsWindow: NSWindow?
    private let settingsURL: URL
    private var hotKey: HotKey = defaultHotKey
    private var isEnabled = false {
        didSet { updateStatus() }
    }
    private lazy var hotKeyLabelField: NSTextField = {
        let field = NSTextField(labelWithString: "当前切换键：${}")
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    override init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let folder = appSupport.appendingPathComponent("numaric", isDirectory: true)
        self.settingsURL = folder.appendingPathComponent("settings.json")
        super.init()
        loadSettings()
        createSupportFolderIfNeeded(at: folder)
        setupStatusItem()
        setupEventTap()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventTap()
    }

    private func createSupportFolderIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @MainActor
    private func setupStatusItem() {
        let menu = NSMenu()
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        let settingsItem = NSMenuItem(
            title: "设置", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.title = "⌨︎"
    }

    @MainActor
    private func updateStatus() {
        toggleMenuItem.title = isEnabled ? "关闭小键盘" : "启用小键盘"
        statusItem.button?.title = isEnabled ? "⌨︎✅" : "⌨︎"
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: eventTapCallback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        else {
            showAccessibilityAlert()
            return
        }

        self.eventTap = eventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap = eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            hotKey = defaultHotKey
            return
        }
        hotKey = settings.hotKey
    }

    private func saveSettings() {
        let settings = Settings(hotKey: hotKey)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL)
        }
    }

    @MainActor
    @objc private func toggleState(_ sender: Any?) {
        isEnabled.toggle()
    }

    @MainActor
    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        hotKeyLabelField.stringValue = "当前切换键：\(hotKeyLabel())"
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @MainActor
    @objc private func beginCaptureShortcut(_ sender: Any?) {
        hotKeyLabelField.stringValue = "请按下新的切换键..."
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let codes = CGKeyCode(event.keyCode)
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            let cgFlags = self.cgFlags(from: flags)
            guard !flags.isEmpty else {
                self.hotKeyLabelField.stringValue = "请至少按下 Command/Option/Control 之一。"
                return nil
            }
            self.hotKey = HotKey(keyCode: codes, modifiers: cgFlags)
            self.saveSettings()
            self.hotKeyLabelField.stringValue = "当前切换键：\(self.hotKeyLabel())"
            if let monitor = self.captureMonitor {
                NSEvent.removeMonitor(monitor)
                self.captureMonitor = nil
            }
            return nil
        }
    }

    @MainActor
    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "numaric 设置"
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.wantsLayer = true

        let title = NSTextField(labelWithString: "切换键：")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        hotKeyLabelField.stringValue = "当前切换键：\(hotKeyLabel())"
        hotKeyLabelField.translatesAutoresizingMaskIntoConstraints = false

        let help = NSTextField(labelWithString: "默认 cmd+opt+k。设置后，按下快捷键即可启用/关闭小键盘映射。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        help.translatesAutoresizingMaskIntoConstraints = false
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2

        let button = NSButton(
            title: "设置切换键", target: self, action: #selector(beginCaptureShortcut(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(title)
        contentView.addSubview(hotKeyLabelField)
        contentView.addSubview(help)
        contentView.addSubview(button)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            hotKeyLabelField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hotKeyLabelField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            help.topAnchor.constraint(equalTo: hotKeyLabelField.bottomAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            button.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 16),
        ])

        return window
    }

    private func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }

    private func hotKeyLabel() -> String {
        var parts = [String]()
        if hotKey.modifiers.contains(.maskCommand) { parts.append("⌘") }
        if hotKey.modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if hotKey.modifiers.contains(.maskControl) { parts.append("⌃") }
        if hotKey.modifiers.contains(.maskShift) { parts.append("⇧") }
        parts.append(keyCodeLabel(hotKey.keyCode))
        return parts.joined()
    }

    private func keyCodeLabel(_ keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "I"
        case 34: return "P"
        case 35: return "["
        case 36: return "Enter"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        default: return "Key\(keyCode)"
        }
    }

    fileprivate func isHotKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        return keyCode == hotKey.keyCode
            && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                == hotKey.modifiers
    }

    fileprivate func shouldRemap(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if !isEnabled { return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        {
            return false
        }
        return remapTable[keyCode] != nil
    }

    fileprivate func sendRemapped(_ keyCode: CGKeyCode) {
        guard let text = remapTable[keyCode] else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16Chars = Array(text.utf16)
        let length = Int(utf16Chars.count)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            utf16Chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: length, unicodeString: ptr.baseAddress)
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            utf16Chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: length, unicodeString: ptr.baseAddress)
            }
            up.post(tap: .cghidEventTap)
        }
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许 numaric 访问键盘。"
            alert.addButton(withTitle: "知道了")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private var remapTable: [CGKeyCode: String] {
        [
            38: "1",  // j
            40: "2",  // k
            37: "3",  // l
            32: "4",  // u
            33: "5",  // i
            31: "6",  // o
            46: "0",  // m
            43: "00",  // ,
        ]
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return .passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    guard type == .keyDown || type == .keyUp else { return .passUnretained(event) }
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    if app.isHotKeyEvent(keyCode: keyCode, flags: flags) {
        return nil
    }
    if app.shouldRemap(keyCode: keyCode, flags: flags) {
        if type == .keyDown {
            app.sendRemapped(keyCode)
        }
        return nil
    }
    return .passUnretained(event)
}

extension NSTextField {
    fileprivate convenience init(labelWithString string: String) {
        self.init(labelWithString: string)
    }
}
