import Foundation

// Dev/test CLI for RCam. Real commands (probe-device, capture) land in M1/M2.
@main
struct CLIMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print("usage: rcamcli <command>")
            print("commands: (none yet — probe-device arrives in M1, capture in M2)")
            exit(64)
        }
        print("rcamcli: unknown command '\(command)'")
        exit(64)
    }
}
