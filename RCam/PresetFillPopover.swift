import SwiftUI

/// Pick a camera platform, give it an address, and write both stream URLs.
///
/// Deliberately one-shot: nothing here is persisted on `CameraConfig`. The
/// URLs it writes are ordinary editable text afterwards, which keeps
/// `mainURL`/`subURL` the single source of truth that `Test Connection` and
/// `ConfigStore.resolvedURL` already assume — and makes the common tweak (a
/// different substream index, an NVR's channel number) just an edit.
struct PresetFillPopover: View {
    /// Seeds the address field, so the popover is as useful for fixing a URL
    /// that will not connect as it is for writing the first one.
    let currentMainURL: String
    let onFill: (_ mainURL: String, _ subURL: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var addressText = ""
    @State private var selectedID: CameraPreset.ID?
    @State private var seeded = false

    private var selected: CameraPreset? {
        CameraPreset.all.first { $0.id == selectedID }
    }

    private var address: StreamAddress? {
        CameraPreset.parseAddress(addressText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            addressField
            presetList
            preview
            Divider()
            buttons
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let existing = CameraPreset.parseAddress(currentMainURL) {
                addressText = existing.text
            }
            selectedID = CameraPreset.all.first?.id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Fill from Preset")
                .font(.headline)
            Text("Pick your camera's platform and enter its address on your network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Address", text: $addressText,
                      prompt: Text("192.168.1.64"))
                .labelsHidden()
                .fontDesign(.monospaced)
                .textFieldStyle(.roundedBorder)
            Text("An IP or hostname. Add `:port` if it is not 554 — a whole RTSP URL works too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetList: some View {
        List(CameraPreset.all, selection: $selectedID) { preset in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                    if let aka = preset.alsoKnownAs {
                        Text(aka)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if preset.provenance.isTested {
                    Text("TESTED")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            .tag(preset.id)
        }
        .listStyle(.bordered)
        .frame(height: 148)
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preset = selected, let address {
                previewRow("Main", preset.mainURL(at: address))
                if preset.subPath == nil {
                    previewRow("Sub", "none for this camera", isPlaceholder: true)
                } else {
                    previewRow("Sub", preset.subURL(at: address))
                }
            } else {
                Text(addressText.isEmpty
                     ? "Enter an address to see the URLs."
                     : "That address could not be read.")
                    .font(.caption)
                    .foregroundStyle(addressText.isEmpty ? Color.secondary : Color.red)
            }

            if let preset = selected {
                Text(preset.provenance.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(_ label: String,
                            _ value: String,
                            isPlaceholder: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(isPlaceholder ? .tertiary : .secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Fill") {
                guard let preset = selected, let address else { return }
                onFill(preset.mainURL(at: address), preset.subURL(at: address))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil || address == nil)
        }
    }
}
