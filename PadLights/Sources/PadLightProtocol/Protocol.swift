import Foundation
public enum ProtocolError: Error { case invalidRange, invalidFrame, invalidChecksum, unexpectedReply }
public enum SMK25II {
    public static func selectedPads(_ text: String) throws -> [Int] {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.count == parts.count, values.allSatisfy({ (1...16).contains($0) }), Set(values).count == values.count else { throw ProtocolError.invalidRange }
        return values.sorted()
    }
    public static let presetStride = 0x9C8
    public static let padBase = 0x7E
    public static let padStride = 0x4A
    public static func colorAddress(preset: Int, pad: Int) throws -> Int {
        guard (1...8).contains(preset), (1...16).contains(pad) else { throw ProtocolError.invalidRange }
        return (preset - 1) * presetStride + padBase + (pad - 1) * padStride + 5
    }
    public static func encode7(_ bytes: [UInt8]) -> [UInt8] {
        var accumulator: UInt32 = 0, bits = 0, result: [UInt8] = []
        for byte in bytes {
            accumulator |= UInt32(byte) << bits; bits += 8
            while bits >= 7 { result.append(UInt8(accumulator & 127)); accumulator >>= 7; bits -= 7 }
        }
        if bits > 0 { result.append(UInt8(accumulator & 127)) }
        return result
    }
    public static func decode7(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.allSatisfy({ $0 < 128 }) else { throw ProtocolError.invalidFrame }
        var accumulator: UInt32 = 0, bits = 0, result: [UInt8] = []
        for byte in bytes {
            accumulator |= UInt32(byte) << bits; bits += 7
            while bits >= 8 { result.append(UInt8(accumulator & 255)); accumulator >>= 8; bits -= 8 }
        }
        guard bits < 7, accumulator == 0, encode7(result) == bytes else { throw ProtocolError.invalidFrame }
        return result
    }
    public static func littleEndian(_ value: Int, bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> (8 * $0)) & 255) } }
    public static func integer(_ bytes: ArraySlice<UInt8>) -> Int { bytes.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) } }
    public static func frame(command: UInt8, body: [UInt8]) -> [UInt8] {
        let raw = [UInt8(0), 0x59, command] + littleEndian(body.count, bytes: 3) + body + [~body.reduce(UInt8(0), &+)]
        return [0xF0] + encode7(raw) + [0xF7]
    }
    public static func parse(_ frame: [UInt8]) throws -> (command: UInt8, body: [UInt8]) {
        guard frame.first == 0xF0, frame.last == 0xF7, frame.count >= 10 else { throw ProtocolError.invalidFrame }
        let raw = try decode7(Array(frame.dropFirst().dropLast()))
        guard raw.count >= 7, raw[0...1] == [0, 0x59], integer(raw[3...5]) == raw.count - 7 else { throw ProtocolError.invalidFrame }
        let body = Array(raw[6..<raw.count-1])
        guard raw.last! == ~body.reduce(UInt8(0), &+) else { throw ProtocolError.invalidChecksum }
        return (raw[2], body)
    }
    public static func read(type: UInt8, address: Int, count: Int) throws -> [UInt8] {
        guard [4,5].contains(type), address >= 0, (1...64).contains(count) else { throw ProtocolError.invalidRange }
        return frame(command: 0x23, body: [type] + littleEndian(address, bytes: 4) + littleEndian(count, bytes: 3))
    }
    // Only exposes a three-byte RGB write. No arbitrary writes, saves, erase or firmware commands.
    public static func color(preset: Int, pad: Int, rgb: [UInt8]) throws -> [UInt8] {
        guard rgb.count == 3 else { throw ProtocolError.invalidRange }
        let address = try colorAddress(preset: preset, pad: pad)
        return frame(command: 0x22, body: [5] + littleEndian(address, bytes: 4) + [3,0,0] + rgb)
    }
    public static func readData(_ frame: [UInt8], type: UInt8, address: Int, count: Int) throws -> [UInt8] {
        let parsed = try parse(frame), body = parsed.body
        guard parsed.command == 0x23, body.count == count + 8, body[0] == type, integer(body[1...4]) == address, integer(body[5...7]) == count else { throw ProtocolError.unexpectedReply }
        return Array(body.dropFirst(8))
    }
}
