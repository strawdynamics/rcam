import Foundation

/// The virtual camera's fixed output format. Every frame RCam pushes into the
/// sink is scaled to these dimensions, whatever the camera's native size.
///
/// The extension declares the same numbers as `kOutputWidth` / `kOutputHeight`
/// / `kFrameRate` in `RCamExtension/Provider.swift`; it deliberately keeps its
/// own copy so that changing the device format bumps the extension's build
/// hash (see `scripts/build.sh`). Keep the two in sync.
public enum OutputFormat {
    public static let width = 1280
    public static let height = 720
    public static let frameRate = 30

    /// "1280 × 720" — uses a real multiplication sign, not an "x".
    public static var sizeDescription: String { "\(width) × \(height)" }
}
