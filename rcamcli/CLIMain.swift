import Foundation

// Dev/test CLI for RCam. `capture` (RTSP decode harness) lands in M2.
@main
struct CLIMain {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            usage()
            exit(64)
        }
        args.removeFirst()

        switch command {
        case "probe-device":
            var frames = 30
            if let index = args.firstIndex(of: "--frames"), index + 1 < args.count,
               let value = Int(args[index + 1]) {
                frames = value
            }
            exit(ProbeDevice.run(frameTarget: frames, dumpLuma: args.contains("--dump-luma")))
        case "capture":
            guard let url = args.first else {
                usage()
                exit(64)
            }
            args.removeFirst()
            var seconds = 5
            var outDir: String?
            if let index = args.firstIndex(of: "--seconds"), index + 1 < args.count,
               let value = Int(args[index + 1]) {
                seconds = value
            }
            if let index = args.firstIndex(of: "--out"), index + 1 < args.count {
                outDir = args[index + 1]
            }
            exit(CaptureCommand.run(url: url, seconds: seconds, outDir: outDir))
        case "select-camera":
            guard let key = args.first else {
                usage()
                exit(64)
            }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.paulstraw.rcam.selectCamera"),
                object: key,
                userInfo: nil,
                deliverImmediately: true
            )
            print("posted selectCamera(\(key))")
            exit(0)
        case "cmio-props":
            let uid = "7E5F9C1A-3B2D-4E6F-8A90-C1D2E3F4A5B6"
            guard let device = CMIOHelpers.findDevice(uid: uid) else {
                print("device NOT found (uid \(uid))")
                exit(1)
            }
            print("device found: id \(device)")
            print("rwch (watched) = \(CMIOHelpers.readCustomString(device: device, code: "rwch") ?? "<no property>")")
            print("rnam (name)    = \(CMIOHelpers.readCustomString(device: device, code: "rnam") ?? "<no property>")")
            let wrote = CMIOHelpers.writeCustomString(device: device, code: "rnam", value: "cli-test")
            print("rnam write     = \(wrote ? "ok" : "FAILED")")
            print("rnam readback  = \(CMIOHelpers.readCustomString(device: device, code: "rnam") ?? "<no property>")")
            exit(0)
        default:
            print("rcamcli: unknown command '\(command)'")
            usage()
            exit(64)
        }
    }

    static func usage() {
        print("""
        usage: rcamcli <command>
          probe-device [--frames N]                       assert "RTSP Camera" exists and animates (default 30)
          capture <rtsp-url> [--seconds N] [--out <dir>]  decode RTSP, save every 30th frame as PNG
          select-camera <name-or-id>                      switch RCam's active camera (via distributed notification)
          cmio-props                                      dump the virtual device's custom properties
        """)
    }
}
