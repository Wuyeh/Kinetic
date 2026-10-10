import SwiftUI

@MainActor
struct WeatherSettingsView: View {
    @ObservedObject var model: WeatherSettingsModel
    @ObservedObject var weather: WeatherService
    @ObservedObject var store: WeatherStore
    @ObservedObject var responses: WeatherResponseStore
    let onEditParticles: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("weather.mode", selection: $model.locationDraft.mode) {
                ForEach(WeatherMode.allCases, id: \.self) { Text(LocalizedStringKey("weather.mode." + $0.rawValue)).tag($0) }
            }
            if model.locationDraft.mode == .manual {
                HStack {
                    TextField("weather.city", text: $model.searchText).textFieldStyle(.roundedBorder)
                        .onSubmit { model.search() }
                    Button { model.search() } label: { Text("weather.search").foregroundStyle(.primary) }
                        .kineticGlassButton().disabled(model.isSearching || model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                if !model.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.searchResults) { place in
                            Button { model.choosePlace(place) } label: {
                                HStack {
                                    Text(place.name).lineLimit(2)
                                    Spacer()
                                    if model.locationDraft.manualPlace?.id == place.id { Image(systemName: "checkmark") }
                                }.foregroundStyle(.primary).contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                }
                if let place = model.locationDraft.manualPlace { Text(place.name).font(.caption).foregroundStyle(.secondary) }
            }
            Text("weather.privacy").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.saveLocation() } label: { Text("weather.saveLocation").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(!model.canSaveLocation)
                Button { weather.refresh() } label: { Text("weather.refresh").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(store.configuration.mode == .off || weather.isFetching)
                if weather.isFetching { ProgressView().controlSize(.small) }
            }
            reading
            if let message = weather.reading.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 4) {
                Text("weather.dataSource").font(.caption).foregroundStyle(.secondary)
                Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
                Text("/ ").font(.caption).foregroundStyle(.secondary)
                Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!).font(.caption)
            }
            Divider()
            responseSettings
            if let error = model.error ?? store.loadError ?? responses.loadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { model.opened() }.onDisappear { model.closed() }
    }
    @ViewBuilder private var reading: some View {
        if let snapshot = weather.reading.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.place.name).font(.headline)
                HStack {
                    Text(snapshot.condition.title)
                    Text(snapshot.temperatureCelsius.formatted(.number.precision(.fractionLength(1))) + " °C")
                    Text(snapshot.isDay ? "weather.day" : "weather.night")
                }
                HStack {
                    Text("weather.wind")
                    Text(snapshot.windSpeedMetresPerSecond.formatted(.number.precision(.fractionLength(1))) + " m/s")
                    Text("weather.precipitation")
                    Text(snapshot.precipitationMillimetres.formatted(.number.precision(.fractionLength(1))) + " mm")
                }.font(.caption).foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("weather.observed", comment: ""), observed(snapshot))).font(.caption).foregroundStyle(.secondary)
                if snapshot.isStale { Text("weather.stale").font(.caption).foregroundStyle(.secondary) }
                else if snapshot.availability == .cached { Text("weather.cached").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            Text(LocalizedStringKey("weather.state." + weather.reading.activity.rawValue)).foregroundStyle(.secondary)
        }
    }
    private func observed(_ snapshot: WeatherSnapshot) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh-Hans")
        formatter.timeZone = TimeZone(identifier: snapshot.place.timeZone); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: snapshot.observedAt)
    }
    private var responseSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("weather.response.title").font(.headline)
            Picker("weather.response.display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                if model.selectedDisplayID == nil { Text("particles.noDisplay").tag(Optional<DisplayID>.none) }
                ForEach(model.connectedDisplays) { Text($0.name).tag(Optional($0.id)) }
                if let id = model.selectedDisplayID, !model.connectedDisplays.contains(where: { $0.id == id }) {
                    Text("particles.disconnected").tag(Optional(id))
                }
            }
            if model.particleLayers.isEmpty {
                Text("weather.response.noLayer").font(.caption).foregroundStyle(.secondary)
                if let onEditParticles {
                    Button(action: onEditParticles) { Text("particles.open").foregroundStyle(.primary) }.kineticGlassButton()
                }
            }
            Picker("weather.response.layer", selection: Binding(get: { model.selectedOverlayID }, set: { model.selectOverlay($0) })) {
                if model.selectedOverlayID == nil { Text("weather.response.noLayerShort").tag(Optional<UUID>.none) }
                ForEach(model.particleLayers) { layer in
                    Text((try? ParticleOptions(configuration: layer).preset.title) ?? NSLocalizedString("particles.title", comment: ""))
                        .tag(Optional(layer.id))
                }
                if let id = model.selectedOverlayID, !model.particleLayers.contains(where: { $0.id == id }) {
                    Text("weather.response.missingLayer").tag(Optional(id))
                }
            }.disabled(model.particleLayers.isEmpty)
            Toggle("weather.response.enabled", isOn: $model.responseEnabled)
            Toggle("weather.response.type", isOn: $model.followsType)
            Toggle("weather.response.intensity", isOn: $model.followsIntensity)
            Toggle("weather.response.wind", isOn: $model.followsWind)
            Text("weather.response.detail").font(.caption).foregroundStyle(.secondary)
            Button { model.saveResponse() } label: { Text("weather.response.save").foregroundStyle(.primary) }
                .kineticGlassButton().disabled(!model.canSaveResponse)
        }
    }
}
