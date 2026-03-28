// main.swift
// 编译：swiftc main.swift -framework Carbon -framework Cocoa -o Numaric
// 日志：程序运行后在 ~/numaric.log 实时写入，可用 tail -f ~/numaric.log 观察

import Carbon
import Cocoa

// ─────────────────────────────────────────────────────────
// MARK: - 日志系统
// ─────────────────────────────────────────────────────────

/// 日志文件路径：~/numaric.log
private let kLogPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/numaric.log"
}()

/// 写一行日志（线程安全，带时间戳）
func log(_ message: String) {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let ts = formatter.string(from: now)
    let line = "[\(ts)] \(message)\n"

    // 追加写入
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: kLogPath) {
            if let fh = FileHandle(forWritingAtPath: kLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: kLogPath))
        }
    }
    // 同时打印到 stderr，方便 Xcode / 终端查看
    fputs(line, stderr)
}

// ─────────────────────────────────────────────────────────
// MARK: - 全局常量
// ─────────────────────────────────────────────────────────

/// 合成事件标记，用于在 tap 里跳过自身发出的事件，防止死循环
private let kSyntheticMark: Int64 = 0x4E55_4D52  // "NUMR"

/// 我们关心的四个修饰位掩码
private let kModMask: UInt64 =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue

/// 键位映射
private let kKeyMap: [Int64: String] = [
    38: "1",  // J
    40: "2",  // K
    37: "3",  // L
    32: "4",  // U
    34: "5",  // I
    31: "6",  // O
    46: "0",  // M
    43: "00",  // 逗号
]

private let kCharKeyCode: [Character: CGKeyCode] = [
    "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
]

// ─────────────────────────────────────────────────────────
// MARK: - CGEvent Tap 全局回调（必须是顶层函数）
// ─────────────────────────────────────────────────────────

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        log("[TAP] refcon is nil — 严重错误")
        return Unmanaged.passRetained(event)
    }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return app.onCGEvent(proxy: proxy, type: type, event: event)
}

