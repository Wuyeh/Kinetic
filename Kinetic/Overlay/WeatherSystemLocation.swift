import CoreLocation
import Foundation

@MainActor
protocol WeatherLocating: AnyObject {
    var onAccessRevoked: (() -> Void)? { get set }
    func locate(requestAuthorization: Bool) async throws -> WeatherPlace
    func cancel()
}

/// Lazy, single-fix, kilometre accuracy. Construction and restored settings never prompt.
@MainActor
final class WeatherSystemLocation: NSObject, WeatherLocating, CLLocationManagerDelegate {
    var onAccessRevoked: (() -> Void)?
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<WeatherPlace, Error>?
    private var timeout: Task<Void, Never>?
    private var token = UUID()
    var hasCreatedManager: Bool { manager != nil }

    func locate(requestAuthorization: Bool) async throws -> WeatherPlace {
        cancel(); try Task.checkCancellation()
        if manager == nil {
            let manager = CLLocationManager(); self.manager = manager
            manager.desiredAccuracy = kCLLocationAccuracyKilometer; manager.delegate = self
        }
        guard let manager else { throw WeatherError.locationUnavailable }
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { throw WeatherError.permissionDenied }
        if status == .notDetermined && !requestAuthorization { throw WeatherError.permissionRequired }
        let token = UUID(); self.token = token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    guard let self, self.token == token else { return }; self.finish(.failure(WeatherError.locationUnavailable))
                }
                if status == .notDetermined { manager.requestWhenInUseAuthorization() }
                else { manager.requestLocation() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in guard let self, self.token == token else { return }; self.cancel() }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<WeatherPlace, Error>) {
        let continuation = continuation; self.continuation = nil
        timeout?.cancel(); timeout = nil; manager?.stopUpdatingLocation()
        continuation?.resume(with: result)
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, self.manager === manager else { return }
            if status == .denied || status == .restricted {
                self.finish(.failure(WeatherError.permissionDenied)); self.onAccessRevoked?()
            } else if status != .notDetermined, self.continuation != nil { manager.requestLocation() }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) <= 300 else { return }
        let latitude = (fix.coordinate.latitude * 100).rounded() / 100
        let longitude = (fix.coordinate.longitude * 100).rounded() / 100
        Task { @MainActor [weak self] in
            guard let self, self.manager === manager, self.continuation != nil else { return }
            let place = WeatherPlace(id: "system:\(latitude):\(longitude)", name: NSLocalizedString("weather.systemPlace", comment: ""),
                latitude: latitude, longitude: longitude, timeZone: TimeZone.current.identifier)
            do { self.finish(.success(try place.validated())) } catch { self.finish(.failure(error)) }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor [weak self] in
            guard let self, self.manager === manager else { return }
            self.finish(.failure(denied ? WeatherError.permissionDenied : WeatherError.locationUnavailable))
        }
    }
    deinit { timeout?.cancel() }
}
