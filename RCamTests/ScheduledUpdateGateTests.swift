import Testing

// The mutating calls are bound to locals first: `#expect` can't take a
// mutating call on a `var` inside its expansion.
@Suite("ScheduledUpdateGate")
struct ScheduledUpdateGateTests {
    @Test("Sparkle shows a scheduled update itself while the camera is idle")
    func idleLetsSparkleShow() {
        #expect(ScheduledUpdateGate.sparkleShouldShowScheduledUpdate(cameraInUse: false))
    }

    @Test("a scheduled update found mid-call is taken away from Sparkle")
    func inUseDefers() {
        #expect(!ScheduledUpdateGate.sparkleShouldShowScheduledUpdate(cameraInUse: true))
    }

    @Test("a held update is released on the first idle edge, and only once")
    func releasedOnIdle() {
        var gate = ScheduledUpdateGate()
        let showNow = gate.updateDeferred(cameraInUse: true)
        #expect(!showNow)
        #expect(gate.isHoldingUpdate)

        let stillInUse = gate.cameraInUseChanged(true)
        #expect(!stillInUse)
        let wentIdle = gate.cameraInUseChanged(false)
        #expect(wentIdle)
        #expect(!gate.isHoldingUpdate)

        let idleAgain = gate.cameraInUseChanged(false)
        let nextCall = gate.cameraInUseChanged(true)
        let nextIdle = gate.cameraInUseChanged(false)
        #expect(!idleAgain && !nextCall && !nextIdle)
    }

    // Sparkle asks, then hands the update over; a client can detach in
    // between, and then no later idle edge would ever come to release it.
    @Test("an update handed over after the camera went idle is shown at once")
    func idleByHandover() {
        var gate = ScheduledUpdateGate()
        let showNow = gate.updateDeferred(cameraInUse: false)
        #expect(showNow)
        #expect(!gate.isHoldingUpdate)
        let laterIdle = gate.cameraInUseChanged(false)
        #expect(!laterIdle)
    }

    @Test("idle edges with nothing held do nothing")
    func nothingHeld() {
        var gate = ScheduledUpdateGate()
        let inUse = gate.cameraInUseChanged(true)
        let idle = gate.cameraInUseChanged(false)
        #expect(!inUse && !idle)
    }

    @Test("an update the user already dealt with is not shown again on idle")
    func handledBeforeIdle() {
        var gate = ScheduledUpdateGate()
        _ = gate.updateDeferred(cameraInUse: true)
        gate.updateHandled()
        let idle = gate.cameraInUseChanged(false)
        #expect(!idle)
    }
}
