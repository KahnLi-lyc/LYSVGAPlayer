import LYSVGAPlayer
import SwiftUI
import UniformTypeIdentifiers

struct SwiftUIDemoView: View {
    @StateObject private var controller = LYSVGAPlayerController()
    @State private var loader = LYSVGAAssetLoader()
    @State private var loadTask: Task<Void, Never>?
    @State private var remoteURL = ""
    @State private var isImporting = false
    @State private var loopsForever = true
    @State private var playsInReverse = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LYSVGAView(controller: controller, contentMode: .scaleAspectFit, clipsToBounds: true)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .background(Color(uiColor: .secondarySystemBackground))

                    sourceControls
                    playbackControls
                    dynamicControls

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("SwiftUI Player")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [UTType.data],
                allowsMultipleSelection: false,
                onCompletion: importFile
            )
            .onDisappear { loadTask?.cancel() }
        }
    }

    private var sourceControls: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(DemoSample.allCases) { sample in
                        Button(sample.title) { load(sample) }
                    }
                    if DemoSupport.localAssets.isEmpty == false {
                        Section("Local Assets") {
                            ForEach(DemoSupport.localAssets) { asset in
                                Button(asset.title) { startLoad(.file(asset.url)) }
                            }
                        }
                    }
                } label: {
                    Label("Bundle", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)

                Button {
                    isImporting = true
                } label: {
                    Label("File", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            HStack {
                TextField("HTTPS SVGA URL", text: $remoteURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    loadRemoteURL()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Load URL")
            }
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { controller.currentProgress },
                    set: { controller.seek(toProgress: $0) }
                ),
                in: 0...1
            )
            .disabled(controller.video == nil)

            HStack(spacing: 18) {
                Button(action: togglePlayback) {
                    Image(systemName: controller.playbackState == .playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(controller.playbackState == .playing ? "Pause" : "Play")

                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop")

                Button {
                    controller.isMuted.toggle()
                } label: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")
            }

            HStack {
                Toggle(isOn: $loopsForever) {
                    Label("Loop", systemImage: "repeat")
                }
                Toggle(isOn: $playsInReverse) {
                    Label("Reverse", systemImage: "backward.end")
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var dynamicControls: some View {
        HStack {
            Button {
                guard let key = controller.video?.sprites.first?.imageKey else { return }
                controller.playerView.setImage(DemoSupport.replacementImage(), forKey: key)
            } label: {
                Label("Replace", systemImage: "photo.badge.arrow.down")
            }
            .buttonStyle(.bordered)

            Button {
                controller.playerView.clearDynamicContents()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
        }
    }

    private func togglePlayback() {
        if controller.playbackState == .playing {
            controller.pause()
        } else if controller.playbackState == .paused {
            controller.resume()
        } else {
            controller.repeatMode = loopsForever ? .forever : .once
            do {
                try controller.play(reverse: playsInReverse)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load(_ sample: DemoSample) {
        guard let url = sample.url else {
            errorMessage = "Missing bundled sample: \(sample.rawValue).svga"
            return
        }
        startLoad(.file(url))
    }

    private func loadRemoteURL() {
        guard let url = URL(string: remoteURL), url.scheme?.lowercased() == "https" else {
            errorMessage = "Enter a valid HTTPS URL."
            return
        }
        startLoad(.remote(url))
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first
            guard let url else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            startLoad(.file(url)) {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startLoad(_ source: LYSVGASource, completion: (() -> Void)? = nil) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            defer { completion?() }
            errorMessage = nil
            do {
                controller.repeatMode = loopsForever ? .forever : .once
                try await controller.load(source, using: loader, autoplay: true)
            } catch let error as LYSVGAError where error == .cancelled {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
