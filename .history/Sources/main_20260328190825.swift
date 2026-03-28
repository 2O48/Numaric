// main.swift
// 编译方式（命令行，无需 Xcode 工程）：
//   swiftc main.swift -framework Carbon -framework Cocoa -o Numaric
// 运行前需在「系统设置 → 隐私与安全 → 辅助功能」添加本程序。

import Carbon
import Cocoa

// ─────────────────────────────────────────────────────────
// MARK: - 全局常量
// ─────────────────────────────────────────────────────────

/// 我们自己合成的按键事件的特征标记，用于在 tap 回调里跳过它，避免死循环。
/// 存入 CGEvent.eventSourceUserData，随意选一个不与系统冲突的魔数。
private let kSyntheticEventMark: Int64 = 0x4E55_4D52  // ASCII "NUMR"

/// CGEventFlags 中我们关心的四个修饰位
private let kModifierMask: UInt64 =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue

/// 键位映射：虚拟键码 → 要输出的字符串（可输出多字符，如 "00"）
private let kKeyMap: [Int64: String] = [
    38: "1",  // J
    40: "2",  // K
    37: "3",  // L
    32: "4",  // U
    34: "5",  // I
    31: "6",  // O
    46: "0",  // M
    43: "00",  // 逗号 ,
]

/// 字符 → ANSI 虚拟键码
private let kCharToKeyCode: [Character: CGKeyCode] = [
    "0": CGKeyCode(kVK_ANSI_0),
    "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2),
    "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4),
    "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6),
    "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8),
    "9": CGKeyCode(kVK_ANSI_9),
]

// ─────────────────────────────────────────────────────────
// MARK: - CGEvent Tap 顶层回调（必须是全局函数，不能是闭包）
// ─────────────────────────────────────────────────────────

private func globalEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return delegate.handleCGEvent(proxy: proxy, type: type, event: event)
}

