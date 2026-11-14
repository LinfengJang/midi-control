import Cocoa
import CoreMIDI
import ApplicationServices

let bundleID = "com.openai.codex"
func midiName(_ object: MIDIObjectRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr, let value else { return "Unknown" }
    return value.takeRetainedValue() as String
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value
}
class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    var window: NSWindow!
    final class OperationStatus: NSTextField {
        var didChange: ((String) -> Void)?
        override var stringValue: String {
            didSet { didChange?(stringValue) }
        }
    }
    let status = OperationStatus(labelWithString: "")
    var device = NSPopUpButton()
    var labels: [NSTextField] = []
    var learnButtons: [NSButton] = []
    var learning: Int?
    var bindings: [String] = {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: "padBindingsRight"), [4, 6, 7, 8].contains(saved.count) {
            return Array((saved + Array(repeating: "", count: 4)).prefix(8))
        }
        let old = defaults.stringArray(forKey: "padBindings")
            ?? Array((defaults.stringArray(forKey: "bindings") ?? []).dropFirst(4))
        let pads = Array((old + ["", ""]).prefix(2)) + Array(repeating: "", count: 6)
        defaults.set(pads, forKey: "padBindingsRight")
        defaults.removeObject(forKey: "padBindings")
        defaults.removeObject(forKey: "bindings")
        return pads
    }()
    var client = MIDIClientRef(), port = MIDIPortRef()
    var sources: [MIDIEndpointRef] = []
    var statusItem: NSStatusItem?
    var connected: MIDIEndpointRef = 0
    var held: Set<String> = []
    var lastAction = Date.distantPast
    let names = ["9 · 打开 ChatGPT 窗口", "10 · 开关语音", "15 · 回车", "16 · Esc", "11 · 语音静音开关", "12 · 听写", "13 · 确认已查看", "14 · 查看 Codex 额度"]
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildSettingsWindow()
        updateLabels()
        MIDIClientCreateWithBlock("MIDI Codex" as CFString, &client) { _ in }
        let result = MIDIInputPortCreateWithBlock(client, "Input" as CFString, &port) { packets, _ in
            withUnsafePointer(to: packets.pointee.packet) { first in
            var cursor = first
            for _ in 0..<packets.pointee.numPackets {
                let packet = cursor.pointee
                let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
                DispatchQueue.main.async { self.receive(bytes) }
                cursor = UnsafePointer(MIDIPacketNext(cursor))
            }
            }
        }
        if result == noErr { refreshDevices() } else { status.stringValue = "无法打开 MIDI：\(result)" }
        window.isReleasedWhenClosed = false
        window.center()
        installApplicationMenu()
        installStatusMenu()
        showSettings()
        if UserDefaults.standard.object(forKey: "lightIntegrationEnabled") as? Bool ?? true {
            lightToggle.state = .on
            toggleLights()
        }
    }

    let settingsTabs = NSTabView()
    var settingsPaneHeight: NSLayoutConstraint!
    let padPane = NSToolbarItem.Identifier("pads")
    let knobPane = NSToolbarItem.Identifier("knobs")
    let knobNames = ["7 · 系统音量", "8 · 屏幕亮度"]
    var knobBindings = UserDefaults.standard.dictionary(forKey: "knobBindings") as? [String: String] ?? [:]
    var knobLabels: [NSTextField] = []
    var knobButtons: [NSButton] = []
    var learningKnob: Int?
    var knobPositions: [Int: Int] = [:]
    var knobRemainders: [Int: Int] = [:]
    let connectionPane = NSToolbarItem.Identifier("connection")

    func buildSettingsWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 478, height: 275),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "MIDI Codex 设置"
        window.delegate = self
        let content = window.contentView!
        let layout = NSStackView()
        layout.orientation = .vertical
        layout.alignment = .width
        layout.spacing = 8
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)
        ])

        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tabs = settingsTabs
        tabs.tabViewType = .noTabsNoBorder
        let toolbar = NSToolbar(identifier: "MIDISettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = padPane
        settingsPaneHeight = tabs.heightAnchor.constraint(equalToConstant: 250)
        settingsPaneHeight.isActive = true
        layout.addArrangedSubview(tabs)
        let pads = settingsPage("打击垫", in: tabs)
        let knobs = settingsPage("旋钮", in: tabs)
        let devices = settingsPage("连接与权限", in: tabs)

        labels = names.map { _ in NSTextField(labelWithString: "") }
        learnButtons = names.indices.map { index in
            let button = NSButton(title: "学习按键", target: self, action: #selector(learn(_:)))
            button.tag = index
            button.setAccessibilityLabel("学习按键：\(names[index])")
            button.widthAnchor.constraint(equalToConstant: 96).isActive = true
            return button
        }
        let grid = NSGridView(views: [0, 1, 4, 5, 6, 7, 2, 3].map { index in
            let parts = names[index].components(separatedBy: " · ")
            let pad = NSTextField(labelWithString: parts[0])
            pad.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            pad.textColor = .secondaryLabelColor
            let shortNames = ["打开 ChatGPT", "语音", "回车", "Esc", "静音", "听写", "确认已查看", "查看额度"]
            let label = NSTextField(labelWithString: shortNames[index])
            label.font = .systemFont(ofSize: 13, weight: .medium)
            labels[index].font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            labels[index].textColor = .secondaryLabelColor
            return [pad, label, labels[index], learnButtons[index]]
        })
        grid.columnSpacing = 10
        grid.rowSpacing = 5
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).width = 120
        grid.column(at: 2).width = 126
        pads.addArrangedSubview(grid)

        let knobGrid = NSGridView(views: knobNames.enumerated().map { index, name in
            let binding = NSTextField(labelWithString: "")
            binding.textColor = .secondaryLabelColor
            knobLabels.append(binding)
            let button = NSButton(title: "学习旋钮", target: self, action: #selector(learnKnob(_:)))
            button.tag = index
            button.setAccessibilityLabel("学习旋钮：\(name)")
            knobButtons.append(button)
            return [NSTextField(labelWithString: name), binding, button]
        })
        knobGrid.columnSpacing = 14
        knobGrid.rowSpacing = 16
        knobGrid.column(at: 0).width = 120
        knobGrid.column(at: 1).width = 140
        knobs.addArrangedSubview(knobGrid)

        device.target = self
        device.action = #selector(selectDevice)
        let refresh = NSButton(title: "刷新设备", target: self, action: #selector(refreshDevices))
        lightToggle.target = self
        lightToggle.action = #selector(toggleLights)
        let permission = NSButton(title: "授权辅助功能", target: self, action: #selector(authorize))
        lightToggle.setAccessibilityLabel("灯光联动")
        let setup = NSGridView(views: [
            [NSTextField(labelWithString: "MIDI 输入"), NSStackView(views: [device, refresh])],
            [NSTextField(labelWithString: "灯光联动"), lightToggle],
            [NSTextField(labelWithString: "辅助功能"), NSStackView(views: [permissionIndicator, permission])]
        ])
        setup.column(at: 0).xPlacement = .trailing
        setup.column(at: 1).xPlacement = .leading
        setup.columnSpacing = 14
        setup.rowSpacing = 16
        devices.addArrangedSubview(setup)
        permissionIndicator.imageScaling = .scaleProportionallyDown
        permissionIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        permissionIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        updatePermissionIndicator()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [padPane, knobPane, connectionPane]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let pads = identifier == padPane
        item.label = pads ? "打击垫" : identifier == knobPane ? "旋钮" : "连接与权限"
        item.image = NSImage(systemSymbolName: pads ? "square.grid.2x2" : identifier == knobPane ? "dial.medium" : "gearshape",
                             accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(selectSettingsPane(_:))
        return item
    }

    @objc func selectSettingsPane(_ sender: NSToolbarItem) {
        let pads = sender.itemIdentifier == padPane
        settingsTabs.selectTabViewItem(at: pads ? 0 : sender.itemIdentifier == knobPane ? 1 : 2)
        learning = nil
        learningKnob = nil
        updateLabels()
        window.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        settingsPaneHeight.constant = pads ? 250 : 128
        let size = NSSize(width: 478, height: pads ? 275 : 152)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        DispatchQueue.main.async { [weak self] in
            if self?.window.isVisible == false { NSApp.setActivationPolicy(.accessory) }
        }
        learning = nil
        learningKnob = nil
        updateLabels()
    }

    func settingsPage(_ label: String, in tabs: NSTabView) -> NSStackView {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let page = NSView()
        item.view = page
        tabs.addTabViewItem(item)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 14)
        ])
        return stack
    }

    @objc func closeSettings() {
        window.close()
    }

    func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MIDI Codex")
        appMenu.addItem(withTitle: "退出 MIDI Codex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(closeSettings), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
    }

    func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let piano = NSImage(systemSymbolName: "pianokeys", accessibilityDescription: "MIDI Codex")
        piano?.isTemplate = true
        item.button?.image = piano
        item.button?.setAccessibilityLabel("MIDI Codex")
        item.button?.toolTip = "MIDI Codex"
        let menu = NSMenu()
        let settings = NSMenuItem(title: "MIDI Codex 设置", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        status.didChange = { [weak self] message in
            self?.statusItem?.button?.toolTip = message
        }
    }

    func updatePermissionIndicator() {
        let granted = AXIsProcessTrusted()
        let label = granted ? "已授权" : "未授权"
        permissionIndicator.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "xmark.circle.fill",
                                            accessibilityDescription: label)
        permissionIndicator.contentTintColor = granted ? .systemGreen : .systemRed
        permissionIndicator.toolTip = label
        permissionIndicator.setAccessibilityLabel(label)
    }

    @objc func showSettings() {
        updatePermissionIndicator()
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                self?.updatePermissionIndicator()
            }
        }
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "DockIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url), icon.isValid {
            NSApp.applicationIconImage = icon
        }
        window.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }
    func updateLabels() {
        for i in names.indices {
            labels[i].stringValue = bindings[i].isEmpty ? "未绑定" : bindings[i]
            learnButtons[i].title = learning == i ? "取消学习" : "学习按键"
        }
        for i in knobNames.indices {
            knobLabels[i].stringValue = knobBindings[String(i)] ?? "未绑定"
            knobButtons[i].title = learningKnob == i ? "取消学习" : "学习旋钮"
        }
    }
    @objc func refreshDevices() {
        if connected != 0 { MIDIPortDisconnectSource(port, connected); connected = 0 }
        sources = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        device.removeAllItems(); device.addItems(withTitles: sources.map(midiName))
        let preferred = UserDefaults.standard.string(forKey: "midiInputName")
        let index = sources.firstIndex { midiName($0) == preferred }
            ?? sources.firstIndex { midiName($0).contains("Master") }
        if let index { device.selectItem(at: index) }
        connectSelectedDevice(savePreference: false)
    }
    @objc func selectDevice() {
        connectSelectedDevice(savePreference: true)
    }
    func connectSelectedDevice(savePreference: Bool) {
        if connected != 0 { MIDIPortDisconnectSource(port, connected); connected = 0 }
        held.removeAll()
        knobPositions.removeAll()
        knobRemainders.removeAll()
        guard sources.indices.contains(device.indexOfSelectedItem) else { status.stringValue = "未发现 MIDI 设备，请连接后刷新。"; return }
        let source = sources[device.indexOfSelectedItem]
        let result = MIDIPortConnectSource(port, source, nil)
        if result == noErr {
            connected = source
            if savePreference { UserDefaults.standard.set(midiName(source), forKey: "midiInputName") }
        }
        status.stringValue = result == noErr ? "已连接 \(midiName(source))，请按琴键。" : "连接失败：\(result)"
    }
    @objc func learn(_ sender: NSButton) {
        learningKnob = nil
        learning = learning == sender.tag ? nil : sender.tag
        status.stringValue = learning == nil ? "已取消学习。" : "请按「\(names[sender.tag])」对应的打击垫。"
        updateLabels()
    }
    @objc func learnKnob(_ sender: NSButton) {
        learning = nil
        learningKnob = learningKnob == sender.tag ? nil : sender.tag
        status.stringValue = learningKnob == nil ? "已取消学习。" : "请转动「\(knobNames[sender.tag])」。"
        updateLabels()
    }

    func controlChange(channel: Int, controller: Int, value: Int) {
        let key = "通道\(channel) · CC \(controller)"
        if let index = learningKnob {
            if knobBindings.contains(where: { $0.key != String(index) && $0.value == key }) {
                status.stringValue = "这个旋钮已绑定另一项。"
                return
            }
            knobBindings[String(index)] = key
            UserDefaults.standard.set(knobBindings, forKey: "knobBindings")
            knobPositions[index] = value
            knobRemainders[index] = 0
            learningKnob = nil
            status.stringValue = "已绑定：\(knobNames[index])"
            updateLabels()
            return
        }
        guard learning == nil,
              let index = knobNames.indices.first(where: { knobBindings[String($0)] == key }) else { return }
        let previous = knobPositions.updateValue(value, forKey: index)
        guard let previous, previous != value else { return }
        guard AXIsProcessTrusted() else {
            status.stringValue = "音量与亮度控制需要辅助功能授权。"
            return
        }
        let travel = knobRemainders[index, default: 0] + value - previous
        let steps = travel / 4
        knobRemainders[index] = (value == 0 || value == 127) ? 0 : travel % 4
        guard steps != 0 else { return }
        // macOS auxiliary key codes from the SDK's ev_keymap.h.
        let keyCode = index == 0 ? (steps > 0 ? 0 : 1) : (steps > 0 ? 2 : 3)
        for _ in 0..<abs(steps) {
            for state in [0xA00, 0xB00] {
                NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                   data1: (keyCode << 16) | state, data2: -1)?
                    .cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    @objc func authorize() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    var runningStatus: UInt8 = 0
    var pending: [UInt8] = []
    var sysex = false
    func receive(_ bytes: [UInt8]) {
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte == 0xF0 { sysex = true; runningStatus = 0; pending = []; continue }
            if byte == 0xF7 { sysex = false; continue }
            if sysex { continue }
            if byte & 0x80 != 0 { runningStatus = byte < 0xF0 ? byte : 0; pending = []; continue }
            guard runningStatus != 0 else { continue }
            pending.append(byte)
            let type = runningStatus & 0xF0
            let length = (type == 0xC0 || type == 0xD0) ? 1 : 2
            if pending.count == length {
                if type == 0x80 || type == 0x90 { note(channel: Int(runningStatus & 15) + 1, number: Int(pending[0]), down: type == 0x90 && pending[1] > 0) }
                if type == 0xB0 {
                    controlChange(channel: Int(runningStatus & 15) + 1, controller: Int(pending[0]), value: Int(pending[1]))
                }
                pending = []
            }
        }
    }
    func note(channel: Int, number: Int, down: Bool) {
        let key = "通道\(channel) · MIDI \(number)"
        if !down { held.remove(key); return }
        guard held.insert(key).inserted, learningKnob == nil else { return }
        if let index = learning {
            if bindings.enumerated().contains(where: { $0.offset != index && $0.element == key }) { status.stringValue = "这个琴键已绑定其他操作，请换一个。"; return }
            bindings[index] = key; UserDefaults.standard.set(bindings, forKey: "padBindingsRight"); learning = nil; updateLabels(); status.stringValue = "已绑定：\(names[index])"; return
        }
        status.stringValue = "收到 \(key)"
        guard let action = bindings.firstIndex(of: key), Date().timeIntervalSince(lastAction) > 0.5 else { return }
        lastAction = Date(); execute(action)
    }
    // Restrict controls to the main conversation window, excluding floating voice/pet windows.
    func conversationWindow(_ app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(root, kAXMainWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func elements(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 50, result.count < 12000 else { return }
            result.append(element)
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return result
    }
    func matchingButtons(in window: AXUIElement, labels: Set<String>) -> [AXUIElement] {
        elements(in: window).filter { element in
            guard attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
                  attribute(element, kAXEnabledAttribute) as? Bool == true else { return false }
            return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains { key in
                guard let text = attribute(element, key) as? String else { return false }
                return labels.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
    }
    func execute(_ action: Int) {
        switch action {
        case 0: openChatGPTWindow()
        case 1: togglePadVoice()
        case 2: sendChatGPTKey(36, name: "回车")
        case 3: sendChatGPTKey(53, name: "Esc")
        case 4:
            pressAudioButton(labels: muteLabels.union(unmuteLabels), action: "语音静音开关")
        case 5:
            pressAudioButton(labels: [
                "dictate", "start dictation", "stop dictation", "finish dictation",
                "听写", "开始听写", "停止听写", "结束听写"
            ], action: "听写")
        case 6:
            guard completionPending || warningPending else { return }
            completionPending = false
            warningPending = false
            completionFrame = nil
            status.stringValue = "已确认查看结果。"
        case 7: readQuota()
        default: return
        }
    }

    func togglePadVoice() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            status.stringValue = "请先打开 Codex。"
            return
        }
        guard AXIsProcessTrusted() else {
            status.stringValue = "语音开关需要辅助功能权限。"
            return
        }
        guard let window = conversationWindow(app) else {
            status.stringValue = "未找到 Codex 主窗口，请先打开目标对话。"
            return
        }
        app.activate(options: [])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let start = matchingButtons(in: window, labels: ["start voice chat", "开启语音聊天", "开始语音聊天", "開始語音對話"])
        let stop = matchingButtons(in: window, labels: ["stop voice chat", "end voice chat", "停止语音聊天", "结束语音聊天", "結束語音對話"])
        let buttons = start + stop
        guard buttons.count == 1 else { status.stringValue = "当前窗口没有唯一的语音开关。"; return }
        let result = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        status.stringValue = result == .success ? "已触发当前对话的语音开关。" : "语音开关未触发。"
    }

    let muteLabels: Set<String> = ["mute", "mute microphone", "mute mic", "静音", "关闭麦克风"]
    let unmuteLabels: Set<String> = ["unmute", "unmute microphone", "unmute mic", "取消静音", "打开麦克风"]

    func pressAudioButton(labels: Set<String>, action: String) {
        guard AXIsProcessTrusted() else {
            status.stringValue = "此操作需要辅助功能权限。"
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let window = conversationWindow(app) else {
            status.stringValue = "请先打开 ChatGPT 对话窗口。"
            return
        }
        let buttons = matchingButtons(in: window, labels: labels)
        guard buttons.count == 1 else {
            status.stringValue = "当前窗口没有唯一可用的「\(action)」按钮。"
            return
        }
        app.activate(options: [])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let result = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        status.stringValue = result == .success ? "已触发「\(action)」。" : "「\(action)」未触发。"
    }

    let lightToggle = NSSwitch()
    let permissionIndicator = NSImageView()
    var permissionTimer: Timer?
    let padLights = DesktopPadLights()
    let lightQueue = DispatchQueue(label: "MIDI Codex lights")
    var lightTimer: Timer?
    var lightBusy = false
    var litApproval: ApprovalLightPhase?
    var litWhite: UInt8?
    var runningLamp = 0
    var nextChaseStep: TimeInterval?
    var litRunningLamp = 0
    var codexRunning = false
    var idleSince: TimeInterval?
    var completionFrame: Int?
    var completionPending = false
    var warningPending = false
    var litWarning = false
    var previousWarnings: [AXUIElement] = []
    var completionNextStep: TimeInterval = 0
    var litCompletionGreen = false
    var micLight = "off"
    var litMic: String?
    let scanQueue = DispatchQueue(label: "MIDI Codex status", qos: .utility)
    var nextScan: TimeInterval = 0
    var scanInFlight = false
    var scanGeneration = 0
    var hasWarningBaseline = false
    var approvalBlinkStarted: Date?

    func openChatGPTWindow() {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { application, error in
            DispatchQueue.main.async {
                guard let application, error == nil else {
                    self.status.stringValue = "无法打开 ChatGPT 窗口。"
                    return
                }
                application.unhide()
                application.activate(options: [])
                self.status.stringValue = "已请求显示 ChatGPT 窗口。"
            }
        }
    }

    func sendChatGPTKey(_ key: CGKeyCode, name: String) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleID else {
            status.stringValue = "请先切到 ChatGPT 窗口。"
            return
        }
        guard AXIsProcessTrusted(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            status.stringValue = "发送按键需要辅助功能权限。"
            return
        }
        down.flags = []
        up.flags = []
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        status.stringValue = "已向 ChatGPT 发送\(name)。"
    }

    @objc func toggleLights() {
        scanGeneration += 1
        UserDefaults.standard.set(lightToggle.state == .on, forKey: "lightIntegrationEnabled")
        if lightToggle.state != .on {
            lightTimer?.invalidate()
            lightTimer = nil
            quotaPercent = nil
            approvalBlinkStarted = nil
            lightBusy = true
            lightQueue.async {
                let error = self.padLights.stop()
                DispatchQueue.main.async {
                    self.lightBusy = false
                    self.lightToggle.toolTip = error
                    if self.lightToggle.state == .on { self.toggleLights() }
                }
            }
            return
        }
        guard lightTimer == nil else { return }
        litApproval = nil
        litWhite = nil
        litQuota = -1
        runningLamp = 0
        nextChaseStep = nil
        litRunningLamp = 0
        codexRunning = false
        idleSince = nil
        completionPending = false
        warningPending = false
        litWarning = false
        previousWarnings = []
        hasWarningBaseline = false
        completionFrame = nil
        litCompletionGreen = false
        litMic = nil
        nextScan = 0
        lightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10, repeats: true) { [weak self] _ in self?.updatePadLights() }
        updatePadLights()
    }

    var quotaLoading = false
    var quotaPercent: Int?
    var quotaFrame = 0
    var quotaDeadline: TimeInterval = 0
    var litQuota = -1
    var litForeground: Bool?

    func readQuota() {
        guard lightToggle.state == .on, !quotaLoading else {
            if !quotaLoading { status.stringValue = "请先开启灯光联动。" }
            return
        }
        quotaLoading = true
        status.stringValue = "正在读取 Codex 额度…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CLIClient.read(timeoutSeconds: 10) }
            DispatchQueue.main.async {
                self.quotaLoading = false
                guard self.lightToggle.state == .on else { return }
                guard case let .success(limits) = result,
                      let window = limits.weekly, window.remaining.isFinite else {
                    self.status.stringValue = "读取额度失败，请检查 Codex CLI 登录后重试。"
                    return
                }
                let percent = Int(window.remaining.rounded(.down))
                self.status.stringValue = "Codex 每周额度剩余 \(percent)%"
                self.quotaPercent = percent
                self.quotaFrame = 0
                self.quotaDeadline = 0
            }
        }
    }

    func updatePadLights() {
        guard !lightBusy else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        scheduleStatusScan(at: uptime)
        let phase = approvalBlinkStarted.map { Int(now.timeIntervalSince($0) / 0.5) % 2 == 0 ? ApprovalLightPhase.on : .off } ?? .idle
        let angle = uptime * 2 * Double.pi / 4
        let white = phase == .idle ? UInt8((13 + 121 * (1 + cos(angle))).rounded()) : 255
        let chase = codexRunning && phase == .idle
        var lamp = 0
        if chase {
            let deadline = nextChaseStep ?? uptime
            if uptime + 0.005 >= deadline {
                lamp = runningLamp % 8 + 1
                nextChaseStep = max(deadline + 0.2, uptime + 0.19)
            } else {
                lamp = runningLamp
            }
        } else {
            nextChaseStep = nil
        }
        let requestedLamp = lamp
        if let frame = completionFrame, uptime >= completionNextStep, completionNextStep.isFinite {
            if frame == 6 {
                completionFrame = nil
            } else {
                completionFrame = frame + 1
                completionNextStep = .infinity
            }
        }
        let flash = completionFrame
        let advancesFlash = flash != nil && !completionNextStep.isFinite
        let warning = warningPending && phase == .idle && !chase
        let green = flash.map { $0 % 2 == 1 } ?? (completionPending && phase == .idle && !chase)
        let brightness: UInt8 = phase != .idle ? (phase == .on ? 210 : 0) : warning ? (Int(uptime * 2) % 2 == 0 ? 210 : 0) : flash != nil ? (green ? 190 : 0) : chase ? 0 : green ? white / 2 : white
        var quota = -1
        var advancesQuota = false
        if let percent = quotaPercent {
            if uptime >= quotaDeadline {
                if quotaFrame == 6 {
                    quotaPercent = nil
                } else {
                    quotaFrame += 1
                    quotaDeadline = .infinity
                    advancesQuota = true
                }
            }
            if quotaPercent != nil { quota = quotaFrame % 2 == 1 ? percent : -2 }
        }
        let displayQuota = quota
        let stepQuota = advancesQuota
        let microphone = micLight
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        guard phase != litApproval || brightness != litWhite || lamp != litRunningLamp || microphone != litMic || green != litCompletionGreen || warning != litWarning || advancesFlash || displayQuota != litQuota || stepQuota || foreground != litForeground else { return }
        lightBusy = true
        lightQueue.async {
            do {
                try self.padLights.update(phase: phase, white: brightness, microphone: microphone, lamp: requestedLamp, completionGreen: green, warning: warning, quota: displayQuota, foreground: foreground)
                DispatchQueue.main.async {
                    self.litCompletionGreen = green
                    self.litWarning = warning
                    self.litQuota = displayQuota
                    self.litForeground = foreground
                    if stepQuota { self.quotaDeadline = ProcessInfo.processInfo.systemUptime + 0.35 }
                    if advancesFlash {
                        self.completionNextStep = ProcessInfo.processInfo.systemUptime + 0.25
                    }
                    self.litApproval = phase
                    self.litWhite = brightness
                    self.litRunningLamp = requestedLamp
                    self.runningLamp = requestedLamp
                    self.litMic = microphone
                    self.lightBusy = false
                    self.lightToggle.toolTip = nil
                }
            } catch {
                let restoreError = self.padLights.stop()
                DispatchQueue.main.async {
                    self.lightBusy = false
                    self.approvalBlinkStarted = nil
                    self.lightTimer?.invalidate()
                    self.lightTimer = nil
                    self.lightToggle.state = .off
                    self.lightToggle.toolTip = restoreError ?? error.localizedDescription
                }
            }
        }
    }

    struct StatusSnapshot {
        var running = false
        var approval = false
        var microphone = "off"
        var warnings: [AXUIElement] = []
    }

    func scheduleStatusScan(at uptime: TimeInterval) {
        guard !scanInFlight, uptime >= nextScan else { return }
        scanInFlight = true
        let generation = scanGeneration
        let includeWarnings = !hasWarningBaseline || codexRunning
        scanQueue.async {
            let snapshot = autoreleasepool { self.readStatus(includeWarnings: includeWarnings) }
            DispatchQueue.main.async {
                self.scanInFlight = false
                guard generation == self.scanGeneration, self.lightTimer != nil else { return }
                self.applyStatus(snapshot, includesWarnings: includeWarnings)
                let active = self.codexRunning || self.approvalBlinkStarted != nil || self.micLight != "off"
                self.nextScan = ProcessInfo.processInfo.systemUptime + (active ? 0.35 : 1.0)
            }
        }
    }

    func readStatus(includeWarnings: Bool) -> StatusSnapshot? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        let main = conversationWindow(app)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? main.map { [$0] } ?? []
        guard !windows.isEmpty else { return nil }
        let allow: Set<String> = ["approve once", "allow once", "allow this conversation",
                                  "仅允许一次", "允许一次", "允许本次对话", "允许当前对话"]
        let deny: Set<String> = ["decline", "deny", "reject", "拒绝", "拒絕"]
        let stop: Set<String> = ["stop generation", "停止生成", "stop", "停止"]
        let voice: Set<String> = ["stop voice chat", "end voice chat", "停止语音聊天",
                                  "结束语音聊天", "mute microphone", "unmute microphone"]
        let warning: Set<String> = ["task failed", "chat failed", "task was interrupted", "task stopped",
                                    "任务失败", "对话失败", "任务已中断", "任务已停止"]
        let relevant = allow.union(deny).union(stop).union(voice).union(muteLabels).union(unmuteLabels)
        var result = StatusSnapshot()
        for window in windows {
            let isMain = main.map { CFEqual($0, window) } ?? false
            var names: Set<String> = []
            var textElements: [AXUIElement] = []
            scanControls(in: window) { element, role in
                switch role {
                case kAXButtonRole:
                    let matching = labels(of: element, keys: [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute])
                        .intersection(relevant)
                    if !matching.isEmpty, attribute(element, kAXEnabledAttribute) as? Bool == true {
                        names.formUnion(matching)
                    }
                case kAXStaticTextRole: textElements.append(element)
                default: break
                }
            }
            result.approval = result.approval || (!names.isDisjoint(with: allow) && !names.isDisjoint(with: deny))
            if isMain {
                result.running = result.running || !names.isDisjoint(with: stop)
                if !names.isDisjoint(with: muteLabels), names.isDisjoint(with: unmuteLabels) {
                    result.microphone = "live"
                } else if !names.isDisjoint(with: unmuteLabels), names.isDisjoint(with: muteLabels) {
                    result.microphone = "muted"
                }
            }
            let checkVoice = !result.running && !names.isDisjoint(with: voice)
            if checkVoice || includeWarnings {
                for element in textElements {
                    let values = labels(of: element, keys: [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
                    if checkVoice, values.contains(where: isVoiceActivityLabel) { result.running = true }
                    if includeWarnings, values.contains(where: { warning.contains($0) || $0.hasPrefix("you stopped after ") }) {
                        result.warnings.append(element)
                    }
                }
            }
        }
        return result
    }

    func scanControls(in root: AXUIElement, visit: (AXUIElement, String?) -> Void) {
        let keys = [kAXRoleAttribute, kAXChildrenAttribute]
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var count = 0
        while let (element, depth) = stack.popLast(), count < 12000 {
            guard depth < 50 else { continue }
            count += 1
            let values = scanAttributes(element, keys: keys)
            let role = values[0] as? String
            visit(element, role)
            if let children = values[1] as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
    }

    func scanAttributes(_ element: AXUIElement, keys: [String]) -> [Any?] {
        var values: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values) == .success,
           let values = values as? [Any], values.count == keys.count {
            return values.map { Optional($0) }
        }
        return keys.map { attribute(element, $0) }
    }

    func labels(of element: AXUIElement, keys: [String]) -> Set<String> {
        Set(scanAttributes(element, keys: keys).compactMap {
            ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }

    func isVoiceActivityLabel(_ value: String) -> Bool {
        let label = value.components(separatedBy: " · ")[0]
        return ["thinking", "running command", "searching the web", "waiting for chat",
                "思考中", "正在思考", "正在运行命令", "正在搜索网页"].contains(label)
            || label.hasPrefix("searching the web for ")
            || (label.hasPrefix("editing ") && (label.hasSuffix(" file") || label.hasSuffix(" files")))
    }

    func applyStatus(_ snapshot: StatusSnapshot?, includesWarnings: Bool) {
        guard let snapshot else {
            approvalBlinkStarted = nil
            micLight = "off"
            codexRunning = false
            idleSince = nil
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if snapshot.approval {
            if approvalBlinkStarted == nil { approvalBlinkStarted = Date() }
        } else {
            approvalBlinkStarted = nil
        }
        micLight = snapshot.microphone
        if includesWarnings && !hasWarningBaseline {
            previousWarnings = snapshot.warnings
            hasWarningBaseline = true
        }
        if snapshot.running || snapshot.approval {
            idleSince = nil
            completionFrame = nil
            codexRunning = codexRunning || snapshot.running || snapshot.approval
        } else if codexRunning {
            if idleSince == nil { idleSince = uptime }
            if let idleSince, uptime - idleSince >= 0.6 {
                codexRunning = false
                warningPending = snapshot.warnings.contains { warning in
                    !previousWarnings.contains { CFEqual($0, warning) }
                }
                previousWarnings = snapshot.warnings
                completionPending = !warningPending
                completionFrame = warningPending ? nil : 0
                completionNextStep = uptime
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lightTimer?.invalidate()
        lightQueue.sync { if let error = padLights.stop() { NSLog("%@", error) } }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { if client != 0 { MIDIClientDispose(client) } }
}
let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
