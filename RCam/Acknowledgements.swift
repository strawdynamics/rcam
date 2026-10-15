import SwiftUI

/// Third-party attribution. FFmpeg is RCam's only non-system dependency, so
/// this is a one-entry list rather than a generated manifest.
///
/// LGPL-2.1 §6 obliges a work that links the library to give prominent notice,
/// to supply a copy of the license, and to make the corresponding source
/// available. The first two happen in `AcknowledgementsSheet`; the third is the
/// upstream tarball — FFmpeg is vendored unmodified — plus the published build
/// recipe.
///
/// §6 also wants the user to be able to relink the work against their own build
/// of the library, and offers two ways to satisfy it: ship the object files
/// (§6a) or use "a suitable shared library mechanism" (§6b). RCam takes §6b —
/// FFmpeg is three dylibs in `Contents/Frameworks`, replaceable in place — which
/// is why the build is `--enable-shared`. A statically linked bundle offered
/// neither, and a published build recipe is not one of the options.
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

    /// `scripts/build-ffmpeg.sh` on `main` in the public repo: the exact
    /// configure flags and build steps behind the bundled FFmpeg libraries, so a
    /// user can rebuild them and swap them in.
    static let buildRecipeURL =
        URL(string: "https://github.com/strawdynamics/rcam/blob/main/scripts/build-ffmpeg.sh")!

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
            Text("LGPL-2.1-or-later · unmodified · dynamically linked")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("""
                 RCam uses FFmpeg to demux RTSP streams. FFmpeg is not modified: \
                 it is built from the unmodified upstream release below, with the \
                 configuration in the linked build recipe, and ships as separate \
                 libraries inside RCam.app/Contents/Frameworks so you can rebuild \
                 and replace them.
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
