//
//  WebSpooferView.swift
//  StikDebug
//

import SwiftUI
import WebKit
import CoreLocation

struct WebSpooferView: View {
    @ObservedObject private var syncService = WebSpooferSyncService.shared
    @State private var selectedTab = 0
    @State private var webViewReloadTrigger = false
    @State private var showSafariAlert = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $selectedTab) {
                Text("Web Panel").tag(0)
                Text("Sync Settings").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == 0 {
                webPanelTab
            } else {
                settingsTab
            }
        }
        .navigationTitle("Web Location Spoofer")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Web Panel Tab

    @ViewBuilder
    private var webPanelTab: some View {
        if let endpoints = syncService.resolveEndpoints() {
            ZStack(alignment: .bottom) {
                WebSpooferWebView(url: endpoints.panelURL, reloadTrigger: $webViewReloadTrigger)
                    .ignoresSafeArea(edges: .bottom)

                floatingControlBar(endpoints: endpoints)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        webViewReloadTrigger.toggle()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Link(destination: endpoints.panelURL) {
                        Image(systemName: "safari")
                    }
                }
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "cloud.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Web Panel Not Configured")
                    .font(.title3.weight(.bold))

                Text("Enter your iOS-Location-Spoofer-Web URL in Sync Settings to load your Liquid Glass map panel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    selectedTab = 1
                } label: {
                    Label("Configure in Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
        }
    }

    private func floatingControlBar(endpoints: ResolvedWebEndpoints) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(syncService.isSyncing ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncService.isSyncing ? "Cloud Sync Active" : "Cloud Sync Paused")
                        .font(.subheadline.weight(.semibold))

                    Text(syncService.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    if syncService.isSyncing {
                        syncService.stopSync(clearDeviceLocation: false)
                    } else {
                        syncService.startSync()
                    }
                } label: {
                    Text(syncService.isSyncing ? "Pause" : "Start")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(syncService.isSyncing ? .orange : .green)
            }

            if let lastCoord = syncService.lastSyncedCoordinate {
                HStack {
                    Text(String(format: "Injected: %.5f, %.5f", lastCoord.latitude, lastCoord.longitude))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    if syncService.lastDriftActive {
                        Text("• Drift ±1.5m")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    Text("Count: \(syncService.syncCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        Form {
            Section {
                TextField("https://your-project.pages.dev/u/user", text: $syncService.endpointInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                SecureField("Token (optional)", text: $syncService.tokenInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Web Spoofer Endpoint")
            } footer: {
                Text("Supports Cloudflare Pages, Vercel or self-hosted iOS-Location-Spoofer-Web panel. The /u/:user path or token parameter is automatically parsed.")
            }

            Section {
                HStack {
                    Text("Poll Cadence")
                    Spacer()
                    Text(String(format: "%.1f s", syncService.pollIntervalSeconds))
                        .foregroundStyle(.secondary)
                }

                Slider(value: $syncService.pollIntervalSeconds, in: 1.0...10.0, step: 0.5)
            } header: {
                Text("Sync Rate")
            } footer: {
                Text("3.0s is recommended to receive smooth natural harmonic breathing drift (±1.5m) and keep developer mode simulation active.")
            }

            Section("Actions") {
                Button {
                    if syncService.isSyncing {
                        syncService.stopSync(clearDeviceLocation: false)
                    } else {
                        syncService.startSync()
                    }
                } label: {
                    HStack {
                        Label(
                            syncService.isSyncing ? "Stop Cloud Sync" : "Start Cloud Sync",
                            systemImage: syncService.isSyncing ? "stop.fill" : "play.fill"
                        )
                        Spacer()
                        if syncService.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .tint(syncService.isSyncing ? .orange : .green)

                Button {
                    syncService.syncNow()
                } label: {
                    Label("Sync Once Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!syncService.isSyncing && syncService.resolveEndpoints() == nil)

                Button(role: .destructive) {
                    syncService.stopSync(clearDeviceLocation: true, reason: "Reset by user")
                } label: {
                    Label("Clear Simulated Location & Stop", systemImage: "xmark.circle")
                }
            }

            Section("Live Sync Status") {
                LabeledContent("Status", value: syncService.statusMessage)

                if let coord = syncService.lastSyncedCoordinate {
                    LabeledContent("Coordinate", value: String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                }

                if let alt = syncService.lastAltitude {
                    LabeledContent("Altitude", value: String(format: "%.1f m", alt))
                }

                LabeledContent("Harmonic Drift", value: syncService.lastDriftActive ? "Active (±1.5m)" : "Off")

                LabeledContent("Total Syncs", value: "\(syncService.syncCount)")

                if let date = syncService.lastSyncDate {
                    LabeledContent("Last Update", value: date.formatted(date: .omitted, time: .standard))
                }

                if let error = syncService.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("LocalDevVPN Required") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iOS 17.4+ On-Device Protocol")
                        .font(.subheadline.weight(.semibold))

                    Text("On-device developer mode simulation connects via local loopback (10.7.0.1). Ensure LocalDevVPN is connected. When on cellular (4G/5G), enable Airplane Mode for 1 second during first connection, then disable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - WKWebView Wrapper

private struct WebSpooferWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadTrigger: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebSpooferWebView
        var lastReloadTrigger: Bool

        init(_ parent: WebSpooferWebView) {
            self.parent = parent
            self.lastReloadTrigger = parent.reloadTrigger
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Optional error handling
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Optional error handling
        }
    }
}
