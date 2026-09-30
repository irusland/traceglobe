import SwiftUI
import WebKit

struct GlobeView: NSViewRepresentable {
    let snapshot: String
    let onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(snapshot: snapshot, onSelect: onSelect) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "selectNode")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = NSColor(red: 0.06, green: 0.09, blue: 0.11, alpha: 1)
        if let url = Bundle.main.url(forResource: "globe", withExtension: "html"), let html = try? String(contentsOf: url, encoding: .utf8) { view.loadHTMLString(html, baseURL: nil) }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.snapshot != snapshot { context.coordinator.snapshot = snapshot; context.coordinator.send(to: view) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "selectNode")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var snapshot: String
        var onSelect: (String) -> Void
        var ready = false
        init(snapshot: String, onSelect: @escaping (String) -> Void) { self.snapshot = snapshot; self.onSelect = onSelect }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; send(to: webView) }
        func send(to webView: WKWebView) {
            guard ready, let data = snapshot.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) else { return }
            webView.callAsyncJavaScript("window.traceglobeUpdate(payload)", arguments: ["payload": payload], in: nil, in: .page) { _ in }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let id = message.body as? String, id.count < 256 else { return }
            onSelect(id)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
