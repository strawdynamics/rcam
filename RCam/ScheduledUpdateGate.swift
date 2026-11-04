import Foundation

/// Decides when a *scheduled* Sparkle update may be put in front of the user.
///
/// RCam is a virtual camera: an update alert landing mid-call is at best a
/// distraction and at worst gets "Install and Relaunch" clicked, which quits
/// the app feeding the call. So an update Sparkle finds on its own while a
/// client has the camera open is held back and shown once the camera goes
/// idle. User-initiated checks never come through here — Sparkle always shows
/// those itself, which is what the user asked for.
///
/// Foundation-only, so the decisions are unit-testable without Sparkle. The
/// `Updater` maps Sparkle's gentle-reminder delegate calls onto it.
struct ScheduledUpdateGate: Equatable {
    /// An update was found while the camera was in use and is waiting for it
    /// to go idle.
    private(set) var isHoldingUpdate = false

    /// Answer for `standardUserDriverShouldHandleShowingScheduledUpdate`:
    /// `true` lets Sparkle show it now, `false` means we will. Sparkle requires
    /// this to be side-effect free, hence `static`; the hold is recorded in
    /// `updateDeferred` once Sparkle confirms it.
    static func sparkleShouldShowScheduledUpdate(cameraInUse: Bool) -> Bool {
        !cameraInUse
    }

    /// Sparkle has handed us a scheduled update to show. Returns `true` if it
    /// should be shown right away: the camera can have gone idle between
    /// Sparkle asking and handing it over, and no later idle edge would come
    /// to release it.
    mutating func updateDeferred(cameraInUse: Bool) -> Bool {
        isHoldingUpdate = cameraInUse
        return !cameraInUse
    }

    /// The camera's in-use state changed. Returns `true` exactly once, on the
    /// first idle edge after an update was held: the caller brings it forward.
    mutating func cameraInUseChanged(_ inUse: Bool) -> Bool {
        guard isHoldingUpdate, !inUse else { return false }
        isHoldingUpdate = false
        return true
    }

    /// The user has seen the update some other way (a manual "Check for
    /// Updates…" brings the held one forward) or the session ended. Nothing is
    /// left to release.
    mutating func updateHandled() {
        isHoldingUpdate = false
    }
}
