// main.swift
// 编译：swiftc main.swift -framework Carbon -framework Cocoa -o Numaric
//
// 三种模式：
//   字母模式（默认）：所有按键放行，不拦截任何输入
//   小键盘模式：快捷键切换进入，kKeyMap 映射生效（数字/运算符）
//   方向键模式：在小键盘模式下从菜单勾选，kNavMap 映射生效，同时吞掉所有
//              kKeyMap 覆盖的按键（确保不会输出字母/数字）
//
// 关闭小键盘时自动关闭方向键模式。
// "使用方向键"菜单项在小键盘模式关闭时为灰色不可点击。

import Carbon
import Cocoa

// ─────────────────────────────────────────────────────────
// MARK: - 日志（默认关闭，取消注释可启用）
// ─────────────────────────────────────────────────────────

@inline(__always)
func log(_ _: String) {}

// ─────────────────────────────────────────────────────────
// MARK: - 常量
// ─────────────────────────────────────────────────────────

private let kSyntheticMark: Int64 = 0x4E55_4D52

private let kModMask: UInt64 =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue

// 小键盘模式：keycode → 输出字符串
private let kKeyMap: [Int64: String] = [
    38: "1", 40: "2", 37: "3",   // J K L → 1 2 3
    32: "4", 34: "5", 31: "6",   // U I O → 4 5 6
    46: "0", 43: "00",           // M , → 0 00
    44: "+",                     // / → +
    41: "-",                     // ; → -
    35: "*",                     // P → *
    29: "/",                     // 0 → /
]

// 方向键模式：keycode → CGKeyCode（功能键）
// 覆盖 kKeyMap 中的按键，同时还包含额外按键（8/9/7/.）
// kNavMap 中出现的所有 keycode 在方向键模式下都会被拦截，不会透传字母/数字
private let kNavMap: [Int64: CGKeyCode] = [
    32: CGKeyCode(kVK_LeftArrow),      // U → ←
    31: CGKeyCode(kVK_RightArrow),     // O → →
    40: CGKeyCode(kVK_DownArrow),      // K → ↓
    28: CGKeyCode(kVK_UpArrow),        // 8 → ↑
    26: CGKeyCode(kVK_Home),           // 7 → Home
    38: CGKeyCode(kVK_End),            // J → End
    25: CGKeyCode(kVK_PageUp),         // 9 → Page Up
    37: CGKeyCode(kVK_PageDown),       // L → Page Down
    46: CGKeyCode(kVK_Help),           // M → Insert (Help)
    47: CGKeyCode(kVK_ForwardDelete),  // . → Delete（前向删除）
]

// 方向键模式下需要"静默吞掉"的 keycode 集合：
// = kKeyMap 中有但 kNavMap 中没有的键（避免它们输出字符）
// 例如 I(34)→5、,(43)→00、/(44)→+、;(41)→-、P(35)→*、0(29)→/
private let kNavSilentSet: Set<Int64> = {
    let navKeys = Set(kNavMap.keys)
    let numKeys = Set(kKeyMap.keys)
    return numKeys.subtracting(navKeys)
}()

// ─────────────────────────────────────────────────────────
// MARK: - CGEvent Tap 顶层回调
// ─────────────────────────────────────────────────────────

private func tapCB(
    proxy: CGEventTapProxy, type: CGEventType,
    event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    return Unmanaged<AppDelegate>.fromOpaque(refcon)
        .takeUnretainedValue()
        .onEvent(proxy: proxy, type: type, event: event)
}

