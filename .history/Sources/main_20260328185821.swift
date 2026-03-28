import Carbon
import Cocoa

// MARK: - 修饰键掩码（统一使用 CGEventFlags 体系，避免与 Carbon cmdKey 混用）
private let kModCmd: CGEventFlags = .maskCommand
private let kModOpt: CGEventFlags = .maskAlternate
private let kModShift: CGEventFlags = .maskShift
private let kModCtrl: CGEventFlags = .maskControl

// 只关心这四个修饰位，忽略 NumLock 等噪声位
private let kModMask: UInt64 =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue

// MARK: - 键位映射表（keyCode → 要输出的字符串）
private let kKeyMap: [Int64: String] = [
    38: "1",  // J
    40: "2",  // K
    37: "3",  // L
    32: "4",  // U
    34: "5",  // I
    31: "6",  // O
    46: "0",  // M
    43: "00",  // 逗号（,）
]

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Status bar
    private var statusItem: NSStatusItem?

    // MARK: 主事件 tap（拦截键盘）
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: 状态
    var isEnabled = false

    // MARK: 快捷键设置（统一用 CGEventFlags.rawValue 存储修饰键）
    var hotKeyModifiers: UInt64 = 0  // CGEventFlags 的 rawValue，仅含四个修饰位
    var hotKeyKeyCode: UInt32 = 0

    // MARK: 设置窗口
    private var settingsWindow: NSWindow?
    private weak var keyField: NSTextField?
    private weak var recordButton: NSButton?

    // MARK: 录制状态（用 NSEvent local monitor，不新建 CGEvent tap）
    private var isRecording = false
    private var recordingMonitor: Any?

    // MARK: - 生命周期

    override init() {
        super.init()
        loadSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        setupEventTap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - 状态栏

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "number", accessibilityDescription: "Numaric")
            button.image?.isTemplate = true
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggleTitle = isEnabled ? "关闭小键盘" : "开启小键盘"
        let toggleItem = NSMenuItem(
            title: toggleTitle, action: #selector(toggleKeypad), keyEquivalent: "")
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "设置...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        // 所有 action 都需要 target
        for item in menu.items {
            item.target = self
        }

        statusItem?.menu = menu
    }

    // MARK: - 菜单动作

    @objc func toggleKeypad() {
        isEnabled.toggle()
        rebuildMenu()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 主 CGEvent Tap

    private func setupEventTap() {
        // 移除旧的（如果存在）
        teardownEventTap()

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        )

        guard let tap = tap else {
            DispatchQueue.main.async {
                self.showAccessibilityAlert()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "请前往「系统设置 → 隐私与安全 → 辅助功能」，将本应用加入允许列表后重启。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )!
            )
        }
    }

    // MARK: - Event Tap 回调（C 函数指针兼容的全局函数）

    // 使用顶层（全局）函数，避免闭包捕获 self 与 Unmanaged 的常见陷阱
    // 这里用 @convention(c) 确保 ABI 正确
}

// MARK: - CGEvent Tap 全局回调

private let eventTapCallback: CGEventTapCallBack = {
    proxy, type, event, refcon -> Unmanaged<CGEvent>? in
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return app.handleEvent(proxy: proxy, type: type, event: event)
}

extension AppDelegate {

    /// 返回 nil 表示吞掉事件，返回事件表示放行
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<
        CGEvent
    >? {

        // tap 被系统禁用后重新启用（权限问题偶发）
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // 正在录制时，交给录制逻辑，不做其他处理
        if isRecording { return nil }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawFlags = event.flags.rawValue & kModMask  // 只取四个修饰位

        // 检查是否匹配快捷键
        if rawFlags == hotKeyModifiers && keyCode == Int64(hotKeyKeyCode) {
            DispatchQueue.main.async { self.toggleKeypad() }
            return nil  // 吞掉快捷键本身
        }

        // 小键盘模式未开启 → 放行
        guard isEnabled else { return Unmanaged.passRetained(event) }

        // 有修饰键（除 Shift 外）时放行，避免误拦截 Cmd+C 等
        let nonShiftMods = rawFlags & ~CGEventFlags.maskShift.rawValue
        if nonShiftMods != 0 { return Unmanaged.passRetained(event) }

        // 查键位映射
        if let mapped = kKeyMap[keyCode] {
            simulateText(mapped)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - 模拟按键输出

    private func simulateText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            guard let keyCode = charToKeyCode(ch) else { continue }
            CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(
                tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(
                tap: .cgSessionEventTap)
        }
    }

    private func charToKeyCode(_ char: Character) -> CGKeyCode? {
        switch char {
        case "0": return CGKeyCode(kVK_ANSI_0)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)
        default: return nil
        }
    }

    // MARK: - 设置窗口

    @objc func showSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Numaric 设置"
        win.isReleasedWhenClosed = false
        win.center()

        buildSettingsContent(in: win)

