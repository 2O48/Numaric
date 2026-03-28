import Carbon
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isEnabled = false
    var settingsWindow: NSWindow?

    var hotKeyModifiers: UInt32 = 0
    var hotKeyKeyCode: UInt32 = 0

    var keyField: NSTextField?
    var recordButton: NSButton?

    override init() {
        super.init()
        loadSettings()
        print("AppDelegate initialized, default hotkey: \(hotKeyToString())")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("applicationDidFinishLaunching called")
        // 隐藏dock图标
        NSApp.setActivationPolicy(.accessory)
        print("Dock icon hidden")

        setupStatusBar()
        setupEventTap()
    }

    func setupStatusBar() {
        print("setupStatusBar called")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "number", accessibilityDescription: "Numaric")
            button.image?.isTemplate = true
            print("Status bar button set up")
        }

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: isEnabled ? "关闭小键盘" : "开启小键盘", action: #selector(toggleKeypad),
                keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "设置...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        print("Status bar menu set up")
    }

    @objc func toggleKeypad() {
        print("toggleKeypad called, current state: \(isEnabled)")
        isEnabled.toggle()
        print("New state: \(isEnabled)")
        updateStatusBarMenu()
        print("Status bar menu updated")
    }

    func updateStatusBarMenu() {
        guard let menu = statusItem?.menu else {
            print("No status bar menu found")
            return
        }
        menu.items[0].title = isEnabled ? "关闭小键盘" : "开启小键盘"
        print("Status bar menu title updated to: \(menu.items[0].title)")
    }

    func setupEventTap() {
        print("setupEventTap called")
        // 不要覆盖用户保存的设置，只在未设置时使用默认值
        print("Current hotkey: \(hotKeyToString())")

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        print("Event mask: \(eventMask)")

        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                print(
                    "Event tap - Key pressed: \(keyCode), flags: \(flags.rawValue), isEnabled: \(appDelegate.isEnabled)"
                )

                // 检查是否是快捷键
                let cmdPressed = flags.contains(.maskCommand)
                let optPressed = flags.contains(.maskAlternate)
                let shiftPressed = flags.contains(.maskShift)
                let controlPressed = flags.contains(.maskControl)

                print(
                    "Cmd: \(cmdPressed), Opt: \(optPressed), Shift: \(shiftPressed), Control: \(controlPressed)"
                )

                var modifiers = UInt32(0)
                if cmdPressed { modifiers |= UInt32(cmdKey) }
                if optPressed { modifiers |= UInt32(optionKey) }
                if shiftPressed { modifiers |= UInt32(shiftKey) }
                if controlPressed { modifiers |= UInt32(controlKey) }

                print(
                    "Modifiers: \(modifiers), Hotkey modifiers: \(appDelegate.hotKeyModifiers), Keycode: \(keyCode), Hotkey keycode: \(appDelegate.hotKeyKeyCode)"
                )

                if modifiers == appDelegate.hotKeyModifiers
                    && keyCode == Int32(appDelegate.hotKeyKeyCode)
                {
                    print(
                        "Hotkey pressed, toggling keypad: \(appDelegate.isEnabled ? "off" : "on")")
                    DispatchQueue.main.async {
                        appDelegate.toggleKeypad()
                    }
                    return nil
                }

                // 如果小键盘模式未启用，直接返回原始事件
                if !appDelegate.isEnabled {
                    print("Keypad not enabled, passing through event")
                    return Unmanaged.passRetained(event)
                }

                // 检查是否是我们关心的键位
                let keyMap: [Int64: String] = [
                    38: "1",  // J
                    40: "2",  // K
                    37: "3",  // L
                    32: "4",  // U
                    34: "5",  // I
                    31: "6",  // O
                    46: "0",  // M
                    43: "00",  // 逗号
                ]

                if let mappedChar = keyMap[keyCode] {
                    print("Mapped key \(keyCode) to \(mappedChar)")
                    appDelegate.simulateKeyPresses(for: mappedChar)
                    return nil
                }

                // 对于非映射的键，返回原始事件
                print("Key not mapped, passing through event")
                return Unmanaged.passRetained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        self.eventTap = eventTap

        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Event tap enabled successfully")
        } else {
            print(
                "Failed to create event tap - This usually means you need to grant accessibility permissions"
            )
            print(
                "Please go to System Settings > Privacy & Security > Accessibility and add Numaric to the list"
            )
        }
    }

    func simulateKeyPresses(for text: String) {
        print("Simulating key presses for: \(text)")
        for char in text {
            let keyCode = charToKeyCode(char)
            print("Simulating key code: \(keyCode) for char: \(char)")

            // 创建事件源
            let eventSource = CGEventSource(stateID: .combinedSessionState)
            if eventSource == nil {
                print("Failed to create event source")
                return
            }

            // 模拟按下事件
            let keyDownEvent = CGEvent(
                keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
            if keyDownEvent != nil {
                keyDownEvent?.post(tap: .cgSessionEventTap)
                print("Posted key down event for: \(char)")
            } else {
                print("Failed to create key down event")
            }

            // 添加延迟
            usleep(1000)

            // 模拟释放事件
            let keyUpEvent = CGEvent(
                keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
            if keyUpEvent != nil {
                keyUpEvent?.post(tap: .cgSessionEventTap)
                print("Posted key up event for: \(char)")
            } else {
                print("Failed to create key up event")
            }

            // 添加延迟
            usleep(1000)
        }
    }

    func charToKeyCode(_ char: Character) -> CGKeyCode {
        switch char {
        case "0": return UInt16(kVK_ANSI_0)
        case "1": return UInt16(kVK_ANSI_1)
        case "2": return UInt16(kVK_ANSI_2)
        case "3": return UInt16(kVK_ANSI_3)
        case "4": return UInt16(kVK_ANSI_4)
        case "5": return UInt16(kVK_ANSI_5)
        case "6": return UInt16(kVK_ANSI_6)
        case "7": return UInt16(kVK_ANSI_7)
        case "8": return UInt16(kVK_ANSI_8)
        case "9": return UInt16(kVK_ANSI_9)
        default: return UInt16(kVK_Space)
        }
    }

    @objc func showSettings() {
        print("showSettings called")
        if settingsWindow != nil {
            settingsWindow?.makeKeyAndOrderFront(nil)
            print("Settings window already exists, bringing to front")
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Numaric 设置"
        window.center()

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let titleLabel = NSTextField(labelWithString: "切换快捷键设置")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: 250, width: 360, height: 30)
        contentView.addSubview(titleLabel)

        let keyLabel = NSTextField(labelWithString: "快捷键:")
        keyLabel.frame = NSRect(x: 20, y: 210, width: 100, height: 24)
        contentView.addSubview(keyLabel)

        let keyField = NSTextField(frame: NSRect(x: 120, y: 210, width: 150, height: 24))
        keyField.stringValue = hotKeyToString()
        keyField.isEditable = false
        contentView.addSubview(keyField)
        self.keyField = keyField

        let recordButton = NSButton(title: "录制", target: self, action: #selector(recordHotKey))
        recordButton.frame = NSRect(x: 280, y: 210, width: 100, height: 24)
        contentView.addSubview(recordButton)
        self.recordButton = recordButton

        let infoLabel = NSTextField(
            wrappingLabelWithString:
                "键位映射说明:\nJ → 1\nK → 2\nL → 3\nU → 4\nI → 5\nO → 6\nM → 0\n逗号 → 00")
        infoLabel.frame = NSRect(x: 20, y: 20, width: 360, height: 120)
        contentView.addSubview(infoLabel)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
        print("Settings window created and shown")
    }

    @objc func recordHotKey() {
        print("recordHotKey called")
        guard let recordButton = recordButton else {
            print("No record button found")
            return
        }

        recordButton.title = "按下组合键..."
        recordButton.isEnabled = false
        print("Record button updated, waiting for hotkey")

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // 提取修饰键
                let cmdPressed = flags.contains(.maskCommand)
                let optPressed = flags.contains(.maskAlternate)
                let shiftPressed = flags.contains(.maskShift)
                let controlPressed = flags.contains(.maskControl)

                print(
                    "Record hotkey - Key pressed: \(keyCode), Cmd: \(cmdPressed), Opt: \(optPressed), Shift: \(shiftPressed), Control: \(controlPressed)"
                )

                var modifiers = UInt32(0)
                if cmdPressed { modifiers |= UInt32(cmdKey) }
                if optPressed { modifiers |= UInt32(optionKey) }
                if shiftPressed { modifiers |= UInt32(shiftKey) }
                if controlPressed { modifiers |= UInt32(controlKey) }

                // 只记录带有修饰键的组合键
                if modifiers > 0 && keyCode >= 0 && keyCode <= 127 {
                    appDelegate.hotKeyModifiers = modifiers
                    appDelegate.hotKeyKeyCode = UInt32(keyCode)

                    print(
                        "Recorded hotkey: modifiers=\(modifiers), keyCode=\(keyCode), hotkey=\(appDelegate.hotKeyToString())"
                    )

                    // 立即停止录制
                    appDelegate.stopRecording()
                    
                    // 更新UI
                    DispatchQueue.main.async {
                        appDelegate.updateKeyField()
                    }
                }

                return nil
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Record hotkey event tap enabled")

            // 设置5秒超时
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.stopRecording()
            }
        } else {
            print("Failed to create record hotkey event tap")
            self.stopRecording()
        }
    }

    func stopRecording() {
        print("stopRecording called")
        guard let recordButton = recordButton else {
            print("No record button found")
            return
        }

        recordButton.title = "录制"
        recordButton.isEnabled = true
        print("Record button reset")

        saveSettings()
        print("Settings saved")
    }

    func updateKeyField() {
        print("updateKeyField called")
        guard let keyField = keyField else {
            print("No key field found")
            return
        }

        keyField.stringValue = hotKeyToString()
        print("Key field updated to: \(keyField.stringValue)")
    }

    func hotKeyToString() -> String {
        var parts: [String] = []

        if hotKeyModifiers & UInt32(cmdKey) != 0 {
            parts.append("⌘")
        }
        if hotKeyModifiers & UInt32(optionKey) != 0 {
            parts.append("⌥")
        }
        if hotKeyModifiers & UInt32(shiftKey) != 0 {
            parts.append("⇧")
        }
        if hotKeyModifiers & UInt32(controlKey) != 0 {
            parts.append("⌃")
        }

        parts.append(keyCodeToString(hotKeyKeyCode))

        return parts.joined(separator: "+")
    }

    func keyCodeToString(_ keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_Space): return "Space"
        default: return "Unknown"
        }
    }

    func loadSettings() {
        print("loadSettings called")
        let defaults = UserDefaults.standard

        if let modifiers = defaults.object(forKey: "hotKeyModifiers") as? UInt32 {
            hotKeyModifiers = modifiers
            print("Loaded modifiers: \(modifiers)")
        } else {
            // 设置默认快捷键为 Cmd+Opt+K
            hotKeyModifiers = UInt32(cmdKey | optionKey)
            print("Set default modifiers: \(hotKeyModifiers)")
        }

        if let keyCode = defaults.object(forKey: "hotKeyKeyCode") as? UInt32 {
            hotKeyKeyCode = keyCode
            print("Loaded key code: \(keyCode)")
        } else {
            hotKeyKeyCode = UInt32(kVK_ANSI_K)
            print("Set default key code: \(hotKeyKeyCode)")
        }
        print("Loaded hotkey: \(hotKeyToString())")
    }

    func saveSettings() {
        print("saveSettings called")
        let defaults = UserDefaults.standard

        defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers")
        defaults.set(hotKeyKeyCode, forKey: "hotKeyKeyCode")
        print("Saved hotkey: \(hotKeyToString())")
    }

    @objc func quitApp() {
        print("quitApp called")
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
print("App initialized, starting run loop")
app.run()
