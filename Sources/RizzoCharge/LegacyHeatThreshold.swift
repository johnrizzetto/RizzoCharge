import Foundation

// Retained for the prototype tests. No live sensor, alert or control calls this.
enum HeatState: Equatable { case unknown, normal, hot }
func heatState(temperature: Double?, threshold: Double) -> HeatState {
    guard let temperature, temperature.isFinite, (-10...100).contains(temperature) else { return .unknown }
    return temperature >= threshold ? .hot : .normal
}
