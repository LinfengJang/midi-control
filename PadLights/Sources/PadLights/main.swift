import Foundation
import CoreMIDI
import AppKit
import PadLightProtocol
import NativeMIDI

struct Failure: LocalizedError { var message: String; var errorDescription: String? { message }; init(_ message: String) { self.message = message } }
func name(_ object: MIDIObjectRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr, let value else { return "Unknown" }
    return value.takeRetainedValue() as String
}
func check(_ status: OSStatus) throws { if status != noErr { throw Failure("CoreMIDI failed: \(status)") } }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
func rgb(_ text: String) throws -> [UInt8] {
    let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let number = UInt32(value, radix: 16) else { throw Failure("Color must be RRGGBB.") }
    return [UInt8((number >> 16) & 255), UInt8((number >> 8) & 255), UInt8(number & 255)]
}
final class Transport {
    var connection: OpaquePointer?
    let condition = NSCondition()
    var pending: [UInt8] = [], replies: [[UInt8]] = []
    init() throws {
        let targets = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter { name($0) == "SINCOSMK25II-Private" }
        let inputs = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { name($0).hasPrefix("SINCOSMK25II-") || name($0) == "SINCO端口3" }
        guard targets.count == 1, !inputs.isEmpty else { throw Failure("Expected exactly one SMK25II Private output and its reply inputs. Connect via USB.") }
        var error: OSStatus = 0
        DispatchQueue.main.sync {
            connection = inputs.withUnsafeBufferPointer { buffer in
                NMOpen(targets[0], buffer.baseAddress, inputs.count, { bytes, count, context in
                    guard let context, let bytes else { return }
                    Unmanaged<Transport>.fromOpaque(context).takeUnretainedValue().receive(Array(UnsafeBufferPointer(start: bytes, count: count)))
                }, Unmanaged.passUnretained(self).toOpaque(), &error)
            }
        }
        try check(error)
        guard connection != nil else { throw Failure("Cannot open MIDI connection") }
        Thread.sleep(forTimeInterval: 2)
    }
    deinit { NMClose(connection) }
    func receive(_ bytes: [UInt8]) {
        if CommandLine.arguments.contains("--trace") { fputs("CHUNK \(hex(bytes))\n", stderr) }
        condition.lock(); defer { condition.unlock() }
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte == 0xF0 { pending = [byte] }
            else if byte == 0xF7, !pending.isEmpty {
                pending.append(byte); if CommandLine.arguments.contains("--trace") { fputs("RX \(hex(pending))\n", stderr) }; replies.append(pending); pending = []
                if replies.count > 64 { replies.removeFirst() }; condition.signal()
            } else if !pending.isEmpty {
                if byte >= 128 || pending.count > 65536 { pending = [] } else { pending.append(byte) }
            }
        }
    }
    func exchange(_ message: [UInt8], matches: ([UInt8]) -> Bool) throws -> [UInt8] {
        condition.lock(); replies = []; condition.unlock()
        if CommandLine.arguments.contains("--trace") { fputs("TX \(hex(message))\n", stderr) }
        try send(message)
        let deadline = Date().addingTimeInterval(3)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let index = replies.firstIndex(where: matches) { return replies.remove(at: index) }
            if !condition.wait(until: deadline) { throw Failure("No matching device reply; no save command was sent.") }
        }
    }
    func send(_ bytes: [UInt8]) throws {
        let result = bytes.withUnsafeBufferPointer { NMSend(connection, $0.baseAddress, bytes.count) }
        try check(result)
    }
    func read(type: UInt8, address: Int, count: Int) throws -> [UInt8] {
        let message = try SMK25II.read(type: type, address: address, count: count)
        let reply = try exchange(message) { (try? SMK25II.readData($0, type: type, address: address, count: count)) != nil }
        return try SMK25II.readData(reply, type: type, address: address, count: count)
    }
    func set(preset: Int, pad: Int, color: [UInt8]) throws {
        let message = try SMK25II.color(preset: preset, pad: pad, rgb: color)
        let reply = try exchange(message) {
            guard let parsed = try? SMK25II.parse($0) else { return false }
            return parsed.command == 0 && parsed.body.count == 1
        }
        guard (try SMK25II.parse(reply)).body == [0] else { throw Failure("Device rejected color write") }
        let address = try SMK25II.colorAddress(preset: preset, pad: pad)
        let actual = try read(type: 5, address: address, count: 3)
        guard actual == color else { throw Failure("Readback does not match requested color") }
    }
}
struct AllSnapshot: Codable { let model: String; let preset: Int; let entries: [[UInt8]]; let createdAt: Date }
struct LightMemory: Codable { var colors: [String: [UInt8]] }
struct Snapshot: Codable { let model: String; let preset: Int; let pad: Int; let color: [UInt8]; let createdAt: Date }
let desktopPads = Array(1...10) + [15, 16, 11, 12, 13, 14]

