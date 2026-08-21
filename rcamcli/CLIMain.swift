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
        """)
    }
}
