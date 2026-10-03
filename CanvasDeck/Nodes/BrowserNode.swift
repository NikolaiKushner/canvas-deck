import AppKit
import CanvasCore
import WebKit

/// A web page in a card: address field, back / forward / reload, the page's
/// title and icon in the card's title bar. Any site, not only previews.
///
/// Every browser card shares the default website data store, so a sign-in
/// in one is a sign-in in all and survives a restart. Far out of view for a
/// while, the page is replaced by a snapshot and unloaded (`unloadIfIdle()`);
/// it comes back when the card does.
final class BrowserNode: NSView, NodeContentView {
    let nodeID: UUID
    private(set) var url: URL?
    var onTitle: ((String) -> Void)?
    var onURL: ((URL) -> Void)?
    var onIcon: ((NSImage?) -> Void)?
    /// A link that asked for a new window.
    var onOpenNewWindow: ((URL) -> Void)?

    private let toolbar = NSView()
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    let address = NSTextField()
    private var web: WKWebView?
    private let snapshot = NSImageView()
    private var observations: [NSKeyValueObservation] = []
    private(set) var isUnloaded = false
    /// No address bar, the page fills the card: the address is in the card's
    /// title bar (App design). ⌘L or a click on it brings the bar back until
    /// the next page. A card without a page starts with the bar out.
    private(set) var isChromeless = true
    private var barRevealed = false
    var onHistoryChange: (() -> Void)?
    var canGoBack: Bool { web?.canGoBack ?? false }

