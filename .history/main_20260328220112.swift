// main.swift
// 编译：swiftc main.swift -framework Carbon -framework Cocoa -o Numaric
//
// 首次使用步骤：
// 1. 编译后把二进制放到固定路径，例如 /usr/local/bin/Numaric（路径变化会导致权限失效）
// 2. 运行一次，程序会弹出辅助功能权限提示
// 3. 在「系统设置→隐私与安全性→辅助功能」中开启 Numaric
// 4. 退出程序，重新运行（授权后需重启才能完全生效）
//
// 日志：~/numaric.log，可用 tail -f ~/numaric.log 实时查看

import Carbon
import Cocoa

// ─────────────────────────────────────────────────────────
// MARK: - 日志
// ─────────────────────────────────────────────────────────

// private let kLogURL: URL = FileManager.default
//     .homeDirectoryForCurrentUser.appendingPathComponent("numaric.log")
// private let logQ = DispatchQueue(label: "log", qos: .utility)

func log(_ msg: String) {
    logQ.async {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(f.string(from: Date()))] \(msg)\n"
        fputs(line, stderr)
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: kLogURL) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? data.write(to: kLogURL)
        }
    }
}

@inline(__always)
func log(_ _: String) {}

// ─────────────────────────────────────────────────────────
// MARK: - 常量
// ─────────────────────────────────────────────────────────

private let kSyntheticMark: Int64 = 0x4E55_4D52

private let kModMask: UInt64 =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue

private let kKeyMap: [Int64: String] = [
    38: "1", 40: "2", 37: "3",
    32: "4", 34: "5", 31: "6",
    46: "0", 43: "00",
]

