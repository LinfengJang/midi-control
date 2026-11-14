import XCTest
@testable import PadLightProtocol
final class ProtocolTests: XCTestCase {
    func testNonContiguousSelectionAndInvalidLists() throws {
        XCTAssertEqual(try SMK25II.selectedPads("16, 1,9"),[1,9,16])
        for text in ["", "0", "17", "1,1", "1,", ",2", "x", "1,2.5"] { XCTAssertThrowsError(try SMK25II.selectedPads(text)) }
        XCTAssertEqual(try SMK25II.selectedPads((1...16).map(String.init).joined(separator:",")),Array(1...16))
    }
    func testKnownPadFiveRedPacket() throws {
        // Independent wire fixture: raw 00 59 22 0B0000 05 AB010000 030000 FF0000 4C.
        let expected: [UInt8] = [0xF0,0x00,0x32,0x09,0x59,0,0,0x40,2,0x2B,3,0,0,0x30,0,0,0,0x7F,1,0,0x60,4,0xF7]
        XCTAssertEqual(try SMK25II.color(preset: 1, pad: 5, rgb: [255,0,0]), expected)
    }
    func testAddressBoundariesAndModelLayout() throws {
        XCTAssertEqual(try SMK25II.colorAddress(preset: 1, pad: 1), 0x83)
        XCTAssertEqual(try SMK25II.colorAddress(preset: 1, pad: 5), 0x1AB)
        XCTAssertEqual(try SMK25II.colorAddress(preset: 8, pad: 16), 0x4951)
        for preset in [0,9,-1] { XCTAssertThrowsError(try SMK25II.colorAddress(preset: preset, pad: 1)) }
        for pad in [0,17,-1] { XCTAssertThrowsError(try SMK25II.colorAddress(preset: 1, pad: pad)) }
        XCTAssertThrowsError(try SMK25II.color(preset: 1, pad: 1, rgb: []))
    }
    func testAllByteValuesSurvivePacking() throws {
        for length in 0...256 {
            let input = (0..<length).map { UInt8(($0 * 73 + length) & 255) }
            XCTAssertEqual(try SMK25II.decode7(SMK25II.encode7(input)), input)
        }
    }
    func testRejectsMalformedAndCorruptedFrames() throws {
        let valid = SMK25II.frame(command: 0, body: [0])
        for length in 0..<valid.count { XCTAssertThrowsError(try SMK25II.parse(Array(valid.prefix(length)))) }
        XCTAssertThrowsError(try SMK25II.decode7([128]))
        XCTAssertThrowsError(try SMK25II.decode7([0]))
        let corruptRaw: [UInt8] = [0,0x59,0,1,0,0,0,0] // Incorrect checksum, must be FF.
        XCTAssertThrowsError(try SMK25II.parse([0xF0] + SMK25II.encode7(corruptRaw) + [0xF7]))
    }
    func testReadReplyCorrelation() throws {
        let body: [UInt8] = [5,0xAB,1,0,0,3,0,0,0,170,127]
        let reply = SMK25II.frame(command: 0x23, body: body)
        XCTAssertEqual(try SMK25II.readData(reply, type: 5, address: 0x1AB, count: 3), [0,170,127])
        XCTAssertThrowsError(try SMK25II.readData(reply, type: 4, address: 0x1AB, count: 3))
        XCTAssertThrowsError(try SMK25II.readData(reply, type: 5, address: 0x1AC, count: 3))
        XCTAssertThrowsError(try SMK25II.readData(reply, type: 5, address: 0x1AB, count: 4))
    }
    func testOnlyThreeColorBytesWrittenWithoutCommit() throws {
        for preset in 1...8 { for pad in 1...16 {
            let message = try SMK25II.parse(SMK25II.color(preset: preset, pad: pad, rgb: [0,0,0]))
            XCTAssertEqual(message.command, 0x22); XCTAssertEqual(message.body[0], 5)
            XCTAssertEqual(message.body.count, 11)
            XCTAssertEqual(Array(message.body[5...7]), [3,0,0])
        } }
    }
}
