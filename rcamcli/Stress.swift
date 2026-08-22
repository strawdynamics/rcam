import Foundation

/// `rcamcli stress <rtsp-url> [--cycles N] [--hold SECONDS]`: hammer
/// RTSPSource.start()/stop() to shake out teardown races (finding 4). Each
/// cycle uses a fresh source, matching how RCamController actually drives
/// them; `--reuse` restarts one source instead, exercising the abandoned-thread
/// bookkeeping in start().
enum StressCommand {
    static func run(url: String, cycles: Int, hold: Double, reuse: Bool) -> Int32 {
        let shared = reuse ? RTSPSource(url: url) : nil
        var framesSeen = 0
        var failures = [String]()
        let lock = NSLock()

        for cycle in 1...cycles {
            let source = shared ?? RTSPSource(url: url)
            source.onFrame = { _, _ in
                lock.lock(); framesSeen += 1; lock.unlock()
            }
            source.onStateChange = { state in
                if case .failed(let message) = state {
                    lock.lock(); failures.append("cycle \(cycle): \(message)"); lock.unlock()
                }
            }

            let started = RTSPSource.now()
            source.start()
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
            source.stop()
            let elapsed = RTSPSource.now() - started

            source.onFrame = nil
            source.onStateChange = nil

            if elapsed > RTSPSource.stopWaitSeconds + hold {
                lock.lock()
                failures.append(String(format: "cycle %d: stop() took %.1fs", cycle, elapsed))
                lock.unlock()
            }
            if cycle % 10 == 0 {
                lock.lock()
                let seen = framesSeen
                lock.unlock()
                print(String(format: "cycle %d/%d — %d frames so far", cycle, cycles, seen))
            }
        }

        lock.lock()
        let seen = framesSeen
        let problems = failures
        lock.unlock()

        print("completed \(cycles) start/stop cycles, \(seen) frames delivered")
        guard problems.isEmpty else {
            for problem in problems.prefix(10) { fputs("FAIL: \(problem)\n", stderr) }
            if problems.count > 10 { fputs("FAIL: … and \(problems.count - 10) more\n", stderr) }
            return 1
        }
        guard seen > 0 else {
            fputs("FAIL: no frames delivered across \(cycles) cycles\n", stderr)
            return 1
        }
        return 0
    }
}
