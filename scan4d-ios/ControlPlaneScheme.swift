import Foundation

/// A server typed without a scheme ("192.168.1.40:8000"): https first, http only when https can't
/// be connected to. `resolve` probes `GET v1/health` and remembers the winner for the typed text;
/// `ControlPlaneClient.baseURL(fromHost:)` reads it. The password never goes over a resolved http
/// (a stored password is checked at the probe, and setting one forgets the result), and a typed
/// `http://` stays the user's explicit choice.
nonisolated enum ControlPlaneScheme {
    static func hasExplicitScheme(_ host: String) -> Bool { host.contains("://") }

    /// The scheme the probe found for exactly this typed text, if any.
    static func resolved(for typed: String, defaults: UserDefaults = .standard) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard defaults.string(forKey: AppConstants.Key.controlPlaneResolvedFor) == trimmed else { return nil }
        return defaults.string(forKey: AppConstants.Key.controlPlaneResolvedScheme)
    }

    static func record(_ scheme: String, for typed: String, defaults: UserDefaults = .standard) {
        defaults.set(scheme, forKey: AppConstants.Key.controlPlaneResolvedScheme)
        defaults.set(typed.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: AppConstants.Key.controlPlaneResolvedFor)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppConstants.Key.controlPlaneResolvedScheme)
        defaults.removeObject(forKey: AppConstants.Key.controlPlaneResolvedFor)
    }

    /// An https attempt that failed to connect, so http may be the server's way: a refused or
    /// timed-out connection, or a handshake that failed (a plain-http port answers TLS with
    /// nonsense). An untrusted certificate, a missing host or no network are not: they stop here.
    static func shouldFallBack(on error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .timedOut, .secureConnectionFailed, .networkConnectionLost, .badServerResponse:
            return true
        default:
            return false
        }
    }

    private enum Probe {
        case answered
        case connectFailed
        case stopped
    }

    /// Settles the scheme for a typed host without one. Does nothing for an explicit scheme.
    /// Returns the scheme recorded, nil when the probe found none (the https default then applies).
    @discardableResult
    static func resolve(host typed: String, password: String = ControlPlaneSecret.password) async -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasExplicitScheme(trimmed) else { return nil }
        switch await probe("https://" + trimmed) {
        case .answered:
            record("https", for: trimmed)
            return "https"
        case .stopped:
            return nil
        case .connectFailed:
            break
        }
        guard password.isEmpty else { return nil }
        if await probe("http://" + trimmed) == .answered {
            record("http", for: trimmed)
            return "http"
        }
        return nil
    }

    /// Any HTTP answer, even an error status, means something speaks that scheme there.
    private static func probe(_ text: String) async -> Probe {
        guard let base = ControlPlaneClient.parse(text) else { return .stopped }
        ControlPlaneSession.allow(host: base.host())
        var request = URLRequest(url: base.appending(path: "v1/health"))
        request.timeoutInterval = AppConstants.controlPlaneProbeTimeoutS
        do {
            let (_, response) = try await ControlPlaneSession.session.data(for: request)
            return response is HTTPURLResponse ? .answered : .stopped
        } catch let error as URLError {
            return shouldFallBack(on: error) ? .connectFailed : .stopped
        } catch {
            return .stopped
        }
    }
}
