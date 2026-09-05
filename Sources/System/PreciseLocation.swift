import AppKit
import CoreLocation
import Foundation

/// Requests precise coordinates once from the system.
///
/// Each request obtains one fix. The app may repeat this daily when automatic location is enabled.
/// Saved coordinates or permission-free time-zone inference remain available on failure.
///
/// Pitfalls:
/// - CLLocationManager requires a thread with a run loop and delivers callbacks there; always use the main thread.
/// - The permission dialog appears only for .notDetermined. After denial, requestWhenInUseAuthorization
///   does nothing and delivers no callback. Report denial as a terminal outcome so the UI can offer manual entry.
/// - requestLocation() may deliver neither a location nor an error on cold starts or desktops without Wi-Fi,
///   so enforce our own timeout.
@MainActor
final class PreciseLocation: NSObject, CLLocationManagerDelegate {

    enum Outcome {
        case coordinate(Coordinate)
        /// Permission denied or restricted. The UI should prioritize manual coordinate entry.
        case denied
        case failed(String)
    }

    static let shared = PreciseLocation()

    private let manager = CLLocationManager()
    private var completion: ((Outcome) -> Void)?
    private var timeout: DispatchWorkItem?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // Sunrise/sunset needs no finer accuracy.
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Opens System Settings > Privacy & Security > Location Services.
    ///
    /// After denial, requestWhenInUseAuthorization cannot show another dialog; direct users to settings
    /// to enable access themselves. Provide a working link: the pane identifier changed after Ventura,
    /// but the old one is still mapped by the system, so try both and use the first that opens.
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Requests one location; a new request replaces any pending callback (the panel has only one button).
    func request(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion

        switch manager.authorizationStatus {
        case .notDetermined:
            // Authorization returns through locationManagerDidChangeAuthorization, which requests the actual location.
            manager.requestWhenInUseAuthorization()
            arm(seconds: 60)   // Allow time for the user to respond to the dialog.
        case .denied, .restricted:
            finish(.denied)
        default:
            manager.requestLocation()
            arm(seconds: 20)
        }
    }

    // MARK: - Delegate

    // Delegate callbacks arrive on the manager's creation thread, always the main thread here.
    // nonisolated satisfies the nonisolated protocol; execution still occurs on the main actor,
    // bridged with assumeIsolated using the same pattern as Scheduler callbacks.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            switch manager.authorizationStatus {
            case .notDetermined:
                break                       // Dialog still open; wait for the next callback.
            case .denied, .restricted:
                finish(.denied)
            default:
                manager.requestLocation()
                arm(seconds: 20)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            let now = Date()
            guard let last = locations.last(where: {
                LocationRefresh.isUsable(Coordinate(latitude: $0.coordinate.latitude,
                                                    longitude: $0.coordinate.longitude),
                                         accuracy: $0.horizontalAccuracy, timestamp: $0.timestamp, now: now)
            }) else { return } // Keep the timeout armed while waiting for a usable fix.
            finish(.coordinate(Coordinate(latitude: last.coordinate.latitude,
                                          longitude: last.coordinate.longitude)))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .denied { finish(.denied); return }
            finish(.failed((error as NSError).localizedDescription))
        }
    }

    // MARK: - Internals

    private func arm(seconds: TimeInterval) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(.failed(L10n.t("location.error.timeout"))) }
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(_ outcome: Outcome) {
        timeout?.cancel()
        timeout = nil
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
