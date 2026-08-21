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
            exit(ProbeDevice.run(frameTarget: frames))
        default:
            print("rcamcli: unknown command '\(command)'")
            usage()
            exit(64)
        }
    }

    static func usage() {
        print("""
        usage: rcamcli <command>
          probe-device [--frames N]   assert "RTSP Camera" exists and animates (default 30 frames)
        """)
    }
}
