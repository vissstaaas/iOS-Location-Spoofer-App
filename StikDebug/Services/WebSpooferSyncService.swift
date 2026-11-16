//
//  WebSpooferSyncService.swift
//  StikDebug
//

import Foundation
import CoreLocation
import Combine
import UIKit

struct RemoteLocationPayload: Decodable {
    let enabled: Bool?
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let jitter: Bool?
    let _drift: Bool?
}

private struct RemoteErrorPayload: Decodable {
    let error: String?
    let message: String?
}

struct ResolvedWebEndpoints {
    let panelURL: URL
    let locJSONURL: URL
}

@MainActor
final class WebSpooferSyncService: ObservableObject {
    static let shared = WebSpooferSyncService()

    @Published var endpointInput: String {
        didSet {
            UserDefaults.standard.set(endpointInput, forKey: UserDefaults.Keys.webSpooferEndpoint)
        }
    }

    @Published var tokenInput: String {
        didSet {
            UserDefaults.standard.set(tokenInput, forKey: UserDefaults.Keys.webSpooferToken)
        }
    }

    @Published var pollIntervalSeconds: Double {
        didSet {
            let clamped = min(max(pollIntervalSeconds, 1.0), 30.0)
            if clamped != pollIntervalSeconds {
                pollIntervalSeconds = clamped
                return
            }
            UserDefaults.standard.set(pollIntervalSeconds, forKey: UserDefaults.Keys.webSpooferPollInterval)
            if isSyncing {
                scheduleTimer()
            }
        }
    }

    @Published private(set) var isSyncing = false
    @Published private(set) var isPollingInFlight = false
    @Published private(set) var lastSyncedCoordinate: CLLocationCoordinate2D?
    @Published private(set) var lastAltitude: Double?
    @Published private(set) var lastDriftActive = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncCount: Int = 0
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var lastErrorMessage: String?

    private var pollTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let urlSession: URLSession

