import XCTest
import IOKit.ps
@testable import RizzoCharge

final class TelemetryTests: XCTestCase {
    func testUnknownAndContradictoryState() {
        XCTAssertEqual(PowerState(ac: nil, charging: false), .unknown)
        XCTAssertEqual(PowerState(ac: true, charging: nil), .unknown)
        XCTAssertEqual(PowerState(ac: false, charging: true), .unknown)
    }
    func testKnownStates() {
        XCTAssertEqual(PowerState(ac: true, charging: true), .charging)
        XCTAssertEqual(PowerState(ac: true, charging: false), .connected)
        XCTAssertEqual(PowerState(ac: false, charging: false), .battery)
    }
    func testCapacityValidationPreservesZero() {
        XCTAssertEqual(chargePercent(current: 0, maximum: 100), 0)
        XCTAssertEqual(chargePercent(current: 1, maximum: 3), 33)
        XCTAssertNil(chargePercent(current: 105, maximum: 100))
        XCTAssertNil(chargePercent(current: nil, maximum: 100))
        XCTAssertNil(chargePercent(current: .infinity, maximum: 100))
        XCTAssertNil(chargePercent(current: 0, maximum: 0))
    }
    func testStaleAndWakeInvalidationHideSample() {
        let now = Date()
        let sample = BatterySample(at: now, state: .charging, percent: 79)
        XCTAssertEqual(sample.fresh(at: now.addingTimeInterval(5))?.percent, 79)
        XCTAssertNil(sample.fresh(at: now.addingTimeInterval(16)))
        XCTAssertNil(sample.fresh(at: now.addingTimeInterval(-1)))
        XCTAssertNil(sample.fresh(at: now, suspended: true))
    }
    func testSignedCurrentAndMissingValues() {
        XCTAssertEqual(signedMilliamps(NSNumber(value: UInt64.max - 999)), -1000)
        XCTAssertEqual(signedMilliamps(NSNumber(value: Int32(-1000))), -1000)
        XCTAssertEqual(signedMilliamps(NSNumber(value: 0)), 0)
        XCTAssertNil(signedMilliamps(nil))
        XCTAssertNil(signedMilliamps(NSNumber(value: 1_000_000)))
        XCTAssertNil(signedMilliamps(NSNumber(value: true)))
        XCTAssertEqual(batteryWatts(millivolts: 12_500, milliamps: -1000), -12.5)
        XCTAssertEqual(batteryWatts(millivolts: 12_500, milliamps: 0), 0)
        XCTAssertNil(batteryWatts(millivolts: 12_500, milliamps: nil))
    }
    func testContradictoryPackPowerIsNotPresented() {
        XCTAssertNil(consistentBatteryWatts(8, state: .battery))
        XCTAssertNil(consistentBatteryWatts(-8, state: .charging))
        XCTAssertNil(consistentBatteryWatts(8, state: .connected))
        XCTAssertNil(consistentBatteryWatts(-8, state: .unknown))
        XCTAssertEqual(consistentBatteryWatts(-8, state: .connected), -8)
    }
}

extension TelemetryTests {
    func testPowerEstimateWithChargeHeldAndWhileCharging() {
        let held = ACPowerEstimate(state: .connected, inputMilliwatts: 11_676, loadMilliwatts: 11_676,
                                   inputMillivolts: 20_423, inputMilliamps: 572, packWatts: 0)
        XCTAssertEqual(held?.inputWatts, 11.676)
        XCTAssertEqual(held?.loadWatts, 11.676)
        let charging = ACPowerEstimate(state: .charging, inputMilliwatts: 39_451, loadMilliwatts: 11_559,
                                       inputMillivolts: 19_962, inputMilliamps: 1_976, packWatts: 27.894)
        XCTAssertEqual(charging?.inputWatts, 39.451)
        XCTAssertEqual(charging?.loadWatts, 11.559)
    }

    func testPowerEstimateRejectsMissingOrContradictoryData() {
        func estimate(_ state: PowerState = .connected, input: Double? = 12_000, load: Double? = 12_000,
                      current: Double? = 600, pack: Double? = 0) -> ACPowerEstimate? {
            ACPowerEstimate(state: state, inputMilliwatts: input, loadMilliwatts: load,
                            inputMillivolts: 20_000, inputMilliamps: current, packWatts: pack)
        }
        XCTAssertNotNil(estimate())
        XCTAssertNil(estimate(.battery))
        XCTAssertNil(estimate(.unknown))
        XCTAssertNil(estimate(input: nil))
        XCTAssertNil(estimate(input: .infinity))
        XCTAssertNil(estimate(load: nil))
        XCTAssertNil(estimate(load: 0))
        XCTAssertNil(estimate(current: 100))
        XCTAssertNil(estimate(pack: nil))
        XCTAssertNil(estimate(.charging, pack: 10))
    }
}

extension TelemetryTests {
    func testReportedChargingWattsValidateUnitsAndAgreement() {
        XCTAssertEqual(reportedChargingWatts(milliwatts: 40_514, calculated: 40.515, state: .charging), 40.514)
        XCTAssertEqual(reportedChargingWatts(milliwatts: 40_514, calculated: nil, state: .charging), 40.514)
        XCTAssertNil(reportedChargingWatts(milliwatts: nil, calculated: 40.515, state: .charging))
        XCTAssertNil(reportedChargingWatts(milliwatts: 0, calculated: 40.515, state: .charging))
        XCTAssertNil(reportedChargingWatts(milliwatts: 40_514, calculated: 5, state: .charging))
        XCTAssertNil(reportedChargingWatts(milliwatts: 40_514, calculated: nil, state: .connected))
    }
}

extension TelemetryTests {
    func testTimeEstimatesKeepValidMinutesAndRejectUnknownValues() {
        XCTAssertEqual(timeEstimateMinutes(112), 112)
        XCTAssertEqual(timeEstimateMinutes(0), 0)
        XCTAssertNil(timeEstimateMinutes(nil))
        XCTAssertNil(timeEstimateMinutes(-1))
        XCTAssertNil(timeEstimateMinutes(65_535))
        XCTAssertNil(timeEstimateMinutes(4.5))
        XCTAssertNil(timeEstimateMinutes(true))
    }

    func testTimeTo80UsesRemainingShareOfFullChargeEstimate() {
        var sample = BatterySample(at: .now, state: .charging, percent: 32, minutesToFull: 112)
        XCTAssertEqual(sample.minutesTo80Percent, 80)
        sample.minutesToFull = nil
        XCTAssertNil(sample.minutesTo80Percent)
        sample.percent = 80
        XCTAssertEqual(sample.minutesTo80Percent, 0)
        sample.state = .battery
        XCTAssertNil(sample.minutesTo80Percent)
    }
}
