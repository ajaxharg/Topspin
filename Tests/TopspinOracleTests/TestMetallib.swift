import Foundation
import Metal
import TopspinCore

/// Loads only the metallib named by the isolated gate environment.
/// Missing or invalid injection fails closed; it never falls back to default.metallib.
func makeTestMetallib(device: MTLDevice) throws -> Metallib {
    guard let raw = ProcessInfo.processInfo.environment["TOPSPIN_TEST_METALLIB"], !raw.isEmpty else {
        throw TopspinError.metallibUnavailable("TOPSPIN_TEST_METALLIB is required for isolated oracle tests")
    }
    return try Metallib(device: device, metallibURL: URL(fileURLWithPath: raw))
}