        // 窗口关闭时清空引用和停止录制
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.stopRecording()
            self?.settingsWindow = nil
        }

        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsContent(in window: NSWindow) {
        let contentView = NSView()
        window.contentView = contentView

        // --- 标题 ---
        let titleLabel = NSTextField(labelWithString: "切换快捷键设置")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        // --- 快捷键显示框 ---
        let keyLabel = NSTextField(labelWithString: "快捷键:")
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(keyLabel)

        let keyField = NSTextField()
        keyField.stringValue = hotKeyToString()
        keyField.isEditable = false
        keyField.isSelectable = false
        keyField.alignment = .center
        keyField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(keyField)
        self.keyField = keyField

        let recordButton = NSButton(
            title: "录制", target: self, action: #selector(handleRecordButton))
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recordButton)
        self.recordButton = recordButton

        // --- 说明 ---
        let info = """
            键位映射（小键盘模式开启时生效）：
              J → 1    K → 2    L → 3
              U → 4    I → 5    O → 6
              M → 0    , → 00
              7、8、9 及其他键照常输入
            """
        let infoLabel = NSTextField(wrappingLabelWithString: info)
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(infoLabel)

        // --- 布局 ---
        let p: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: p),

            keyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: p),
            keyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: p),
            keyLabel.widthAnchor.constraint(equalToConstant: 60),

            keyField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            keyField.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 8),
            keyField.widthAnchor.constraint(equalToConstant: 160),

            recordButton.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            recordButton.leadingAnchor.constraint(equalTo: keyField.trailingAnchor, constant: 12),
            recordButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -p),

            infoLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: p),
            infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: p),
            infoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -p),
            infoLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -p),

            contentView.widthAnchor.constraint(equalToConstant: 420),
            contentView.heightAnchor.constraint(equalToConstant: 320),
        ])
    }

    // MARK: - 快捷键录制

    @objc private func handleRecordButton() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordButton?.title = "按下组合键… (ESC取消)"
        recordButton?.isHighlighted = true
        keyField?.stringValue = "等待输入…"
        keyField?.textColor = .systemOrange

        // 用 NSEvent local monitor 监听键盘，不新增 CGEvent tap（避免冲突）
        // local monitor 可捕获发往当前 App 的按键（设置窗口聚焦时即可）
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self = self, self.isRecording else { return event }

            let keyCode = UInt32(event.keyCode)
            let rawMods = event.modifierFlags.intersection([.command, .option, .shift, .control])

            // ESC 取消录制
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }

            // 必须有修饰键（纯字母/数字不允许作为快捷键，避免日常输入被截获）
            guard !rawMods.isEmpty else { return event }

            // 将 NSEvent.ModifierFlags 转为 CGEventFlags.rawValue（两者数值相同）
            var cgMods: UInt64 = 0
            if rawMods.contains(.command) { cgMods |= CGEventFlags.maskCommand.rawValue }
            if rawMods.contains(.option) { cgMods |= CGEventFlags.maskAlternate.rawValue }
            if rawMods.contains(.shift) { cgMods |= CGEventFlags.maskShift.rawValue }
            if rawMods.contains(.control) { cgMods |= CGEventFlags.maskControl.rawValue }

            self.hotKeyModifiers = cgMods
            self.hotKeyKeyCode = keyCode
            self.saveSettings()
            self.stopRecording()
            return nil  // 吞掉录制期间的按键
        }

        // 5 秒超时自动取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.stopRecording()
        }
    }

    private func stopRecording() {
        guard isRecording || recordingMonitor != nil else { return }
        isRecording = false

        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }

        recordButton?.title = "录制"
        recordButton?.isHighlighted = false
        keyField?.stringValue = hotKeyToString()
        keyField?.textColor = .labelColor
    }

    // MARK: - 快捷键 → 字符串

    func hotKeyToString() -> String {
        var parts: [String] = []
        if hotKeyModifiers & CGEventFlags.maskControl.rawValue != 0 { parts.append("⌃") }
        if hotKeyModifiers & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if hotKeyModifiers & CGEventFlags.maskShift.rawValue != 0 { parts.append("⇧") }
        if hotKeyModifiers & CGEventFlags.maskCommand.rawValue != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(hotKeyKeyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default: return "(\(code))"
        }
    }

    // MARK: - 持久化
    // 注意：UInt32/UInt64 不能直接用 UserDefaults.integer(forKey:)（它返回 Int）
    // 改用 set(_:forKey:) 存 Int，再转回来，安全可靠。

    func loadSettings() {
        let defaults = UserDefaults.standard

        // hotKeyModifiers 存为 Int64 via Double（UserDefaults 没有 UInt64 原生支持，用 string 最安全）
        if let modsStr = defaults.string(forKey: "hotKeyModifiers2"),
            let mods = UInt64(modsStr)
        {
            hotKeyModifiers = mods
        } else {
            // 默认 Cmd+Opt+K
            hotKeyModifiers =
                CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        }

        let savedCode = defaults.integer(forKey: "hotKeyKeyCode2")
        hotKeyKeyCode = savedCode > 0 ? UInt32(savedCode) : UInt32(kVK_ANSI_K)
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(String(hotKeyModifiers), forKey: "hotKeyModifiers2")
        defaults.set(Int(hotKeyKeyCode), forKey: "hotKeyKeyCode2")
        defaults.synchronize()

        // 更新 UI（可能在任意线程调用）
        DispatchQueue.main.async {
            self.keyField?.stringValue = self.hotKeyToString()
            self.keyField?.textColor = .labelColor
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
