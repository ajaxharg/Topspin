import Testing
@testable import TopspinRuntime

@Suite("Fan limit")
struct FanGovernorTests {
    /// A machine for the governor to hold: the heat follows the share worked with a time
    /// constant of a minute, and the fan runs from its slowest speed once the heat passes a
    /// third. Returns the fan's speed and the share at each two-second reading.
    private static func run(limit: Double, minutes: Double) -> [(fan: Double, share: Double)] {
        var governor = FanGovernor(), heat = 0.0, readings: [(fan: Double, share: Double)] = []
        for _ in 0..<Int(minutes * 30) {
            heat += (governor.share - heat) * 2 / 60
            let fan = heat < 33 ? 0 : 30 + (heat - 33) * 70 / 67
            governor.read(fan: fan, limit: limit, slowest: 30, seconds: 2)
            readings.append((fan, governor.share))
        }
        return readings
    }

    @Test("the fan settles at its limit, without the share being thrown to the floor on the way")
    func settles() {
        let readings = Self.run(limit: 50, minutes: 20)
        #expect(readings.suffix(60).allSatisfy { abs($0.fan - 50) < 2 })
        #expect(readings.map(\.fan).max()! < 60)
        #expect(readings.map(\.share).min()! > 25)
    }

    @Test("the share gives way while the fan is speeding up under its limit, and comes back while it slows over it")
    func anticipates() {
        var governor = FanGovernor()
        for fan in stride(from: 40.0, to: 49, by: 2) { governor.read(fan: fan, limit: 50, slowest: 30, seconds: 2) }
        #expect(governor.share < 100)
        for _ in 0..<20 { governor.read(fan: 70, limit: 50, slowest: 30, seconds: 2) }
        let low = governor.share
        for fan in stride(from: 68.0, to: 52, by: -2) { governor.read(fan: fan, limit: 50, slowest: 30, seconds: 2) }
        #expect(governor.share > low)
    }

    @Test("a limit under the fan's slowest speed keeps it off nearly all the time, at a share the machine bears")
    func keptOff() {
        let readings = Self.run(limit: 0, minutes: 60).suffix(900)
        #expect(Double(readings.filter { $0.fan > 0 }.count) / 900 < 0.15)
        #expect(readings.map(\.share).reduce(0, +) / 900 > 15)
    }

    @Test("the share stays between the floor and all of the time")
    func bounded() {
        var governor = FanGovernor()
        for _ in 0..<500 { governor.read(fan: 100, limit: 30, slowest: 30, seconds: 2) }
        #expect(governor.share == FanGovernor.floor)
        for _ in 0..<500 { governor.read(fan: 0, limit: 60, slowest: 30, seconds: 2) }
        #expect(governor.share == 100)
    }

    @Test("the fan's speed, where this machine gives it, is a percentage")
    func sensor() {
        if let percent = FanSensor.shared.percent() { #expect((0...100).contains(percent)) }
    }
}
