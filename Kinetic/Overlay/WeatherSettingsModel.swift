import Combine
import Foundation

@MainActor
final class WeatherSettingsModel: ObservableObject {
    let weather: WeatherService
    let responses: WeatherResponseStore
    private let overlays: OverlayStore
    private let registry: DisplayRegistry
    @Published var locationDraft = WeatherConfiguration()
    @Published var searchText = ""
    @Published private(set) var searchResults: [WeatherPlace] = []
    @Published private(set) var isSearching = false
    @Published private(set) var connectedDisplays: [DisplayDescriptor] = []
    @Published private(set) var particleLayers: [OverlayConfiguration] = []
    @Published private(set) var selectedDisplayID: DisplayID?
    @Published private(set) var selectedOverlayID: UUID?
    @Published var responseEnabled = false
    @Published var followsType = true
    @Published var followsIntensity = true
    @Published var followsWind = true
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var allLayers: [OverlayConfiguration] = []
    private var subscriptions = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var searchToken = UUID()

    init(weather: WeatherService, responses: WeatherResponseStore, overlays: OverlayStore, registry: DisplayRegistry) {
        self.weather = weather; self.responses = responses; self.overlays = overlays; self.registry = registry
        locationDraft = weather.store.configuration
        registry.$displays.sink { [weak self] value in
            guard let self else { return }; self.connectedDisplays = value.filter(\.isPersistent)
            if self.selectedDisplayID == nil { self.selectDisplay(self.connectedDisplays.first?.id) }
        }.store(in: &subscriptions)
        overlays.$configurations.sink { [weak self] value in self?.allLayers = value; self?.updateLayers() }.store(in: &subscriptions)
    }
    var canSaveLocation: Bool { weather.isStarted && weather.store.loadError == nil && (try? locationDraft.validated()) != nil }
    var canSaveResponse: Bool {
        guard responses.loadError == nil, let id = selectedOverlayID, let display = selectedDisplayID else { return false }
        if connectedDisplays.contains(where: { $0.id == display }), particleLayers.contains(where: { $0.id == id }) { return true }
        return !responseEnabled && responses.configurations.contains { $0.overlayID == id && $0.displayID == display }
    }
    func opened() { locationDraft = weather.store.configuration; loadResponse(); error = nil; notice = nil }
    func closed() { cancelSearch(); searchResults = []; searchText = "" }
    func choosePlace(_ place: WeatherPlace) { locationDraft.manualPlace = place; notice = nil }
    func search() {
        cancelSearch(); error = nil; searchResults = []; isSearching = true
        let query = searchText, token = UUID(); searchToken = token
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let results = try await self.weather.client.searchPlaces(query); try Task.checkCancellation()
                guard self.searchToken == token else { return }; self.searchResults = results
                if results.isEmpty { self.notice = NSLocalizedString("weather.noResults", comment: "") }
            } catch {
                guard !Task.isCancelled, self.searchToken == token else { return }
                self.error = (error as? WeatherError)?.localizedDescription ?? WeatherError.network.localizedDescription
            }
            guard self.searchToken == token else { return }; self.isSearching = false; self.searchTask = nil
        }
    }
    func cancelSearch() { searchToken = UUID(); searchTask?.cancel(); searchTask = nil; isSearching = false }
    func saveLocation() {
        do {
            try weather.configure(locationDraft, requestSystemPermission: locationDraft.mode == .system)
            error = nil; notice = NSLocalizedString("weather.saved", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    func selectDisplay(_ id: DisplayID?) {
        selectedDisplayID = id
        selectedOverlayID = responses.configurations.first { $0.displayID == id }?.overlayID
        updateLayers(); loadResponse()
    }
    func selectOverlay(_ id: UUID?) { selectedOverlayID = id; loadResponse() }
    private func updateLayers() {
        particleLayers = allLayers.filter { $0.kind == .particles && $0.displayID == selectedDisplayID }
        if selectedOverlayID == nil { selectedOverlayID = particleLayers.first?.id; loadResponse() }
        // A missing target remains selected; never silently move automation to another layer/display.
    }
    private func loadResponse() {
        let saved = responses.configurations.first { $0.overlayID == selectedOverlayID && $0.displayID == selectedDisplayID }
        responseEnabled = saved?.isEnabled ?? false; followsType = saved?.followsType ?? true
        followsIntensity = saved?.followsIntensity ?? true; followsWind = saved?.followsWind ?? true
    }
    func saveResponse() {
        guard canSaveResponse, let overlayID = selectedOverlayID, let displayID = selectedDisplayID else {
            error = OverlayError.targetUnavailable.localizedDescription; return
        }
        do {
            try responses.upsert(.init(overlayID: overlayID, displayID: displayID, isEnabled: responseEnabled,
                                       followsType: followsType, followsIntensity: followsIntensity, followsWind: followsWind))
            error = nil; notice = NSLocalizedString("weather.response.saved", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    deinit { searchTask?.cancel() }
}