// ─────────────────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private(set) var isEnabled = false

    // 快捷键（CGEventFlags.rawValue 体系）
    private var hotMods: UInt64 = 0
    private var hotCode: UInt32 = 0

    private var settingsWin: NSWindow?
    private weak var keyField: NSTextField?
    private weak var recBtn: NSButton?

    private var isRecording = false
    private var recMonitor: Any?

    // ── 生命周期 ─────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新建/清空日志文件
        let header = "=== Numaric 启动 ===\n"
        try? header.data(using: .utf8)?.write(to: URL(fileURLWithPath: kLogPath))

        log("applicationDidFinishLaunching")
        log("日志路径: \(kLogPath)")

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
        log("小键盘模式: \(on ? "开启" : "关闭")")
    }

    // ── Event Tap ────────────────────────────────────────

    func installTap() {
        removeTap()

        log("installTap — 开始创建 CGEvent tap")
        log("  当前快捷键: mods=\(hotMods) code=\(hotCode) => \(hotkeyStr())")

        // passRetained：tap 持有一次强引用，removeTap 里 release
        let retained = Unmanaged.passRetained(self)

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: retained.toOpaque()
            )
        else {
            retained.release()
            log("installTap — tapCreate 失败！请检查辅助功能权限")
            showAccessAlert()
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        tapSource = src
        log("installTap — 成功，tap 已启用")
    }

    private func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        // 平衡 installTap 里的 passRetained
        Unmanaged.passUnretained(self).release()
        eventTap = nil
        if let src = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            tapSource = nil
        }
        log("removeTap — tap 已移除")
    }

    private func showAccessAlert() {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "需要辅助功能权限"
            a.informativeText = "请前往「系统设置 → 隐私与安全性 → 辅助功能」添加本程序后重启。"
            a.alertStyle = .warning
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "取消")
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

    func onCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>?
    {

        // tap 被系统暂停 → 重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("[TAP] tap 被系统暂停 (type=\(type.rawValue))，正在重启")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // 跳过自身合成的事件
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == kSyntheticMark {
            log("[TAP] 合成事件放行（userData=\(userData)）")
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawMods = event.flags.rawValue & kModMask
        let flagsRaw = event.flags.rawValue

        log(
            "[TAP] keyDown keyCode=\(keyCode) rawMods=\(rawMods) flags=\(flagsRaw) isEnabled=\(isEnabled) isRecording=\(isRecording)"
        )
        log("  期望快捷键: mods=\(hotMods) code=\(hotCode)")
        log("  mods匹配=\(rawMods == hotMods) code匹配=\(keyCode == Int64(hotCode))")

        // 正在录制 → 吞掉（由 local monitor 处理）
        if isRecording {
            log("  → 录制中，吞掉")
            return nil
        }

        // 检测快捷键
        if rawMods == hotMods && keyCode == Int64(hotCode) {
            log("  → 快捷键命中！切换小键盘")
            DispatchQueue.main.async { self.setEnabled(!self.isEnabled) }
            return nil
        }

        guard isEnabled else {
            return Unmanaged.passRetained(event)
        }

        // 有非 Shift 修饰键 → 放行
        let nonShift = rawMods & ~CGEventFlags.maskShift.rawValue
        if nonShift != 0 {
            log("  → 有修饰键 nonShift=\(nonShift)，放行")
            return Unmanaged.passRetained(event)
        }

        // 查映射
        if let text = kKeyMap[keyCode] {
            log("  → 小键盘映射: keyCode=\(keyCode) → \"\(text)\"")
            postText(text)
            return nil
        }

        log("  → 无映射，放行")
        return Unmanaged.passRetained(event)
    }

    // ── 合成按键 ─────────────────────────────────────────

    private func postText(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        for ch in text {
            guard let kc = kCharKeyCode[ch] else {
                log("[POST] 未知字符 '\(ch)'，跳过")
                continue
            }
            let dn = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
            dn?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
            up?.setIntegerValueField(.eventSourceUserData, value: kSyntheticMark)
            dn?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
            log("[POST] 发送字符 '\(ch)' keyCode=\(kc)")
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
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
        log("设置窗口已打开")
    }

    private func buildSettingsUI(in w: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = root

        let title = lbl("切换快捷键设置", 15, .semibold)
        let kl = lbl("快捷键：", 13)

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

        // 日志路径提示
        let logInfo = lbl("日志: \(kLogPath)", 10, .regular, .tertiaryLabelColor)
        logInfo.maximumNumberOfLines = 1

        let info = lbl(
            "键位映射（小键盘开启时）：\n  J→1  K→2  L→3  U→4  I→5  O→6  M→0  ,→00\n  7/8/9 及其他键原样输入",
            12, .regular, .secondaryLabelColor)
        info.maximumNumberOfLines = 0

        for v in [title, kl, kf, rb, info, logInfo] { root.addSubview(v) }

        let p: CGFloat = 20
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),
            root.heightAnchor.constraint(equalToConstant: 300),

            title.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),

            kl.topAnchor.constraint(equalTo: title.bottomAnchor, constant: p),
            kl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),

            kf.centerYAnchor.constraint(equalTo: kl.centerYAnchor),
            kf.leadingAnchor.constraint(equalTo: kl.trailingAnchor, constant: 8),
            kf.widthAnchor.constraint(equalToConstant: 140),

            rb.centerYAnchor.constraint(equalTo: kl.centerYAnchor),
            rb.leadingAnchor.constraint(equalTo: kf.trailingAnchor, constant: 10),

            info.topAnchor.constraint(equalTo: kl.bottomAnchor, constant: p),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),

            logInfo.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            logInfo.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            logInfo.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
        ])
    }

    private func lbl(
        _ s: String, _ size: CGFloat,
        _ w: NSFont.Weight = .regular,
        _ c: NSColor = .labelColor
    ) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = NSFont.systemFont(ofSize: size, weight: w)
        f.textColor = c
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // ── 录制快捷键 ───────────────────────────────────────

    @objc private func handleRec() { isRecording ? cancelRec() : startRec() }

    private func startRec() {
        guard !isRecording else { return }
        isRecording = true
        recBtn?.title = "按下组合键… (ESC取消)"
        keyField?.stringValue = "等待输入…"
        keyField?.textColor = .systemOrange
        log("录制开始")

        recMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isRecording else { return ev }

            log("[REC] 捕获按键 keyCode=\(ev.keyCode) mods=\(ev.modifierFlags.rawValue)")

            if ev.keyCode == UInt16(kVK_Escape) {
                log("[REC] ESC — 取消录制")
                self.cancelRec()
                return nil
            }

            let mods = ev.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !mods.isEmpty else {
                log("[REC] 无修饰键，忽略")
                return ev
            }

            var cgMods: UInt64 = 0
            if mods.contains(.command) { cgMods |= CGEventFlags.maskCommand.rawValue }
            if mods.contains(.option) { cgMods |= CGEventFlags.maskAlternate.rawValue }
            if mods.contains(.shift) { cgMods |= CGEventFlags.maskShift.rawValue }
            if mods.contains(.control) { cgMods |= CGEventFlags.maskControl.rawValue }

            self.hotMods = cgMods
            self.hotCode = UInt32(ev.keyCode)
            log("[REC] 录制成功: mods=\(cgMods) code=\(ev.keyCode) => \(self.hotkeyStr())")
            self.saveSettings()
            self.finishRec()
            return nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.isRecording else { return }
            log("[REC] 超时，自动取消")
            self.cancelRec()
        }
    }

    private func finishRec() {
        isRecording = false
        if let m = recMonitor {
            NSEvent.removeMonitor(m)
            recMonitor = nil
        }
        recBtn?.title = "录制"
        keyField?.stringValue = hotkeyStr()
        keyField?.textColor = .labelColor
        log("录制结束，当前快捷键: \(hotkeyStr())")
    }

    private func cancelRec() {
        guard isRecording || recMonitor != nil else { return }
        finishRec()
    }

    // ── 持久化 ───────────────────────────────────────────

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "hkMods"), let v = UInt64(s) {
            hotMods = v
            log("loadSettings — 读取 hkMods=\(v) (来自 UserDefaults)")
        } else {
            hotMods = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            log("loadSettings — hkMods 未找到，使用默认值 \(hotMods)")
        }
        let kc = d.integer(forKey: "hkCode")
        hotCode = kc > 0 ? UInt32(kc) : UInt32(kVK_ANSI_K)
        log("loadSettings — hkCode=\(hotCode) (UserDefaults返回 \(kc))")
        log("loadSettings — 最终快捷键: \(hotkeyStr())")
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(String(hotMods), forKey: "hkMods")
        d.set(Int(hotCode), forKey: "hkCode")
        d.synchronize()
        log("saveSettings — hkMods=\(hotMods) hkCode=\(hotCode) => \(hotkeyStr())")

        // 验证立即回读
        let check1 = d.string(forKey: "hkMods") ?? "nil"
        let check2 = d.integer(forKey: "hkCode")
        log("saveSettings — 回读验证: hkMods=\(check1) hkCode=\(check2)")
    }

    // ── 工具 ─────────────────────────────────────────────

    private func hotkeyStr() -> String {
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