private let kCharKC: [Character: CGKeyCode] = [
    "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
]

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

    private(set) var isEnabled = false

    var hotMods: UInt64 = 0
    var hotCode: UInt32 = 0

    private var settingsWin: NSWindow?
    private weak var keyField: NSTextField?
    private weak var recBtn: NSButton?
    private weak var recHint: NSTextField?

    // [FIX] 使用原子操作保证录制状态线程安全，避免多次回调竞争
    private var isRecording = false
    private var recMonitorLocal: Any?
    private var recMonitorGlobal: Any?

    // ── 启动 ─────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        // try? "=== Numaric 启动 ===\n".data(using: .utf8)?.write(to: kLogURL)
        log("启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
        log("路径: \(ProcessInfo.processInfo.arguments[0])")

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
        log("状态栏已创建")
    }

    private func refreshMenu() {
        let menu = NSMenu()

        let t1 = NSMenuItem(
            title: isEnabled ? "关闭小键盘" : "开启小键盘",
            action: #selector(actToggle), keyEquivalent: "")
        t1.target = self
        menu.addItem(t1)
        menu.addItem(.separator())
        let t2 = NSMenuItem(title: "设置…", action: #selector(actSettings), keyEquivalent: "")
        t2.target = self
        menu.addItem(t2)
        menu.addItem(.separator())
        let t3 = NSMenuItem(title: "退出", action: #selector(actQuit), keyEquivalent: "")
        t3.target = self
        menu.addItem(t3)

        statusItem.menu = menu
    }

    @objc private func actToggle() { setEnabled(!isEnabled) }
    @objc private func actSettings() { openSettings() }
    @objc private func actQuit() { NSApp.terminate(nil) }

    private func setEnabled(_ on: Bool) {
        isEnabled = on
        refreshMenu()
        log("小键盘: \(on ? "开启" : "关闭")")
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
        // [FIX] passRetained(self).release() 才能平衡 installTap 中的 passRetained
        // 原来的 passUnretained(self).release() 会导致 over-release crash
        Unmanaged.passRetained(self).release()
        tap = nil
        if let s = tapSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            tapSrc = nil
        }
        log("removeTap 完成")
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
                    URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )!)
            }
        }
    }

    // ── CGEvent 处理 ─────────────────────────────────────

    func onEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

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

        // [FIX] 录制中：tap 必须放行事件（passRetained），让 NSEvent global monitor 能收到
        // 原来 return nil 会在事件链最顶端吞掉按键，global monitor 永远收不到任何按键
        if isRecording {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawMods = event.flags.rawValue & kModMask

        log("[TAP] kc=\(keyCode) mods=\(rawMods) enabled=\(isEnabled)")

        // 切换快捷键
        if rawMods == hotMods && keyCode == Int64(hotCode) {
            log("[TAP] 快捷键命中，切换")
            DispatchQueue.main.async { self.setEnabled(!self.isEnabled) }
            return nil
        }

        guard isEnabled else { return Unmanaged.passRetained(event) }

        // 有非 Shift 修饰键时放行
        if rawMods & ~CGEventFlags.maskShift.rawValue != 0 {
            return Unmanaged.passRetained(event)
        }

        if let text = kKeyMap[keyCode] {
            log("[TAP] 映射 \(keyCode)→\"\(text)\"")
            postText(text)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // ── 合成按键 ─────────────────────────────────────────

    private func postText(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        for ch in text {
            guard let kc = kCharKC[ch] else { continue }
            let dn = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
            dn?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
            up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
            dn?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    // ── 设置窗口 ─────────────────────────────────────────

    private func openSettings() {
        if let w = settingsWin {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
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
            "键位映射（小键盘开启时生效）：\n" + " J→1  K→2  L→3\n" + " U→4  I→5  O→6\n" + " M→0  ,→00\n"
            + " 7 / 8 / 9 及其他键原样输入"
        let info = mkLabel(infoText, 12, .regular, .secondaryLabelColor)
        info.maximumNumberOfLines = 0

        // let logHint = mkLabel("日志: ~/numaric.log", 10, .regular, .tertiaryLabelColor)

        for v in [title, kl, kf, rb, hint, info, logHint] { root.addSubview(v) }

        let p: CGFloat = 20
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 480),
            root.heightAnchor.constraint(equalToConstant: 320),

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

            // logHint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            // logHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
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

        // Global monitor：捕获全局按键，包括含 ⌘ 的组合
        // [FIX] tap 已改为在 isRecording 时放行事件，global monitor 现在可以正常收到所有按键
        recMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleRecEvent(ev)
        }

        // Local monitor：兜底，捕获发给本 App 的按键
        recMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleRecEvent(ev)
            return nil  // 吞掉，避免触发菜单等
        }

        if recMonitorGlobal == nil {
            log("[REC] global monitor 创建失败（权限不足？）")
            recHint?.stringValue = "⚠️ 权限不足，global monitor 不可用，仅能录制不含 ⌘ 的快捷键"
        }

        // 10 秒超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.isRecording else { return }
            log("[REC] 超时取消")
            self.cancelRec()
        }
    }

    private func handleRecEvent(_ ev: NSEvent) {
        // [FIX] 使用 DispatchQueue.main 确保线程安全，避免 global/local monitor 同时触发
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }

            let kc = ev.keyCode
            let mods = ev.modifierFlags.intersection([.command, .option, .shift, .control])

            log("[REC] keyCode=\(kc) mods=\(mods.rawValue)")

            if kc == UInt16(kVK_Escape) {
                log("[REC] ESC → 取消")
                self.cancelRec()
                return
            }

            guard !mods.isEmpty else {
                log("[REC] 无修饰键，忽略")
                return
            }

            var cgMods: UInt64 = 0
            if mods.contains(.command) { cgMods |= CGEventFlags.maskCommand.rawValue }
            if mods.contains(.option) { cgMods |= CGEventFlags.maskAlternate.rawValue }
            if mods.contains(.shift) { cgMods |= CGEventFlags.maskShift.rawValue }
            if mods.contains(.control) { cgMods |= CGEventFlags.maskControl.rawValue }

            self.hotMods = cgMods
            self.hotCode = UInt32(kc)
            log("[REC] 录制成功 mods=\(cgMods) code=\(kc) => \(self.hotkeyStr())")
            self.saveSettings()
            self.finishRec()
        }
    }

    private func finishRec() {
        // [FIX] 先设 isRecording=false，再 cleanup，避免 cleanup 后回调再次触发
        isRecording = false
        cleanupRecMonitors()
        recBtn?.title = "录制"
        keyField?.stringValue = hotkeyStr()
        keyField?.textColor = .labelColor
        recHint?.stringValue = ""
        log("[REC] 结束，当前快捷键: \(hotkeyStr())")
    }

    private func cancelRec() {
        guard isRecording || recMonitorLocal != nil || recMonitorGlobal != nil else { return }
        // [FIX] 先设 isRecording=false，再 cleanup
        isRecording = false
        cleanupRecMonitors()
        recBtn?.title = "录制"
        keyField?.stringValue = hotkeyStr()
        keyField?.textColor = .labelColor
        recHint?.stringValue = ""
        log("[REC] 已取消")
    }

    private func cleanupRecMonitors() {
        if let m = recMonitorGlobal {
            NSEvent.removeMonitor(m)
            recMonitorGlobal = nil
        }
        if let m = recMonitorLocal {
            NSEvent.removeMonitor(m)
            recMonitorLocal = nil
        }
    }

    // ── 持久化 ───────────────────────────────────────────

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "hkMods"), let v = UInt64(s) {
            hotMods = v
            log("loadSettings hkMods=\(v) (UserDefaults)")
        } else {
            hotMods = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            log("loadSettings hkMods=默认值\(hotMods)")
        }

        let kc = d.integer(forKey: "hkCode")
        hotCode = kc > 0 ? UInt32(kc) : UInt32(kVK_ANSI_K)
        log("loadSettings hkCode=\(hotCode) => \(hotkeyStr())")
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(String(hotMods), forKey: "hkMods")
        d.set(Int(hotCode), forKey: "hkCode")
        d.synchronize()
        let v1 = d.string(forKey: "hkMods") ?? "nil"
        let v2 = d.integer(forKey: "hkCode")
        log("saveSettings hkMods=\(hotMods) hkCode=\(hotCode) | 回读: \(v1)/\(v2)")
    }

    // ── 显示字符串 ───────────────────────────────────────

    func hotkeyStr() -> String {
        var s = ""
        if hotMods & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if hotMods & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if hotMods & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if hotMods & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
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
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
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
