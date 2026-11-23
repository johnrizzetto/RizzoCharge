import CoreGraphics
import XCTest
@testable import RizzoCharge

final class BatteryIconTests: XCTestCase {
    func testFillUsesTheReportedPercentageAcrossTheEntireRange() {
        let interior = CGRect(x: 2, y: 7, width: 15, height: 8)
        for percent in 0...100 {
            let fill = batteryFillRect(in: interior, percent: percent)
            XCTAssertEqual(fill.origin, interior.origin)
            XCTAssertEqual(fill.height, interior.height)
            XCTAssertEqual(fill.width / interior.width, CGFloat(percent) / 100, accuracy: 0.000001)
        }
    }

    func testUnavailableChargeLeavesTheIconEmpty() {
        let interior = CGRect(x: 2, y: 7, width: 15, height: 8)
        XCTAssertTrue(batteryFillRect(in: interior, percent: nil).isEmpty)
    }
}