// ─────────────────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: 状态栏
    private var statusItem: NSStatusItem!

    // MARK: 键盘拦截
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    // MARK: 小键盘开关
    private(set) var isEnabled = false

    // MARK: 快捷键（统一使用 CGEventFlags.rawValue 体系）
    private var hotModifiers: UInt64 = 0
    private var hotKeyCode: UInt32 = 0

    // MARK: 设置窗口
    private var settingsWindow: NSWindow?
    private weak var keyDisplayField: NSTextField?
    private weak var recordBtn: NSButton?

    // MARK: 录制状态
    private var isRecording = false
    private var recordMonitor: Any?

    // ── 生命周期 ──────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 不在 Dock 显示
        loadSettings()
        buildStatusBar()
        installEventTap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ── 状态栏 ────────────────────────────────────────────

    private func buildStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(
                systemSymbolName: "number.square", accessibilityDescription: "Numaric")
            btn.image?.isTemplate = true
        }
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: isEnabled ? "关闭小键盘" : "开启小键盘",
            action: #selector(menuToggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置…", action: #selector(menuSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuToggle() { setEnabled(!isEnabled) }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func setEnabled(_ on: Bool) {
        isEnabled = on
        refreshMenu()
    }

    // ── CGEvent Tap 安装 ──────────────────────────────────

    func installEventTap() {
        removeEventTap()

        // passRetained 保证 tap 存活期间 self 不被释放；在 removeEventTap 里 release
        let retained = Unmanaged.passRetained(self)
        let refcon = retained.toOpaque()

        // 同时监听 tapDisabled 事件类型以便自动重启
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: globalEventTapCallback,
                userInfo: refcon
            )
        else {
            retained.release()
            promptAccessibility()
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        tapRunLoopSource = src
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            // 平衡 installEventTap 里的 passRetained
            Unmanaged.passUnretained(self).release()
            eventTap = nil
        }
        if let src = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            tapRunLoopSource = nil
        }
    }

    private func promptAccessibility() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "请前往「系统设置 → 隐私与安全性 → 辅助功能」，将本程序加入列表后重启。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )!
                NSWorkspace.shared.open(url)
            }
        }
    }

    // ── CGEvent 处理（由顶层回调转入） ───────────────────

    func handleCGEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Tap 被系统暂停 → 立即重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // ★ 跳过自身合成的事件，防止死循环
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventMark {
            return Unmanaged.passRetained(event)
        }

        // 正在录制 → 吞掉（NSEvent local monitor 会处理）
        if isRecording { return nil }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawMods = event.flags.rawValue & kModifierMask

        // 检测切换快捷键
        if rawMods == hotModifiers && keyCode == Int64(hotKeyCode) {
            DispatchQueue.main.async { self.setEnabled(!self.isEnabled) }
            return nil
        }

        // 小键盘未开启 → 放行
        guard isEnabled else { return Unmanaged.passRetained(event) }

        // 有非 Shift 修饰键 → 放行（保护 Cmd+C、Opt+← 等）
        let nonShift = rawMods & ~CGEventFlags.maskShift.rawValue
        if nonShift != 0 { return Unmanaged.passRetained(event) }

        // 查映射表
        if let text = kKeyMap[keyCode] {
            postSyntheticText(text)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // ── 合成按键输出 ──────────────────────────────────────

    private func postSyntheticText(_ text: String) {
        // privateState：不读取当前修饰键状态，确保合成出来的是干净的按键事件
        let src = CGEventSource(stateID: .privateState)

        for ch in text {
            guard let kc = kCharToKeyCode[ch] else { continue }

            let down = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)

            // ★ 打上标记，让 tap 回调识别并放行
            down?.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMark)
            up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMark)

            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    // ── 设置窗口 ──────────────────────────────────────────

    private func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Numaric 设置"
        win.isReleasedWhenClosed = false
        win.center()
        buildSettingsUI(in: win)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.cancelRecordingIfNeeded()
            self?.settingsWindow = nil
        }

        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsUI(in win: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = root

        let title = makeLabel("切换快捷键设置", size: 15, weight: .semibold)

        let keyLbl = makeLabel("快捷键：", size: 13)

        let kf = NSTextField()
        kf.stringValue = hotkeyString()
        kf.isEditable = false
        kf.isSelectable = false
        kf.alignment = .center
        kf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        kf.translatesAutoresizingMaskIntoConstraints = false
        self.keyDisplayField = kf

        let rb = NSButton(title: "录制", target: self, action: #selector(handleRecordBtn))
        rb.translatesAutoresizingMaskIntoConstraints = false
        self.recordBtn = rb

        let infoText =
            "键位映射（小键盘开启时生效）：\n  J→1   K→2   L→3\n  U→4   I→5   O→6\n  M→0   ,→00\n  7 / 8 / 9 及其他按键原样输入"
        let info = makeLabel(infoText, size: 12, color: .secondaryLabelColor)
        info.maximumNumberOfLines = 0

        for v in [title, keyLbl, kf, rb, info] { root.addSubview(v) }

        let g: CGFloat = 20
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 440),
            root.heightAnchor.constraint(equalToConstant: 290),

            title.topAnchor.constraint(equalTo: root.topAnchor, constant: g),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: g),

            keyLbl.topAnchor.constraint(equalTo: title.bottomAnchor, constant: g),
            keyLbl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: g),

            kf.centerYAnchor.constraint(equalTo: keyLbl.centerYAnchor),
            kf.leadingAnchor.constraint(equalTo: keyLbl.trailingAnchor, constant: 8),
            kf.widthAnchor.constraint(equalToConstant: 140),

            rb.centerYAnchor.constraint(equalTo: keyLbl.centerYAnchor),
            rb.leadingAnchor.constraint(equalTo: kf.trailingAnchor, constant: 10),

            info.topAnchor.constraint(equalTo: keyLbl.bottomAnchor, constant: g),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: g),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -g),
        ])
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // ── 录制快捷键 ────────────────────────────────────────

    @objc private func handleRecordBtn() {
        isRecording ? cancelRecordingIfNeeded() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordBtn?.title = "按下组合键… (ESC 取消)"
        keyDisplayField?.stringValue = "等待输入…"
        keyDisplayField?.textColor = .systemOrange

        // local monitor：仅捕获发给当前 App 的键盘事件，不新建全局 tap
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isRecording else { return ev }

            if ev.keyCode == UInt16(kVK_Escape) {
                self.cancelRecordingIfNeeded()
                return nil
            }

            let mods = ev.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !mods.isEmpty else { return ev }  // 无修饰键 → 不记录，放行

            var cgMods: UInt64 = 0
            if mods.contains(.command) { cgMods |= CGEventFlags.maskCommand.rawValue }
            if mods.contains(.option) { cgMods |= CGEventFlags.maskAlternate.rawValue }
            if mods.contains(.shift) { cgMods |= CGEventFlags.maskShift.rawValue }
            if mods.contains(.control) { cgMods |= CGEventFlags.maskControl.rawValue }

            self.hotModifiers = cgMods
            self.hotKeyCode = UInt32(ev.keyCode)
            self.saveSettings()
            self.finishRecording()
            return nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.cancelRecordingIfNeeded()
        }
    }

    private func finishRecording() {
        isRecording = false
        if let m = recordMonitor {
            NSEvent.removeMonitor(m)
            recordMonitor = nil
        }
        recordBtn?.title = "录制"
        keyDisplayField?.stringValue = hotkeyString()
        keyDisplayField?.textColor = .labelColor
    }

    private func cancelRecordingIfNeeded() {
        guard isRecording || recordMonitor != nil else { return }
        finishRecording()
    }

    // ── 持久化 ────────────────────────────────────────────

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "hkMods"), let v = UInt64(s) {
            hotModifiers = v
        } else {
            hotModifiers = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        }
        let kc = d.integer(forKey: "hkCode")
        hotKeyCode = kc > 0 ? UInt32(kc) : UInt32(kVK_ANSI_K)
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(String(hotModifiers), forKey: "hkMods")
        d.set(Int(hotKeyCode), forKey: "hkCode")
        d.synchronize()
    }

    // ── 快捷键显示字符串 ──────────────────────────────────

    private func hotkeyString() -> String {
        var s = ""
        if hotModifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if hotModifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if hotModifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if hotModifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        s += keyCodeName(hotKeyCode)
        return s
    }

    private func keyCodeName(_ code: UInt32) -> String {
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
        default: return "[\(code)]"
        }
    }
}

// ─────────────────────────────────────────────────────────
// MARK: - 入口
// ─────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
