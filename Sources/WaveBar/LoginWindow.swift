import AppKit
import WebKit

/// Opens the Yandex OAuth page and catches the access token from the redirect.
final class LoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = LoginWindow()

    private static let authURL = URL(string:
        "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d")!

    private var window: NSWindow?
    private var webView: WKWebView?
    private var urlObservation: NSKeyValueObservation?
    private var onToken: ((String) -> Void)?

    func show(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        webView.navigationDelegate = self
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            if let url = view.url { self?.handle(url) }
        }
        webView.load(URLRequest(url: Self.authURL))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Вход в Яндекс"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.webView = webView
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, handle(url) {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    @discardableResult
    private func handle(_ url: URL) -> Bool {
        guard let fragment = url.fragment, fragment.contains("access_token=") else { return false }
        let params = URLComponents(string: "?" + fragment)?.queryItems ?? []
        guard let token = params.first(where: { $0.name == "access_token" })?.value, !token.isEmpty else { return false }
        let callback = onToken
        onToken = nil
        DispatchQueue.main.async { [weak self] in
            callback?(token)
            self?.window?.close()
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        urlObservation = nil
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
    }

    static func clearCookies() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}
