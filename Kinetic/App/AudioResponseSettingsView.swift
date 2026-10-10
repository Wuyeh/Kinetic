import SwiftUI

@MainActor struct AudioResponseSettingsView: View {
    @ObservedObject var service: AudioResponseService
    @ObservedObject var music: MusicService
    @State private var connecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("audioResponse.title").font(.headline)
            Toggle("audioResponse.enabled", isOn: Binding(get: { service.settings.isEnabled }, set: { service.setEnabled($0) }))
            Text("audioResponse.privacy").font(.caption).foregroundStyle(.secondary)
            Text(service.status.message).foregroundStyle(.secondary)
            if service.status == .listening {
                ProgressView(value: Double(service.level)).accessibilityLabel(Text("audioResponse.level"))
            }
            if service.status == .permissionRequired || service.status == .failed {
                Button("audioResponse.retry", action: service.retry).kineticGlassButton()
            }
            Divider()
            Text("audioResponse.media").font(.headline)
            Picker("music.source", selection: Binding(get: { service.settings.mediaSource }, set: { service.setMediaSource($0) })) {
                ForEach(MusicSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("audioResponse.media.detail").font(.caption).foregroundStyle(.secondary)
            Button("music.connect") {
                let source = service.settings.mediaSource; connecting = true
                Task { _ = await music.authorize(source); connecting = false }
            }.kineticGlassButton().disabled(connecting)
            Text(music.snapshots[service.settings.mediaSource]?.availability.message ?? MusicAvailability.inactive.message)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
