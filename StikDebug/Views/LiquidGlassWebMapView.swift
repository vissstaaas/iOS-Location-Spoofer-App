//
//  LiquidGlassWebMapView.swift
//  StikDebug
//

import SwiftUI
import WebKit
import CoreLocation

struct LiquidGlassWebMapView: UIViewRepresentable {
    let targetURL: URL?
    @Binding var reloadTrigger: Bool
    var onLocationInjected: ((Double, Double, Double?, Bool) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "injectLocation")

        // Auto-hook into the "锁定" button & /set API call
        let hookScript = """
        (function() {
            function notifyNative(lat, lng, alt, jitter) {
                if (lat != null && lng != null && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.injectLocation) {
                    window.webkit.messageHandlers.injectLocation.postMessage({
                        latitude: Number(lat),
                        longitude: Number(lng),
                        altitude: alt != null ? Number(alt) : 0,
                        jitter: Boolean(jitter)
                    });
                }
            }

            document.addEventListener('click', function(e) {
                var target = e.target;
                while (target && target !== document.body) {
                    if (target.id === 'btn-lock') {
                        setTimeout(function() {
                            try {
                                var altEl = document.getElementById('inp-alt');
                                var altVal = (altEl && altEl.value) ? parseFloat(altEl.value) : (window.altitude || 0);
                                if (window.WGS && window.WGS.lat != null && window.WGS.lng != null) {
                                    notifyNative(window.WGS.lat, window.WGS.lng, altVal, window.isJitterEnabled !== false);
                                }
                            } catch(err) {}
                        }, 50);
                        break;
                    }
                    target = target.parentElement;
                }
            }, true);

            var origFetch = window.fetch;
            window.fetch = function(url, options) {
                try {
                    if (typeof url === 'string' && url.indexOf('/set') !== -1 && options && options.body) {
                        var data = JSON.parse(options.body);
                        if (data.latitude != null && data.longitude != null) {
                            notifyNative(data.latitude, data.longitude, data.altitude, data.jitter !== false);
                        }
                    }
                } catch(e) {}
                return origFetch.apply(this, arguments);
            };
        })();
        """

        let userScript = WKUserScript(source: hookScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(userScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        loadContent(in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            loadContent(in: uiView)
        }
    }

    private func loadContent(in webView: WKWebView) {
        if let targetURL {
            let request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            webView.load(request)
        } else if let localURL = Bundle.main.url(forResource: "web_spoofer_index", withExtension: "html") {
            webView.loadFileURL(localURL, allowingReadAccessTo: localURL.deletingLastPathComponent())
        } else {
            // Fallback placeholder
            let html = "<html style='background:#111;color:#fff;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100%;'><body><h2>Web Spoofer Loaded</h2></body></html>"
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: LiquidGlassWebMapView
        var lastReloadTrigger: Bool

        init(_ parent: LiquidGlassWebMapView) {
            self.parent = parent
            self.lastReloadTrigger = parent.reloadTrigger
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "injectLocation" else { return }
            guard let dict = message.body as? [String: Any] else { return }

            let lat = (dict["latitude"] as? NSNumber)?.doubleValue ?? (dict["lat"] as? NSNumber)?.doubleValue
            let lng = (dict["longitude"] as? NSNumber)?.doubleValue ?? (dict["lng"] as? NSNumber)?.doubleValue
            let alt = (dict["altitude"] as? NSNumber)?.doubleValue
            let jitter = (dict["jitter"] as? NSNumber)?.boolValue ?? true

            if let lat, let lng {
                parent.onLocationInjected?(lat, lng, alt, jitter)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // If remote URL failed (offline/no network), gracefully fallback to bundled index.html
            if let localURL = Bundle.main.url(forResource: "web_spoofer_index", withExtension: "html") {
                webView.loadFileURL(localURL, allowingReadAccessTo: localURL.deletingLastPathComponent())
            }
        }
    }
}
