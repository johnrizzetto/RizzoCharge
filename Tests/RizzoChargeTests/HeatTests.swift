import XCTest
@testable import RizzoCharge
final class HeatTests: XCTestCase {
    func testHeatThreshold() { XCTAssertEqual(heatState(temperature: 35, threshold: 35), .hot); XCTAssertEqual(heatState(temperature: 34, threshold: 35), .normal) }
    func testUnavailableTemperature() { XCTAssertEqual(heatState(temperature: nil, threshold: 35), .unknown); XCTAssertEqual(heatState(temperature: 400, threshold: 35), .unknown) }
}