    static let toolbarHeight: CGFloat = 36
    /// Safari's: some sign-in pages turn an unknown WebKit browser away.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init(nodeID: UUID, url: String) {
        self.nodeID = nodeID
        self.url = URL(string: url).flatMap { $0.scheme == nil ? nil : $0 }
        super.init(frame: .zero)
        barRevealed = self.url == nil
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        toolbar.wantsLayer = true
        addSubview(toolbar)
        for (button, symbol, label, action) in [
            (back, "chevron.left", "Back", #selector(goBack)),
            (forward, "chevron.right", "Forward", #selector(goForward)),
            (reload, "arrow.clockwise", "Reload", #selector(reloadOrStop)),
        ] as [(NSButton, String, String, Selector)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = label
            toolbar.addSubview(button)
        }
        address.placeholderString = "Search or enter an address"
        address.font = .systemFont(ofSize: 13)
        address.bezelStyle = .roundedBezel
        address.lineBreakMode = .byTruncatingTail
        address.target = self
        address.action = #selector(go)
        address.cell?.isScrollable = true
        toolbar.addSubview(address)

        snapshot.imageScaling = .scaleAxesIndependently
        snapshot.isHidden = true
        addSubview(snapshot)

        loadWebView()
    }

    required init?(coder: NSCoder) { nil }

    var preferredFirstResponder: NSView? { url == nil ? address : web }

    private func loadWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.customUserAgent = Self.userAgent
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = false
        web.navigationDelegate = self
        web.uiDelegate = self
        web.underPageBackgroundColor = .textBackgroundColor
        addSubview(web, positioned: .below, relativeTo: snapshot)
        self.web = web
        observations = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    if let title = web.title, !title.isEmpty { self?.onTitle?(title) }
                }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.urlChanged(web.url) }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
        ]
        if let url {
            address.stringValue = url.absoluteString
            web.load(URLRequest(url: url))
        } else if let home = BrowserAddress.resolve(Settings.browserHomePage) {
            open(home)
        }
        isUnloaded = false
        updateButtons()
        needsLayout = true
    }

    func open(_ url: URL) {
        if isUnloaded { self.url = url; return reloadAfterUnload() }
        web?.load(URLRequest(url: url))
        address.stringValue = url.absoluteString
    }

    private func urlChanged(_ new: URL?) {
        guard let new else { return }
        url = new
        if window?.firstResponder !== address.currentEditor() { address.stringValue = new.absoluteString }
        onURL?(new)
    }

    func setChromeless(_ chromeless: Bool) {
        guard chromeless != isChromeless else { return }
        isChromeless = chromeless
        barRevealed = false
        needsLayout = true
    }

    private var showsBar: Bool { !isChromeless || barRevealed }

    private func updateButtons() {
        onHistoryChange?()
        back.isEnabled = web?.canGoBack ?? false
        forward.isEnabled = web?.canGoForward ?? false
        let loading = web?.isLoading ?? false
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
        reload.toolTip = loading ? "Stop" : "Reload"
    }

    @objc private func go() {
        guard let url = BrowserAddress.resolve(address.stringValue) else { return }
        if barRevealed {
            barRevealed = false
            needsLayout = true
        }
        open(url)
        window?.makeFirstResponder(web)
    }

    @objc func goBack() { web?.goBack() }
    @objc func goForward() { web?.goForward() }
    @objc func reloadOrStop() {
        guard let web else { return }
        if web.isLoading { web.stopLoading() } else { web.reload() }
    }

    /// After a change made elsewhere (Linear through MCP), show it.
    func reloadPage() { web?.reload() }

    func focusAddress() {
        if isChromeless {
            barRevealed = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    // MARK: Unloading

    /// Memory: a page costs ~230 MB. Far out of view, the card keeps a
    /// picture and drops the page. Pages playing sound are left alone.
    func unloadIfIdle() {
        guard let web, !isUnloaded else { return }
        web.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, state == .none else { return }
                web.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        guard !self.isUnloaded, self.web === web else { return }
                        self.snapshot.image = image
                        self.snapshot.isHidden = image == nil
                        self.url = web.url ?? self.url
                        self.observations = []
                        web.stopLoading()
                        web.removeFromSuperview()
                        self.web = nil
                        self.isUnloaded = true
                    }
                }
            }
        }
    }

    /// The card is in view again: the page loads behind its snapshot.
    func reloadAfterUnload() {
        guard isUnloaded else { return }
        loadWebView()
    }

    // MARK: Layout & keys

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        withEffectiveAppearance { toolbar.layer?.backgroundColor = CanvasPalette.card.cgColor }
        let h = showsBar ? Self.toolbarHeight : 0
        toolbar.isHidden = !showsBar
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        back.frame = CGRect(x: 8, y: 8, width: 22, height: 20)
        forward.frame = CGRect(x: 32, y: 8, width: 22, height: 20)
        reload.frame = CGRect(x: 56, y: 8, width: 22, height: 20)
        address.frame = CGRect(x: 86, y: 6, width: max(0, bounds.width - 94), height: 24)
        let content = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        web?.frame = content
        snapshot.frame = content
    }

    /// ⌘L address, ⌘R reload, ⌘[ / ⌘] history, while the card has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, window.firstResponder === web || window.firstResponder === address.currentEditor() || (window.firstResponder as? NSView)?.isDescendant(of: self) == true else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "l": focusAddress(); return true
        case "r": web?.reload(); return true
        case "[": goBack(); return true
        case "]": goForward(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Icon

    private func fetchIcon() {
        guard let web else { return }
        let script = "(document.querySelector(\"link[rel~='icon'][sizes='32x32']\") || document.querySelector(\"link[rel~='icon']\") || document.querySelector(\"link[rel='apple-touch-icon']\") || {}).href || ''"
        web.evaluateJavaScript(script) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let page = web.url
                let found = (value as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                guard let icon = found ?? page.flatMap({ URL(string: "/favicon.ico", relativeTo: $0)?.absoluteURL }) else {
                    self.onIcon?(nil)
                    return
                }
                URLSession.shared.dataTask(with: icon) { data, _, _ in
                    let image = data.flatMap(NSImage.init(data:))
                    DispatchQueue.main.async { self.onIcon?(image) }
                }.resume()
            }
        }
    }
}

extension BrowserNode: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        snapshot.isHidden = true
        snapshot.image = nil
        fetchIcon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, for: webView)
    }

    private func showError(_ error: Error, for webView: WKWebView) {
        let error = error as NSError
        // A new navigation replaced this one: not a failure.
        guard error.code != NSURLErrorCancelled else { return }
        snapshot.isHidden = true
        let target = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? url?.absoluteString ?? ""
        let message = error.localizedDescription
        let escape: (String) -> String = { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <html><body style="font: 14px -apple-system; color: #57606a; display: flex; align-items: center; justify-content: center; height: 90vh; text-align: center">
        <div><h2 style="color: #1f2328; font-weight: 600">This page could not be opened</h2><p>\(escape(message))</p><p style="font-size: 12px">\(escape(target))</p></div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        address.stringValue = target
    }

    /// `target=_blank` and window.open: a new card next to this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onOpenNewWindow?(url) }
        return nil
    }

    /// Links the browser cannot show (mailto:, app links) go to the system.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "file", "data", "blob"].contains(scheme) { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }
}
