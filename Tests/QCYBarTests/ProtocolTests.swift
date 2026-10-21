import XCTest
@testable import QCYBar

final class ProtocolTests: XCTestCase {
    func testQcyFrames() {
        // qcyx frame-format.md: ANC "Normal"
        XCTAssertEqual(QCYFrame.encode([TLV(.anc, AncSetting.normal.bytes)]), [0xFF, 0x05, 0x17, 0x03, 0x02, 0x00, 0x00])
        XCTAssertEqual(QCYFrame.encode([.request(.multiEq2)]), [0xFF, 3, 0xFE, 1, 0x22])
        XCTAssertEqual(QCYFrame.encode([TLV(.powerOffTimer, le(UInt16(30)) + [0, 0])]), [0xFF, 6, 0x14, 4, 30, 0, 0, 0])
        XCTAssertEqual(QCYFrame.encode([TLV(.resetDefault)]), [0xFF, 2, 1, 0])
    }

    func testSettingsDump() {
        // Orphion PROTOCOL.md §4
        let dump: [UInt8] = [0xff, 0x30, 0x2c, 0x04, 0x00, 0x01, 0x01, 0x01, 0x08, 0x03, 0x46, 0x46, 0x0f, 0x09, 0x01, 0x02,
                             0x17, 0x03, 0x01, 0x05, 0x00, 0x10, 0x01, 0x00, 0x16, 0x01, 0x32, 0x04, 0x01, 0x02, 0x23, 0x01,
                             0x00, 0x24, 0x01, 0x01, 0x1f, 0x02, 0x05, 0x00, 0x1d, 0x02, 0x08, 0x0f, 0x19, 0x04, 0x57, 0x51,
                             0x30, 0x30]
        let tlvs = QCYFrame.decode(dump)
        XCTAssertEqual(tlvs.count, 12)
        XCTAssertEqual(tlvs.first { $0.id == 0x17 }?.payload, [1, 5, 0])
        XCTAssertEqual(tlvs.first { $0.id == 0x16 }?.payload, [50])
    }

    func testRcsp() {
        var r = RCSP()
        let hello = r.hello(unixTime: 0)
        XCTAssertEqual(hello[0], [0xFE, 0xDC, 0xBA, 0xC0, 0x03, 0x00, 0x06, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xEF])
        // Orphion jieli.rs test: ANC (1,1,2) with sn 3
        var r2 = RCSP()
        for _ in 0..<3 { _ = r2.custom(.request(.battery)) }
        XCTAssertEqual(r2.custom(TLV(.anc, [1, 1, 2])), [0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0x00, 0x06, 0x03, 0x17, 0x03, 0x01, 0x01, 0x02, 0xEF])
        // Response split across two notifications.
        let resp: [UInt8] = [0xFE, 0xDC, 0xBA, 0x00, 0xFF, 0x00, 0x07, 0x00, 0x02, 0x2F, 0x03, 0x5A, 0x5C, 0x64, 0xEF]
        XCTAssertTrue(r.push(Array(resp[0..<6])).isEmpty)
        let frames = r.push(Array(resp[6...]))
        XCTAssertEqual(frames.count, 1)
        let tlvs = QCYFrame.decodeEntries(frames[0].params)
        XCTAssertEqual(tlvs, [TLV(.battery, [0x5A, 0x5C, 0x64])])
        let b = Battery(tlvs[0].payload)
        XCTAssertEqual(b?.left?.percent, 90)
        XCTAssertEqual(b?.caseBox?.percent, 100)
    }

    func testEqPayload() {
        let p = EqPreset.a30[0].payload(padTo: 20)
        XCTAssertEqual(p.count, 3 + 20 * 7)
        XCTAssertEqual(p[0], 1)
        XCTAssertEqual(Array(p[1...2]), le(Int16(-1500)))
        XCTAssertEqual(Array(p[3...9]), le(UInt16(20)) + le(Int16(-1100)) + le(UInt16(80)) + [2])
        XCTAssertEqual(p.last, 255)
        XCTAssertEqual(EqPreset.custom(gains: Array(repeating: 0, count: 10)).masterGain, -0.5, accuracy: 0.01)
        XCTAssertLessThan(EqPreset.custom(gains: [8, 8, 8, 0, 0, 0, 0, 0, 0, 0]).masterGain, -4)
    }
}