    private init() {
        self.endpointInput = UserDefaults.standard.string(forKey: UserDefaults.Keys.webSpooferEndpoint) ?? ""
        self.tokenInput = UserDefaults.standard.string(forKey: UserDefaults.Keys.webSpooferToken) ?? ""
        let savedInterval = UserDefaults.standard.double(forKey: UserDefaults.Keys.webSpooferPollInterval)
        self.pollIntervalSeconds = savedInterval >= 1.0 ? savedInterval : 3.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: config)
    }

    func resolveEndpoints() -> ResolvedWebEndpoints? {
        var raw = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }

        guard var components = URLComponents(string: raw),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }

        let lowerPath = path.lowercased()
        let basePath: String
        if lowerPath.hasSuffix("/loc.json") {
            basePath = String(path.dropLast("/loc.json".count))
        } else if lowerPath.hasSuffix("/ios-location-spoofer.sgmodule") {
            basePath = String(path.dropLast("/ios-location-spoofer.sgmodule".count))
        } else if lowerPath.hasSuffix("/set") {
            basePath = String(path.dropLast("/set".count))
        } else {
            basePath = path
        }

        let trimmedToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryItems = components.queryItems ?? []
        let hasUserPrefix = basePath.range(of: #"/u/[^/]+$"#, options: .regularExpression) != nil
        if !trimmedToken.isEmpty && !hasUserPrefix && !queryItems.contains(where: { $0.name.lowercased() == "token" }) {
            queryItems.append(URLQueryItem(name: "token", value: trimmedToken))
        }

        var panelComponents = components
        panelComponents.path = basePath.isEmpty ? "/" : basePath + "/"
        panelComponents.queryItems = queryItems.isEmpty ? nil : queryItems

        var locComponents = components
        locComponents.path = (basePath.isEmpty ? "" : basePath) + "/loc.json"
        locComponents.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let panelURL = panelComponents.url,
              let locJSONURL = locComponents.url else {
            return nil
        }

        return ResolvedWebEndpoints(panelURL: panelURL, locJSONURL: locJSONURL)
    }

    func configureAndStart(url: String, token: String? = nil) {
        endpointInput = url
        if let token, !token.isEmpty {
            tokenInput = token
        }
        startSync()
    }

    func startSync() {
        let pairingFile = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
            lastErrorMessage = "Pairing file not found. Import a pairing file in Settings first."
            statusMessage = "Missing pairing file"
            return
        }

        guard let endpoints = resolveEndpoints() else {
            lastErrorMessage = "Enter a valid iOS-Location-Spoofer-Web URL (e.g. https://domain/u/user)."
            statusMessage = "Invalid URL"
            return
        }

        lastErrorMessage = nil
        isSyncing = true
        statusMessage = "Connecting to \(endpoints.locJSONURL.host ?? "server")…"

        beginBackgroundKeepAlive()
        LocationSimulationSession.shared.clearRoute()
        LocationSimulationSession.shared.pauseResending()

        scheduleTimer()
        syncNow()
        LogManager.shared.addInfoLog("Web Spoofer sync started: \(endpoints.locJSONURL.absoluteString)")
    }

    func stopSync(clearDeviceLocation: Bool = false, reason: String? = nil) {
        pollTimer?.invalidate()
        pollTimer = nil
        isSyncing = false
        isPollingInFlight = false

        if let reason {
            statusMessage = reason
        } else {
            statusMessage = "Stopped"
        }

        if clearDeviceLocation {
            LocationSimulationCommandQueue.shared.async {
                _ = clear_simulated_location()
                DispatchQueue.main.async {
                    LocationSimulationSession.shared.stop()
                    self.endBackgroundKeepAlive()
                }
            }
        } else {
            endBackgroundKeepAlive()
        }

        LogManager.shared.addInfoLog("Web Spoofer sync stopped\(reason.map { ": \($0)" } ?? "")")
    }

    func syncNow() {
        guard isSyncing, !isPollingInFlight else { return }
        guard let endpoints = resolveEndpoints() else {
            stopSync(clearDeviceLocation: false, reason: "Invalid URL")
            return
        }

        isPollingInFlight = true
        var request = URLRequest(url: endpoints.locJSONURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let trimmedToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }

        Task {
            defer {
                self.isPollingInFlight = false
            }

            do {
                let (data, response) = try await urlSession.data(for: request)
                guard self.isSyncing else { return }

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        let serverError = (try? JSONDecoder().decode(RemoteErrorPayload.self, from: data))
                        let detail = serverError?.error ?? serverError?.message ?? "Access denied (HTTP \(http.statusCode))"
                        self.lastErrorMessage = "Account unavailable: \(detail)"
                        self.stopSync(clearDeviceLocation: true, reason: "Paused / Expired (\(http.statusCode))")
                        return
                    }

                    guard (200...299).contains(http.statusCode) else {
                        self.lastErrorMessage = "HTTP error \(http.statusCode)"
                        self.statusMessage = "Server HTTP \(http.statusCode)"
                        return
                    }
                }

                let payload = try JSONDecoder().decode(RemoteLocationPayload.self, from: data)
                if payload.enabled == false {
                    self.lastErrorMessage = nil
                    self.statusMessage = "Remote spoofing disabled on web panel"
                    LocationSimulationCommandQueue.shared.async {
                        _ = clear_simulated_location()
                    }
                    return
                }

                guard (-90.0...90.0).contains(payload.latitude),
                      (-180.0...180.0).contains(payload.longitude) else {
                    self.lastErrorMessage = "Invalid coordinates from server"
                    return
                }

                await self.applyCoordinateToDevice(
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    altitude: payload.altitude,
                    drift: payload._drift ?? payload.jitter ?? false
                )
            } catch {
                guard self.isSyncing else { return }
                self.lastErrorMessage = error.localizedDescription
                self.statusMessage = "Network retry…"
            }
        }
    }

    func applyDirectCoordinate(latitude: Double, longitude: Double, altitude: Double? = nil) {
        guard (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            return
        }

        if !isSyncing && resolveEndpoints() != nil {
            startSync()
        }

        Task {
            await applyCoordinateToDevice(
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                drift: false
            )
        }
    }

    private func applyCoordinateToDevice(
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        drift: Bool
    ) async {
        let pairingPath = PairingFileStore.prepareURL().path
        let targetIP = DeviceConnectionContext.targetIPAddress

        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                let result = simulate_location(targetIP, latitude, longitude, pairingPath)
                continuation.resume(returning: result)
            }
        }

        guard isSyncing || code == 0 else { return }

        if code == 0 {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            LocationSimulationSession.shared.pauseResending()
            LocationSimulationSession.shared.start(at: coordinate)
            LocationSimulationSession.shared.updateCoordinate(coordinate)

            lastSyncedCoordinate = coordinate
            lastAltitude = altitude
            lastDriftActive = drift
            lastSyncDate = Date()
            syncCount += 1
            lastErrorMessage = nil
            statusMessage = String(format: "Synced %.5f, %.5f", latitude, longitude)
        } else {
            lastErrorMessage = "Tunnel error \(code). Ensure LocalDevVPN is connected."
            statusMessage = "Inject failed (code \(code))"
        }
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func beginBackgroundKeepAlive() {
        BackgroundAudioManager.shared.requestStart()
        BackgroundLocationManager.shared.requestStart()
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WebSpooferSync") { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundKeepAlive()
                }
            }
        }
    }

    private func endBackgroundKeepAlive() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
