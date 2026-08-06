import AnvilCore
import AppKit
import SwiftUI

@main
struct AnvilMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Anvil", systemImage: model.isActive ? "lock.fill" : "lock.open") {
            ContentView()
                .environmentObject(model)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppModel: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var selectedPresetID: UUID?
    @Published var minutes = 30
    @Published var status = "Ready"
    @Published var publicState = PublicState(isActive: false, endsAt: nil, presetName: nil)

    private let presetsURL = AnvilPaths.userPresetsFile
    private var timer: Timer?

    var isActive: Bool { publicState.endsAt.map { $0 > Date() } ?? false }
    var selectedPreset: Preset? { presets.first { $0.id == selectedPresetID } }

    init() {
        loadPresets()
        readPublicState()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.readPublicState()
        }
    }

    func loadPresets() {
        if let loaded = try? JSONFiles.read([Preset].self, from: presetsURL), !loaded.isEmpty {
            presets = loaded
        } else {
            presets = [
                Preset(
                    name: "Deep Work",
                    appBundleIDs: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"],
                    appPaths: ["/Applications/Slack.app", "/System/Applications/Messages.app"],
                    domains: ["youtube.com", "x.com", "reddit.com"],
                    defaultMinutes: 60
                )
            ]
            savePresets()
        }
        selectedPresetID = presets.first?.id
        minutes = presets.first?.defaultMinutes ?? 30
    }

    func savePresets() {
        try? JSONFiles.write(presets.map { $0.normalized() }, to: presetsURL, permissions: 0o644)
    }

    func readPublicState() {
        let url = AnvilPaths().publicStateFile
        if let state = try? JSONFiles.read(PublicState.self, from: url) {
            DispatchQueue.main.async {
                self.publicState = state
            }
        }
    }

    func startSelected() {
        guard let preset = selectedPreset else { return }
        let request = StartRequest(preset: preset, minutes: minutes)
        do {
            let response = try ControlSocketClient().send(request)
            status = response
            // The panel dismisses the moment a dialog button is tapped, so the
            // status line is gone before anyone can read it. A failed start looked
            // exactly like a successful one: the window just closed. Anything other
            // than a clean start has to be reported in something that outlives the
            // panel.
            if !response.hasPrefix("ok") {
                presentAlert(
                    title: "Anvil did not start the block",
                    message: response.isEmpty ? "The daemon accepted the connection but sent no reply." : response
                )
            }
        } catch {
            status = "Could not reach the daemon."
            presentAlert(
                title: "Anvil could not reach the daemon",
                message: """
                \(error.localizedDescription)

                Nothing was blocked. Check that the daemon is running:

                    sudo launchctl print system/com.cjverma.anvild
                    ls -l /var/run/anvil.sock
                """
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func addPreset() {
        let preset = Preset(name: "New Block", domains: [], defaultMinutes: 30)
        presets.append(preset)
        selectedPresetID = preset.id
        savePresets()
    }

    func deleteSelected() {
        guard let id = selectedPresetID else { return }
        presets.removeAll { $0.id == id }
        selectedPresetID = presets.first?.id
        savePresets()
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var appBundleIDs = ""
    @State private var appPaths = ""
    @State private var domains = ""
    @State private var showingConfirm = false
    /// Captured once, when Start is pressed.
    ///
    /// Both the dialog body and its button used to call a helper that recomputed
    /// Date() + minutes on each SwiftUI evaluation, so they were rendered at
    /// different moments and disagreed by an hour on screen. A confirmation for
    /// something with no undo has to state one time and mean it.
    @State private var pendingEndsAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("Preset", selection: $model.selectedPresetID) {
                ForEach(model.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .onChange(of: model.selectedPresetID) { _ in syncFields() }

            editor
            duration
            controls
            HStack(alignment: .firstTextBaseline) {
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                // Without this there is no way out of the app at all: the window
                // style has no context menu, and LSUIElement means no Dock icon
                // and no Cmd-Q. Quitting does not touch an active block — the
                // daemon owns the deadline and keeps enforcing it.
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.footnote)
                .help("Quits the menu bar app. An active block keeps running.")
            }
        }
        .padding(16)
        .onAppear(perform: syncFields)
        .confirmationDialog("Start Anvil?", isPresented: $showingConfirm, titleVisibility: .visible) {
            Button("Block until \(formatted(pendingEndsAt))", role: .destructive) {
                model.startSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    /// Spells out the actual consequences, because this is the last screen before
    /// something that cannot be undone.
    private var confirmationMessage: String {
        let preset = model.selectedPreset
        let apps = (preset?.appBundleIDs.count ?? 0) + (preset?.appPaths.count ?? 0)
        let sites = preset?.domains.count ?? 0
        return """
        \(apps) app(s) and \(sites) website(s) blocked until \(formatted(pendingEndsAt)).

        Terminal, iTerm, Activity Monitor and System Settings close for the whole \
        session. Your browsers restart now, so save anything open.

        There is no early exit. Safe Mode is the recovery path.
        """
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anvil")
                .font(.title2.bold())
            if let endsAt = model.publicState.endsAt, endsAt > Date() {
                Text("Active until \(endsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
            } else {
                Text("No active block")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelledField(
                "Blocked apps",
                caption: "Bundle IDs, comma separated",
                text: $appBundleIDs,
                prompt: "com.apple.Music, com.tinyspeck.slackmacgap"
            )
            labelledField(
                "Blocked app paths",
                caption: "Optional, comma separated",
                text: $appPaths,
                prompt: "/Applications/Slack.app"
            )
            labelledField(
                "Blocked websites",
                caption: "Comma separated",
                text: $domains,
                prompt: "reddit.com, youtube.com"
            )
        }
        .onChange(of: appBundleIDs) { _ in commitFields() }
        .onChange(of: appPaths) { _ in commitFields() }
        .onChange(of: domains) { _ in commitFields() }
    }

    /// A visible heading per field, and a real minimum height.
    ///
    /// Three bare vertical-axis text fields collapsed to a few pixels with no
    /// visible placeholder, so an empty preset looked identical to a filled one.
    /// That is a bad thing to get wrong in front of a Start button you cannot undo.
    private func labelledField(
        _ title: String,
        caption: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            TextField(prompt, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(2...4)
        }
    }

    private var duration: some View {
        VStack(alignment: .leading) {
            Stepper("Duration: \(model.minutes) min", value: $model.minutes, in: 1...1_440, step: 5)
            Slider(value: Binding(
                get: { Double(model.minutes) },
                set: { model.minutes = Int($0) }
            ), in: 1...1_440, step: 1)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                model.addPreset()
                syncFields()
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button(role: .destructive) {
                model.deleteSelected()
                syncFields()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Spacer()
            Button {
                pendingEndsAt = Date().addingTimeInterval(TimeInterval(model.minutes * 60))
                showingConfirm = true
            } label: {
                Label("Start", systemImage: "lock.fill")
            }
            .keyboardShortcut(.defaultAction)
            // An empty preset still kills the escape tools, so starting one costs
            // you Terminal for the duration and blocks nothing in return.
            .disabled(model.selectedPreset?.blocksNothing ?? true)
            .help(
                (model.selectedPreset?.blocksNothing ?? true)
                    ? "Add at least one app or website first."
                    : "Starts the block. There is no way to cancel it."
            )
        }
    }

    private func syncFields() {
        guard let preset = model.selectedPreset else { return }
        appBundleIDs = preset.appBundleIDs.joined(separator: ", ")
        appPaths = preset.appPaths.joined(separator: ", ")
        domains = preset.domains.joined(separator: ", ")
        model.minutes = preset.defaultMinutes
    }

    private func commitFields() {
        guard let id = model.selectedPresetID, let index = model.presets.firstIndex(where: { $0.id == id }) else { return }
        model.presets[index].appBundleIDs = split(appBundleIDs)
        model.presets[index].appPaths = split(appPaths)
        model.presets[index].domains = split(domains)
        model.presets[index].defaultMinutes = model.minutes
        model.savePresets()
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