struct DesktopOverlay {
    let preset: Int
    let colors: [[UInt8]]
}
var desktopOverlay: DesktopOverlay?
var desktopTopColors: [[UInt8]]?
var desktopApprovalPending: Bool?
var desktopForeground: Bool?
var desktopMic: String?

func restoreDesktopLights(using transport: Transport) throws {
    guard let overlay = desktopOverlay else { return }
    var failed: [Int] = []
    for (offset, color) in overlay.colors.enumerated() {
        let pad = desktopPads[offset]
        do { try transport.set(preset: overlay.preset, pad: pad, color: color) }
        catch { failed.append(pad) }
    }
    guard failed.isEmpty else { throw Failure("未能恢复打击垫 \(failed)；键盘断电后会恢复预设。") }
    desktopOverlay = nil
    desktopTopColors = nil
    desktopApprovalPending = nil
    desktopForeground = nil
    desktopMic = nil
}

var sessionOutput: Data?
var serving = false
var sessionTransport: Transport?
var sessionLock: Int32 = -1
func emit<T: Encodable>(_ value: T) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value); if serving { sessionOutput = data } else { print(String(data: data, encoding: .utf8)!) } }
var args = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
func option(_ key: String) -> String? { options[key] }
func number(_ key: String, default fallback: Int? = nil) throws -> Int {
    if let value = option(key) {
        guard let result = Int(value) else { throw Failure("Invalid \(key)") }; return result
    }
    if let fallback { return fallback }; throw Failure("Missing or invalid \(key)")
}
var lastEditorCheck = -Double.infinity

