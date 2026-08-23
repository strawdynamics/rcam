import SwiftUI

/// Third-party attribution. FFmpeg is RCam's only non-system dependency, so
/// this is a one-entry list rather than a generated manifest.
///
/// LGPL-2.1 §6 obliges a work that links the library to give prominent notice,
/// to supply a copy of the license, and to make the corresponding source
/// available. The first two happen in `AcknowledgementsSheet`; the third is the
/// upstream tarball — FFmpeg is vendored unmodified — plus the published build
/// recipe. §6 also wants the user to be able to relink against their own build
/// of the library, which a signed, statically linked App Store bundle cannot
/// offer; publishing the exact recipe is what stands in for it.
enum Acknowledgements {
    /// Must match `FFMPEG_VERSION` in `scripts/build-ffmpeg.sh`, which
    /// `scripts/build.sh` checks — a stale version here is a false statement in
    /// a legal notice, and it looks exactly like a true one.
    static let ffmpegVersion = "7.1.1"

    /// The exact tarball `scripts/build-ffmpeg.sh` downloads. Derived from the
    /// version so it cannot drift on its own.
    static var ffmpegSourceURL: URL {
        URL(string: "https://ffmpeg.org/releases/ffmpeg-\(ffmpegVersion).tar.xz")!
    }

    /// A public copy of `scripts/build-ffmpeg.sh`. The RCam repo is private, so
    /// this gist is the only place a user can read how the vendored static libs
    /// were configured and built.
    static let buildRecipeURL =
        URL(string: "https://gist.github.com/paulstraw/05d0d7cda9d12bf4122f4bae51227ca7")!

    /// The license ships as a bundle resource rather than a Swift literal, so a
    /// copy of it physically accompanies the binary — which is the wording §6
    /// actually uses. The fallback is a URL rather than an empty view: a
    /// missing resource must not silently turn the notice into a blank page.
    static var licenseText: String {
        guard let url = Bundle.main.url(forResource: "COPYING", withExtension: "LGPLv2.1"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            The GNU Lesser General Public License, version 2.1, is available at
            https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
            """
        }
        return text
    }
}

struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(Acknowledgements.licenseText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FFmpeg \(Acknowledgements.ffmpegVersion)")
                .font(.headline)
            Text("LGPL-2.1-or-later · unmodified · statically linked")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("""
                 RCam uses FFmpeg to demux and decode RTSP streams. FFmpeg is \
                 not modified: it is built from the unmodified upstream release \
                 below, with the configuration in the linked build recipe.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("Source (ffmpeg-\(Acknowledgements.ffmpegVersion).tar.xz)",
                     destination: Acknowledgements.ffmpegSourceURL)
                Link("Build recipe", destination: Acknowledgements.buildRecipeURL)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
