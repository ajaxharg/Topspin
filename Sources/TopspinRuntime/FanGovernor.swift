// FanGovernor.swift — holding the machine's fan at a chosen speed by resting the scheduler.
//
// The fan's speed is read from the SMC (no privilege is needed to read it), and the share of
// the time the scheduler works (BatchScheduler.workPercent) is moved to keep it at the limit
// the settings give. The fan follows the temperature and the temperature follows the power by
// tens of seconds, so the share is moved a little at each reading and not set from one.

import Foundation
import IOKit

/// The fans' speed, from the SMC.
public final class FanSensor: @unchecked Sendable {
    public static let shared = FanSensor()

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    /// Each fan's full speed in rpm, read once.
    private var fullSpeeds: [Float] = []

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return }
        let count = read("FNum").flatMap { $0.first }.map(Int.init) ?? 0
        fullSpeeds = (0..<min(count, 10)).map { float("F\($0)Mx") ?? 0 }
        if let full = fullSpeeds.first, full > 0, let slowest = float("F0Mn") { slowestPercent = Double(slowest / full) * 100 }
    }

    /// The fastest fan's speed as a percentage of its full speed: 0 is stopped. Nil on a
    /// machine with no fan, or whose SMC does not give the speed.
    public func percent() -> Double? {
        lock.lock(); defer { lock.unlock() }
        var highest: Double?
        for (fan, full) in fullSpeeds.enumerated() where full > 0 {
            guard let speed = float("F\(fan)Ac") else { continue }
            highest = max(highest ?? 0, min(100, Double(speed / full) * 100))
        }
        return highest
    }

    /// The slowest a fan runs when it runs at all, as a percentage of its full speed.
    public private(set) var slowestPercent: Double?

    /// The SMC's call structure (SMCParamStruct in Apple's PowerManagement sources): 80 bytes.
    private struct Parameters {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0, dataType: UInt32 = 0
        var attributes: UInt8 = 0
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    private static let readKeyInfo: UInt8 = 9, readBytes: UInt8 = 5

    private func call(_ input: Parameters) -> Parameters? {
        var input = input, output = Parameters()
        var size = MemoryLayout<Parameters>.stride
        guard IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Parameters>.stride, &output, &size) == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    /// The bytes of a key's value, and its type.
    private func read(_ key: String) -> [UInt8]? { typed(key)?.bytes }

    private func typed(_ key: String) -> (bytes: [UInt8], type: UInt32)? {
        guard connection != 0 else { return nil }
        var input = Parameters()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.command = Self.readKeyInfo
        guard let info = call(input), info.dataSize <= 32 else { return nil }
        input.dataSize = info.dataSize
        input.command = Self.readBytes
        guard let value = call(input) else { return nil }
        return (withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(info.dataSize))) }, info.dataType)
    }

    /// A speed in rpm: a float on Apple silicon, 14.2 fixed point (`fpe2`) on older machines.
    private func float(_ key: String) -> Float? {
        guard let value = typed(key) else { return nil }
        if value.type == 0x666c_7420, value.bytes.count == 4 { return value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) } }
        if value.type == 0x6670_6532, value.bytes.count == 2 { return Float(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4 }
        return nil
    }
}

/// The share of the time to work, moved at each reading of the fan towards what holds it at
/// the limit.
///
/// The fan follows the heat in the machine's body, which follows the power drawn by about a
/// minute: measured on an M5 Pro, with the work cut to a twentieth the fan took 80 s to come
/// down from 52 % to its slowest. So the error alone is a poor guide (a share cut until the fan
/// is back under its limit has been cut far too long), and the share also follows the fan's
/// movement: it gives way as the fan speeds up, before the limit is reached, and comes back as
/// the fan slows, while it is still over. That is a PI controller in its velocity form, with
/// the gains the lag asks for.
///
/// A fan cannot run slower than its slowest speed (about 30 % of full on a MacBook Pro), so
/// under a limit below that it is to stay off, and gives no measure of how near it is to
/// coming on. There the share is found as a sender finds a link's capacity: the fan coming on
/// says the share was too high, the work all but stops until it is off again, and resumes at
/// three quarters of that share, a ceiling which then rises slowly.
public struct FanGovernor: Sendable {
    /// Seconds between readings.
    public static let interval = 2.0
    /// The least share: work goes on, slowly, whatever the fan does.
    public static let floor = 5.0
    /// Points of share for a point of fan speed, and the seconds over which a standing error
    /// moves the share as far again.
    static let gain = 1.2, integralSeconds = 60.0
    /// With the fan to stay off: the share kept of the one that brought it on, and the points
    /// a minute the ceiling rises while it stays off.
    static let backOff = 0.75, probePerMinute = 1.5

    public private(set) var share = 100.0
    private var lastError: Double?
    private var ceiling = 100.0
    private var running = false

    public init() {}

    /// Take a reading: the fan's speed, its limit and its slowest running speed, in percent of
    /// full speed, and the seconds since the reading before.
    public mutating func read(fan: Double, limit: Double, slowest: Double, seconds: Double) {
        if limit < slowest {
            lastError = nil
            if fan > 0 {
                if !running { ceiling = max(Self.floor, Self.backOff * share) }
                share = Self.floor
            } else {
                ceiling = min(100, ceiling + Self.probePerMinute * seconds / 60)
                share = min(ceiling, share + seconds)
            }
            running = fan > 0
        } else {
            ceiling = 100; running = false
            // A stopped fan is under any limit it can run at, and no further under than its
            // slowest speed is: its starting is not a movement to give way to.
            let error = limit - max(fan, slowest)
            var change = Self.gain * error * min(seconds, 10) / Self.integralSeconds
            if let lastError { change += Self.gain * (error - lastError) }
            if fan == 0 { change = max(change, seconds / 2) }
            lastError = error
            share += change
        }
        share = min(100, max(Self.floor, share))
    }
}