// ─────────────────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var tap: CFMachPort?
    private var tapSrc: CFRunLoopSource?

    // 模式状态
    private(set) var isEnabled = false      // 小键盘模式
    private(set) var isNavEnabled = false   // 方向键模式（仅在 isEnabled 时有效）

    // 快捷键
    var hotMods: UInt64 = 0
    var hotCode: UInt32 = 0

    // 设置窗口
    private var settingsWin: NSWindow?
    private weak var keyField: NSTextField?
    private weak var recBtn: NSButton?
    private weak var recHint: NSTextField?

    // 录制状态
    private var isRecording = false
    private var recMonitorLocal: Any?
    private var recMonitorGlobal: Any?

    // ── 启动 ─────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        buildStatusBar()
        installTap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ── 状态栏 ───────────────────────────────────────────

    private func buildStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "number.square",
            accessibilityDescription: "Numaric")
        statusItem.button?.image?.isTemplate = true
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()

        // 开关小键盘
        let t1 = NSMenuItem(
            title: isEnabled ? "关闭小键盘" : "开启小键盘",
            action: #selector(actToggle), keyEquivalent: "")
        t1.target = self
        menu.addItem(t1)

        // 方向键模式（仅在小键盘模式开启时可点击）
        let t2 = NSMenuItem(
            title: "使用方向键",
            action: isEnabled ? #selector(actToggleNav) : nil,
            keyEquivalent: "")
        t2.target = self
        t2.state = isNavEnabled ? .on : .off
        // 小键盘未开启时置灰
        if !isEnabled {
            t2.isEnabled = false
        }
        menu.addItem(t2)

        menu.addItem(.separator())

        let t3 = NSMenuItem(title: "设置…", action: #selector(actSettings), keyEquivalent: "")
        t3.target = self
        menu.addItem(t3)

        menu.addItem(.separator())

        let t4 = NSMenuItem(title: "退出", action: #selector(actQuit), keyEquivalent: "")
        t4.target = self
        menu.addItem(t4)

        statusItem.menu = menu
    }

    @objc private func actToggle() { setEnabled(!isEnabled) }
    @objc private func actToggleNav() { setNavEnabled(!isNavEnabled) }
    @objc private func actSettings() { openSettings() }
    @objc private func actQuit() { NSApp.terminate(nil) }

    /// 切换小键盘模式；关闭时同时强制关闭方向键模式
    private func setEnabled(_ on: Bool) {
        isEnabled = on
        if !on { isNavEnabled = false }
        refreshMenu()
        log("小键盘: \(on ? "开启" : "关闭")")
    }

    /// 切换方向键模式（仅在小键盘模式开启时调用）
    private func setNavEnabled(_ on: Bool) {
        guard isEnabled else { return }
        isNavEnabled = on
        refreshMenu()
        log("方向键模式: \(on ? "开启" : "关闭")")
    }

    // ── Event Tap ────────────────────────────────────────

    func installTap() {
        removeTap()
        log("installTap 开始 快捷键=\(hotkeyStr())")

        let retained = Unmanaged.passRetained(self)
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard
            let t = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: tapCB, userInfo: retained.toOpaque()
            )
        else {
            retained.release()
            log("installTap 失败 — 请检查辅助功能权限")
            showAccessAlert()
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSrc = src
        log("installTap 成功")
    }

    private func removeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        Unmanaged.passRetained(self).release()
        tap = nil
        if let s = tapSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            tapSrc = nil
        }
    }

    private func showAccessAlert() {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "需要辅助功能权限"
            a.informativeText =
                "请前往「系统设置 → 隐私与安全性 → 辅助功能」将本程序加入列表并开启。\n\n"
                + "授权后请退出并重新启动程序。\n\n"
                + "注意：每次更改程序路径或重新编译后都需要重新授权。"
            a.alertStyle = .warning
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "稍后")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )!)
            }
        }
    }

    // ── CGEvent 处理 ─────────────────────────────────────

    func onEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // tap 被系统暂停时重启
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("[TAP] 被系统暂停，重启")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // 跳过自身合成事件
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMark {
            return Unmanaged.passRetained(event)
        }

        // 录制中：放行所有事件，让 monitor 能收到
        if isRecording {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawMods = event.flags.rawValue & kModMask

        log("[TAP] kc=\(keyCode) mods=\(rawMods) numpad=\(isEnabled) nav=\(isNavEnabled)")

        // ── 切换快捷键（任何模式下均响应）──
        if rawMods == hotMods && keyCode == Int64(hotCode) {
            log("[TAP] 快捷键命中，切换小键盘")
            DispatchQueue.main.async { self.setEnabled(!self.isEnabled) }
            return nil
        }

        // ── 字母模式：完全放行 ──
        guard isEnabled else { return Unmanaged.passRetained(event) }

        // 有非 Shift 修饰键时放行（不干扰 Cmd/Ctrl/Alt 快捷键）
        if rawMods & ~CGEventFlags.maskShift.rawValue != 0 {
            return Unmanaged.passRetained(event)
        }

        // ── 方向键模式 ──
        if isNavEnabled {
            // kNavMap 中的键 → 发送功能键
            if let navKC = kNavMap[keyCode] {
                log("[TAP] NAV \(keyCode)→kc\(navKC)")
                postKey(navKC)
                return nil
            }
            // kNavSilentSet 中的键（属于 kKeyMap 但不在 kNavMap）→ 静默吞掉，不输出任何字符
            if kNavSilentSet.contains(keyCode) {
                log("[TAP] NAV silent \(keyCode)")
                return nil
            }
            // 其余按键（不在两个映射表中）→ 放行，允许正常输入
            return Unmanaged.passRetained(event)
        }

        // ── 小键盘模式 ──
        if let text = kKeyMap[keyCode] {
            log("[TAP] NUM \(keyCode)→\"\(text)\"")
            postText(text)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // ── 合成字符输出 ─────────────────────────────────────

    /// 输出字符串：数字走虚拟键码，运算符等直接注入 Unicode
    private func postText(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        for ch in text {
            if let kc = kCharKC[ch] {
                let dn = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
                dn?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
                up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
                dn?.post(tap: .cgSessionEventTap)
                up?.post(tap: .cgSessionEventTap)
            } else {
                // UniChar = UInt16，直接注入 Unicode 码位
                var uchar = UniChar(ch.unicodeScalars.first!.value)
                let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                dn?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uchar)
                up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uchar)
                dn?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
                up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
                dn?.post(tap: .cgSessionEventTap)
                up?.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// 发送功能键（方向键/Home/End 等），不注入任何字符
    private func postKey(_ kc: CGKeyCode) {
        let src = CGEventSource(stateID: .privateState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
        dn?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
        up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
        dn?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    // ── 数字字符 → 虚拟键码映射 ─────────────────────────

    private let kCharKC: [Character: CGKeyCode] = [
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
        "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
    ]

    // ── 设置窗口 ─────────────────────────────────────────

    private func openSettings() {
        if let w = settingsWin {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Numaric 设置"
        w.isReleasedWhenClosed = false
        w.center()
        buildSettingsUI(in: w)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            self?.cancelRec()
            self?.settingsWin = nil
        }

        settingsWin = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsUI(in w: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = root

        let title = mkLabel("切换快捷键设置", 15, .semibold)
        let kl = mkLabel("快捷键：", 13)

        let kf = NSTextField()
        kf.stringValue = hotkeyStr()
        kf.isEditable = false
        kf.isSelectable = false
        kf.alignment = .center
        kf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        kf.translatesAutoresizingMaskIntoConstraints = false
        keyField = kf

        let rb = NSButton(title: "录制", target: self, action: #selector(handleRec))
        rb.translatesAutoresizingMaskIntoConstraints = false
        recBtn = rb

        let hint = mkLabel("", 12, .regular, .systemOrange)
        hint.translatesAutoresizingMaskIntoConstraints = false
        recHint = hint

        let infoText =
            "模式说明：\n"
            + "  字母模式（默认）：所有按键正常输入，不拦截任何字符\n"
            + "  小键盘模式：快捷键切换，以下键位生效：\n"
            + "    J→1   K→2   L→3\n"
            + "    U→4   I→5   O→6\n"
            + "    M→0   ,→00\n"
            + "    /→+   ;→-   P→*   主键盘0→/\n"
            + "  方向键模式：在小键盘模式下从菜单勾选，以下键位生效：\n"
            + "    U→←   O→→   K→↓   8→↑\n"
            + "    7→Home  J→End  9→PageUp  L→PageDown\n"
            + "    M→Insert  .→Delete（前向）\n"
            + "    （方向键模式下不输出任何字母或数字）\n"
            + "版本：1.2"
        let info = mkLabel(infoText, 12, .regular, .secondaryLabelColor)
        info.maximumNumberOfLines = 0

        for v in [title, kl, kf, rb, hint, info] { root.addSubview(v) }

        let p: CGFloat = 20
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 500),
            root.heightAnchor.constraint(equalToConstant: 360),

            title.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),

            kl.topAnchor.constraint(equalTo: title.bottomAnchor, constant: p),
            kl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),

            kf.centerYAnchor.constraint(equalTo: kl.centerYAnchor),
            kf.leadingAnchor.constraint(equalTo: kl.trailingAnchor, constant: 8),
            kf.widthAnchor.constraint(equalToConstant: 140),

            rb.centerYAnchor.constraint(equalTo: kl.centerYAnchor),
            rb.leadingAnchor.constraint(equalTo: kf.trailingAnchor, constant: 10),

            hint.topAnchor.constraint(equalTo: kl.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),

            info.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
        ])
    }

    private func mkLabel(
        _ s: String, _ size: CGFloat,
        _ weight: NSFont.Weight = .regular,
        _ color: NSColor = .labelColor
    ) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // ── 录制快捷键 ───────────────────────────────────────

    @objc private func handleRec() { isRecording ? cancelRec() : startRec() }

    private func startRec() {
        guard !isRecording else { return }
        isRecording = true
        recBtn?.title = "取消录制"
        keyField?.stringValue = "等待按键…"
        keyField?.textColor = .systemOrange
        recHint?.stringValue = "请按下想要的组合键（需含 ⌘/⌥/⌃/⇧）"
        log("[REC] 开始录制")

        recMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleRecEvent(ev)
        }
        recMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleRecEvent(ev)
            return nil
        }

        if recMonitorGlobal == nil {
            recHint?.stringValue = "⚠️ 权限不足，仅能录制不含 ⌘ 的快捷键"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.isRecording else { return }
            self.cancelRec()
        }
    }

    private func handleRecEvent(_ ev: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }

            let kc = ev.keyCode
            let mods = ev.modifierFlags.intersection([.command, .option, .shift, .control])

            if kc == UInt16(kVK_Escape) {
                self.cancelRec()
                return
            }
            guard !mods.isEmpty else { return }

            var cgMods: UInt64 = 0
            if mods.contains(.command) { cgMods |= CGEventFlags.maskCommand.rawValue }
            if mods.contains(.option)  { cgMods |= CGEventFlags.maskAlternate.rawValue }
            if mods.contains(.shift)   { cgMods |= CGEventFlags.maskShift.rawValue }
            if mods.contains(.control) { cgMods |= CGEventFlags.maskControl.rawValue }

            self.hotMods = cgMods
            self.hotCode = UInt32(kc)
            self.saveSettings()
            self.finishRec()
        }
    }

    private func finishRec() {
        isRecording = false
        cleanupRecMonitors()
        recBtn?.title = "录制"
        keyField?.stringValue = hotkeyStr()
        keyField?.textColor = .labelColor
        recHint?.stringValue = ""
    }

    private func cancelRec() {
        guard isRecording || recMonitorLocal != nil || recMonitorGlobal != nil else { return }
        isRecording = false
        cleanupRecMonitors()
        recBtn?.title = "录制"
        keyField?.stringValue = hotkeyStr()
        keyField?.textColor = .labelColor
        recHint?.stringValue = ""
    }

    private func cleanupRecMonitors() {
        if let m = recMonitorGlobal { NSEvent.removeMonitor(m); recMonitorGlobal = nil }
        if let m = recMonitorLocal  { NSEvent.removeMonitor(m); recMonitorLocal = nil }
    }

    // ── 持久化 ───────────────────────────────────────────

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "hkMods"), let v = UInt64(s) {
            hotMods = v
        } else {
            hotMods = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        }
        let kc = d.integer(forKey: "hkCode")
        hotCode = kc > 0 ? UInt32(kc) : UInt32(kVK_ANSI_K)
        log("loadSettings => \(hotkeyStr())")
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(String(hotMods), forKey: "hkMods")
        d.set(Int(hotCode), forKey: "hkCode")
        d.synchronize()
    }

    // ── 快捷键显示字符串 ─────────────────────────────────

    func hotkeyStr() -> String {
        var s = ""
        if hotMods & CGEventFlags.maskControl.rawValue   != 0 { s += "⌃" }
        if hotMods & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if hotMods & CGEventFlags.maskShift.rawValue     != 0 { s += "⇧" }
        if hotMods & CGEventFlags.maskCommand.rawValue   != 0 { s += "⌘" }
        s += keyName(hotCode)
        return s
    }

    private func keyName(_ c: UInt32) -> String {
        switch Int(c) {
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
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab:    return "⇥"
        default: return "[\(c)]"
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