func run() throws {
    let command = args.first ?? "help"
    if command == "help" || args.contains("--help") {
        print("""
        padlights state
        padlights batch --pads 1,3,9 --operation off --backup /absolute/before.json --memory /absolute/memory.json
        padlights verify-all --backup /absolute/all-pads.json
        padlights restore-all --backup /absolute/all-pads.json
        padlights devices
        padlights read --pad 5 [--preset 1]
        padlights color --pad 5 --hex FF0000 --backup /absolute/backup.json [--preset 1]
        padlights off --pad 5 --backup /absolute/backup.json [--preset 1]
        padlights on --backup /absolute/backup.json
        padlights restore --backup /absolute/backup.json
        padlights packet --pad 5 --preset 1 --hex 00AA7F
        padlights demo --pad 5 --hex FF0000 --seconds 5 --backup /absolute/backup.json
        RGB writes only, no persistence/save command. With no --preset, uses the active preset.
        off uses RGB black; restore returns to the backed-up color. Do not run concurrently with MidiSuite.
        """); return
    }
    let allowed: [String: Set<String>] = [
        "state": ["--trace"],
        "desktop-lights": ["--phase", "--white", "--mic", "--lamp", "--green", "--warning", "--quota", "--foreground"], "desktop-restore": [],
        "batch": ["--pads", "--operation", "--hex", "--backup", "--memory", "--reference", "--trace"],
        "verify-all": ["--backup", "--trace"], "restore-all": ["--backup", "--trace"],
        "devices": [], "read": ["--pad", "--preset", "--trace"],
        "color": ["--pad", "--preset", "--hex", "--backup", "--trace"],
        "off": ["--pad", "--preset", "--backup", "--trace"],
        "restore": ["--backup", "--trace"], "on": ["--backup", "--trace"],
        "packet": ["--pad", "--preset", "--hex"],
        "demo": ["--pad", "--preset", "--hex", "--backup", "--seconds", "--trace"]
    ]
    guard let keys = allowed[command] else { throw Failure("Unknown command") }
    var i = 1
    while i < args.count {
        let key = args[i]
        guard keys.contains(key), options[key] == nil else { throw Failure("Unknown or repeated option: \(key)") }
        if key == "--trace" { options[key] = "true"; i += 1; continue }
        guard i + 1 < args.count, !args[i+1].hasPrefix("--") else { throw Failure("Missing value for \(key)") }
        options[key] = args[i+1]; i += 2
    }
    if command == "devices" {
        for i in 0..<MIDIGetNumberOfSources() { print("input: \(name(MIDIGetSource(i)))") }
        for i in 0..<MIDIGetNumberOfDestinations() { print("output: \(name(MIDIGetDestination(i)))") }; return
    }
    if command == "packet" {
        let frame = try SMK25II.color(preset: number("--preset"), pad: number("--pad"), rgb: rgb(option("--hex") ?? ""))
        print(frame.map { String(format: "%02X", $0) }.joined(separator: " ")); return
    }
    if command.hasPrefix("desktop-"), !serving { throw Failure("Desktop lights require a live session") }
    if command == "desktop-restore", desktopOverlay == nil { try emit(["ok": true]); return }
    let now = ProcessInfo.processInfo.systemUptime
    if !serving || command != "desktop-lights" || now - lastEditorCheck >= 1 {
        let editors = ["com.musicalinstruments.musicalInstruments", "com.sinco.MidiSuite"]
        guard !NSWorkspace.shared.runningApplications.contains(where: { editors.contains($0.bundleIdentifier ?? "") || ["MidiSuite", "Midi Suite"].contains($0.localizedName ?? "") }) else { throw Failure("Quit MidiSuite first to avoid competing configuration requests.") }
        lastEditorCheck = now
    }
    let lockPath = "/tmp/smk25ii-padlights-\(getuid()).lock"
    let lockFD = sessionLock >= 0 ? sessionLock : open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { throw Failure("Cannot open device lock") }
    defer { if !serving { close(lockFD) } }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another PadLights operation is already running") }
    if serving { sessionLock = lockFD }
    let transport: Transport
    if let cached = sessionTransport { transport = cached } else { transport = try Transport(); if serving { sessionTransport = transport } }
    if !serving || command != "desktop-lights" || desktopOverlay == nil {
        let identity = try transport.exchange(SMK25II.frame(command: 0x11, body: [])) {
            (try? SMK25II.parse($0).command) == 0x11
        }
        let identityBody = try SMK25II.parse(identity).body
        guard String(bytes: identityBody, encoding: .ascii)?.contains("SMK25II") == true else { throw Failure("Device identity is not SMK25II") }
    }
    let global = try transport.read(type: 4, address: 0, count: 20)
    guard global.count == 20, global[0] < 8 else { throw Failure("Invalid active preset header") }
    func readAll(_ preset: Int) throws -> AllSnapshot {
        var entries: [[UInt8]] = []
        for pad in 1...16 {
            let address = try SMK25II.colorAddress(preset:preset,pad:pad)-5
            entries.append(try transport.read(type:5,address:address,count:64) + transport.read(type:5,address:address+64,count:10))
        }
        return AllSnapshot(model:"SMK25II",preset:preset,entries:entries,createdAt:Date())
    }
    let activePreset=Int(global[0])+1
    if command == "desktop-restore" {
        try restoreDesktopLights(using: transport)
        try emit(["ok": true]); return
    }
    if command == "desktop-lights" {
        guard let phase = option("--phase"), ["idle", "on", "off"].contains(phase) else { throw Failure("Invalid light phase") }
        if let overlay = desktopOverlay, overlay.preset != activePreset {
            try restoreDesktopLights(using: transport)
            throw Failure("键盘预设已切换，请重新开启灯光联动。")
        }
        let initial = desktopOverlay == nil
        if initial {
            let colors = try desktopPads.map { pad in
                try transport.read(type: 5, address: SMK25II.colorAddress(preset: activePreset, pad: pad), count: 3)
            }
            desktopOverlay = DesktopOverlay(preset: activePreset, colors: colors)
        }
        let pending = phase != "idle"
        let foreground = option("--foreground") == "1"
        let intensity: UInt8 = pending ? 255 : 64
        let windowColor: [UInt8] = foreground ? [120, 83, 255] : [30, 21, 64]
        let white = try number("--white", default: 255)
        guard let level = UInt8(exactly: white) else { throw Failure("Invalid white light intensity") }
        let microphone = option("--mic") ?? "off"
        let micColor: [UInt8]
        switch microphone {
        case "live": micColor = [255, 210, 0]
        case "muted": micColor = [125, 0, 45]
        case "off": micColor = [65, 43, 0]
        default: throw Failure("Invalid microphone light state")
        }
        let lamp = try number("--lamp", default: 0)
        guard (0...8).contains(lamp) else { throw Failure("Invalid running light position") }
        let quota = try number("--quota", default: -1)
        guard (-2...100).contains(quota) else { throw Failure("Invalid quota percentage") }
        let quotaColor: [UInt8] = quota <= 30 ? [220, 0, 0] : quota < 60 ? [210, 157, 0] : [63, 190, 11]
        let filled = (max(0, quota) * 8 + 99) / 100
        let topColors: [[UInt8]] = (1...8).map { pad in
            if quota != -1 { return pad <= filled ? quotaColor : [0, 0, 0] }
            if phase != "idle" { return [level, UInt8(Int(level) * 3 / 4), 0] }
            if option("--warning") == "1" { return [level, 0, 0] }
            if option("--green") == "1" { return [level / 3, level, level / 16] }
            if lamp == 0 { return [level, level, level] }
            return pad == lamp ? [255, 255, 255] : [0, 0, 0]
        }
        let targets = topColors
            + [windowColor, [255, 230, 0], [0, intensity, 0], [intensity, 0, 0], micColor, [255, 105, 0], [0, 140, 200], [255, 35, 160]]
        let order = desktopPads.indices.filter { $0 != lamp - 1 } + (lamp == 0 ? [] : [lamp - 1])
        for index in order {
            if !initial {
                if index < 8, desktopTopColors?[index] == topColors[index] { continue }
                if index == 8, desktopForeground == foreground { continue }
                if index == 9 || index >= 13 { continue }
                if (10..<12).contains(index), desktopApprovalPending == pending { continue }
                if index == 12, desktopMic == microphone { continue }
            }
            try transport.set(preset: activePreset, pad: desktopPads[index], color: targets[index])
        }
        desktopTopColors = topColors
        desktopApprovalPending = pending
        desktopForeground = foreground
        desktopMic = microphone
        try emit(["ok": true]); return
    }
    if command == "state" { try emit(readAll(activePreset));return }
    if command == "batch" {
        let pads=try SMK25II.selectedPads(option("--pads") ?? "")
        guard let operation=option("--operation"), ["color","off","on","restore"].contains(operation),
              let backup=option("--backup"), backup.hasPrefix("/"),
              let memoryPath=option("--memory"),memoryPath.hasPrefix("/"),backup != memoryPath else { throw Failure("Invalid batch operation, backup or memory path") }
        guard !FileManager.default.fileExists(atPath:backup) else { throw Failure("Backup exists; use a new file") }
        let before=try readAll(activePreset)
        var memory=LightMemory(colors:[:])
        if FileManager.default.fileExists(atPath:memoryPath) {
            memory=try JSONDecoder().decode(LightMemory.self,from:Data(contentsOf:URL(fileURLWithPath:memoryPath)))
            guard memory.colors.values.allSatisfy({$0.count==3}) else { throw Failure("Invalid color memory") }
        }
        var reference: AllSnapshot?
        if operation == "restore" {
            guard let path=option("--reference") else { throw Failure("Missing --reference") }
            let loaded=try JSONDecoder().decode(AllSnapshot.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
            guard loaded.model == "SMK25II",loaded.preset==activePreset,loaded.entries.count==16,loaded.entries.allSatisfy({$0.count==SMK25II.padStride}) else { throw Failure("Reference does not match the active preset") }
            reference=loaded
        }
        let fallback=try rgb(option("--hex") ?? "00AA7F")
        var targets: [Int:[UInt8]]=[:]
        for pad in pads {
            let original=Array(before.entries[pad-1][5...7]),key="\(activePreset):\(pad)"
            if original.contains(where:{$0 != 0}) { memory.colors[key]=original }
            switch operation {
            case "off": targets[pad]=[0,0,0]
            case "on": targets[pad]=memory.colors[key] ?? fallback
            case "restore": targets[pad]=Array(reference!.entries[pad-1][5...7])
            default: targets[pad]=fallback
            }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(before).write(to:URL(fileURLWithPath:backup),options:[.withoutOverwriting])
        try encoder.encode(memory).write(to:URL(fileURLWithPath:memoryPath),options:[.atomic])
        do {
            for pad in pads { try transport.set(preset:activePreset,pad:pad,color:targets[pad]!) }
            let after=try readAll(activePreset)
            for pad in 1...16 {
                var expected=before.entries[pad-1]
                if let target=targets[pad] { expected.replaceSubrange(5...7,with:target) }
                guard after.entries[pad-1]==expected else { throw Failure("Batch verification mismatch for pad \(pad)") }
            }
            guard try transport.read(type:4,address:0,count:20)==global else { throw Failure("Active preset or global settings changed during operation") }
            for pad in pads where targets[pad]!.contains(where:{$0 != 0}) { memory.colors["\(activePreset):\(pad)"]=targets[pad]! }
            try encoder.encode(memory).write(to:URL(fileURLWithPath:memoryPath),options:[.atomic])
            try emit(after);return
        } catch {
            let originalError=error
            var failures:[Int]=[]
            for pad in pads { do { try transport.set(preset:activePreset,pad:pad,color:Array(before.entries[pad-1][5...7])) } catch { failures.append(pad) } }
            if !failures.isEmpty { throw Failure("Batch failed; could not restore pads \(failures). Use restore-all with the saved backup.") }
            throw Failure("Batch failed and selected colors were restored: \(originalError.localizedDescription)")
        }
    }
    if command == "verify-all" || command == "restore-all" {
        guard let path = option("--backup"), path.hasPrefix("/") else { throw Failure("An absolute --backup path is required") }
        var snapshot: AllSnapshot
        if command == "restore-all" {
            snapshot = try JSONDecoder().decode(AllSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard snapshot.model == "SMK25II", (1...8).contains(snapshot.preset), snapshot.entries.count == 16,
                  snapshot.entries.allSatisfy({ $0.count == SMK25II.padStride }) else { throw Failure("Invalid all-pad backup") }
            for pad in 1...16 { try transport.set(preset: snapshot.preset, pad: pad, color: Array(snapshot.entries[pad-1][5...7])) }
            print("All 16 colors restored and readback verified; no save sent."); return
        }
        guard !FileManager.default.fileExists(atPath:path) else { throw Failure("Backup exists; choose a new path") }
        let preset = Int(global[0])+1
        func entry(_ pad: Int) throws -> [UInt8] {
            let base = try SMK25II.colorAddress(preset:preset,pad:pad)-5
            return try transport.read(type:5,address:base,count:64) + transport.read(type:5,address:base+64,count:10)
        }
        var entries: [[UInt8]] = []
        for pad in 1...16 { entries.append(try entry(pad)) }
        snapshot = AllSnapshot(model:"SMK25II",preset:preset,entries:entries,createdAt:Date())
        let encoder = JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(snapshot).write(to:URL(fileURLWithPath:path),options:[.withoutOverwriting])
        print("All 16 complete pad records backed up. Testing red, off, restore one pad at a time.");fflush(stdout)
        for pad in 1...16 {
            let original = Array(entries[pad-1][5...7])
            do {
                try transport.set(preset:preset,pad:pad,color:[255,0,0]);Thread.sleep(forTimeInterval:1)
                try transport.set(preset:preset,pad:pad,color:[0,0,0]);Thread.sleep(forTimeInterval:1)
                try transport.set(preset:preset,pad:pad,color:original)
                guard try entry(pad) == entries[pad-1] else { throw Failure("Pad \(pad) record changed outside the expected restored RGB values") }
                print("Pad \(pad)/16: red, off, original #\(hex(original)) restored; all 74 configuration bytes unchanged.");fflush(stdout)
            } catch {
                let initialError=error
                do { try transport.set(preset:preset,pad:pad,color:original) }
                catch { throw Failure("Pad \(pad) failed and automatic restoration failed; restore-all from the backup is required: \(error.localizedDescription)") }
                throw initialError
            }
        }
        for pad in 1...16 { guard try entry(pad) == entries[pad-1] else { throw Failure("Final record verification failed for pad \(pad)") } }
        guard try transport.read(type:4,address:0,count:20) == global else { throw Failure("Global settings changed during the test") }
        print("PASS: all 16 pads individually controlled, all 16 full records and global settings restored unchanged. No save command sent.");return
    }
    if command == "restore" || command == "on" {
        guard let path = option("--backup") else { throw Failure("Missing --backup") }
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard saved.model == "SMK25II", saved.color.count == 3 else { throw Failure("Invalid backup") }
        try transport.set(preset: saved.preset, pad: saved.pad, color: saved.color)
        print("Restored preset \(saved.preset) pad \(saved.pad) to #\(hex(saved.color)); device readback verified; no save sent."); return
    }
    let preset = try number("--preset", default: Int(global[0]) + 1), pad = try number("--pad")
    let address = try SMK25II.colorAddress(preset: preset, pad: pad)
    let original = try transport.read(type: 5, address: address, count: 3)
    if command == "read" { try emit(Snapshot(model: "SMK25II", preset: preset, pad: pad, color: original, createdAt: Date())); return }
    guard let path = option("--backup"), path.hasPrefix("/") else { throw Failure("An absolute --backup path is required before modifying a light.") }
    guard !FileManager.default.fileExists(atPath: path) else { throw Failure("Backup already exists; choose a new path so the original is not overwritten.") }
    let target = try command == "off" ? [UInt8(0),0,0] : rgb(option("--hex") ?? "")
    let seconds = try number("--seconds", default: 5)
    guard (1...30).contains(seconds) else { throw Failure("--seconds must be 1...30") }
    let saved = Snapshot(model: "SMK25II", preset: preset, pad: pad, color: original, createdAt: Date())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(saved).write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    if command == "demo" {
        do {
            try transport.set(preset: preset, pad: pad, color: target)
            print("Demo: pad \(pad) #\(hex(original)) -> #\(hex(target)); readback verified. Restoring in \(seconds) seconds."); fflush(stdout)
            Thread.sleep(forTimeInterval: Double(seconds))
        } catch {
            let initialError = error
            do { try transport.set(preset: preset, pad: pad, color: original) }
            catch { throw Failure("Demo failed and restore failed; use the backup to retry: \(error.localizedDescription)") }
            throw initialError
        }
        try transport.set(preset: preset, pad: pad, color: original)
        print("Original color restored and readback verified.")
    } else {
        try transport.set(preset: preset, pad: pad, color: target)
        print("Preset \(preset) pad \(pad) set to #\(hex(target)); readback verified; no save sent. Original backed up.")
    }
}
DispatchQueue.global().async {
    if args == ["serve"] {
        serving = true
        while let line = readLine() {
            autoreleasepool {
                do {
                    args = try JSONDecoder().decode([String].self, from: Data(line.utf8))
                    guard ["state", "batch", "desktop-lights", "desktop-restore"].contains(args.first ?? "") && !args.contains("--help") else { throw Failure("Unsupported console request") }
                    options = [:]; sessionOutput = nil
                    try run()
                    guard let data = sessionOutput else { throw Failure("Missing device response") }
                    let object = try JSONSerialization.jsonObject(with:data)
                    let payload: Any = args[0].hasPrefix("desktop-") ? object : ["state": object]
                    let response = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
                    print(String(data:response,encoding:.utf8)!); fflush(stdout)
                } catch {
                    let response = try! JSONSerialization.data(withJSONObject:["error":error.localizedDescription])
                    print(String(data:response,encoding:.utf8)!); fflush(stdout)
                    if desktopOverlay == nil { sessionTransport = nil }
                }
            }
        }
        if let transport = sessionTransport {
            do { try restoreDesktopLights(using: transport) }
            catch { fputs("Error: \(error.localizedDescription)\n", stderr) }
        }
        sessionTransport = nil
        if sessionLock >= 0 { close(sessionLock) }
        exit(0)
    }
    do { try run(); exit(0) } catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
}
RunLoop.main.run()
