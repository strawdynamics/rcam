import Foundation
import CoreVideo

/// FROZEN as of M2 — everything downstream (extension wiring, UI, switching)
/// depends on this shape. Do not change it.
public enum FrameSourceState: Equatable {
    case idle
    case connecting
    case streaming
    case failed(String)
}

public protocol FrameSource: AnyObject {
    /// Delivers 1920x1080 NV12 pixel buffers plus their arrival time
    /// (host uptime seconds). Called on an internal queue/thread.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)? { get set }
    var onStateChange: ((FrameSourceState) -> Void)? { get set }

    func start()
    func stop()
}
