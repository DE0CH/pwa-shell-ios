import SafariServices
import UIKit
import WebKit

/// The whole app: one full-screen web view on the site, plus native overlays for signing in and for
/// a page that could not load.
final class ShellViewController: UIViewController {
    private(set) var webView: WKWebView!
    private let signIn = AccessSignIn()
    private let signInView = MessageOverlay()
    private let errorView = MessageOverlay()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let toast = UILabel()
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var hasLoaded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "PWAShell/1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        // The page lays itself out with env(safe-area-inset-*) (viewport-fit=cover); the scroll view must
        // not add the insets a second time.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityIdentifier = "shell-webview"
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        signInView.configure(title: Config.appName, message: L("signin.message"), button: L("signin.button"),
                             buttonID: "signin-button") { [weak self] in self?.startSignIn() }
        errorView.configure(title: L("error.title"), message: "", button: L("error.retry"),
                            buttonID: "retry-button") { [weak self] in self?.reload() }
        for overlay in [signInView, errorView] {
            overlay.isHidden = true
            overlay.pin(in: view)
        }

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = UIColor.label.withAlphaComponent(0.85)
        toast.textColor = .systemBackground
        toast.font = .preferredFont(forTextStyle: .subheadline)
        toast.numberOfLines = 0
        toast.textAlignment = .center
        toast.layer.cornerRadius = 10
        toast.clipsToBounds = true
        toast.alpha = 0
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        spinner.startAnimating()
        webView.load(URLRequest(url: Config.siteURL))
    }

    // MARK: - Loading

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        reload()
    }

    private func reload() {
        errorView.isHidden = true
        signInView.isHidden = true
        if webView.url == nil || !hasLoaded || webView.url.map({ !Config.isInternal($0) }) == true {
            webView.load(URLRequest(url: Config.siteURL))
        } else {
            webView.reload()
        }
    }

    /// Coming back to the app after the site's session cookie expired: the page's own requests would
    /// fail, so reload it; Access then renews the cookie silently (or asks to sign in).
    @objc private func didBecomeActive() {
        guard hasLoaded, signInView.isHidden else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let host = Config.siteHost
            let valid = cookies.contains { c in
                c.name == "CF_Authorization" && c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
                    && (c.expiresDate.map { $0 > Date().addingTimeInterval(60) } ?? true)
            }
            if !valid { self?.reload() }
        }
    }

    // MARK: - Sign-in

    private func showSignIn() {
        spinner.stopAnimating()
        webView.scrollView.refreshControl?.endRefreshing()
        errorView.isHidden = true
        signInView.setMessage(L("signin.message"))
        signInView.isHidden = false
    }

    private func startSignIn() {
        signInView.setBusy(true)
        signIn.start(from: view.window) { [weak self] result in
            guard let self else { return }
            self.signInView.setBusy(false)
            switch result {
            case .success(let tokens):
                let store = self.webView.configuration.websiteDataStore.httpCookieStore
                let cookies = AccessSignIn.cookies(for: tokens, site: Config.siteURL)
                let group = DispatchGroup()
                for cookie in cookies {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    self.signInView.isHidden = true
                    self.spinner.startAnimating()
                    self.webView.load(URLRequest(url: Config.siteURL))
                }
            case .failure(let error):
                if let message = (error as? LocalizedError)?.errorDescription {
                    self.signInView.setMessage(L("signin.message") + "\n\n" + message)
                } else if !(error is AccessSignIn.SignInError) {
                    self.signInView.setMessage(L("signin.message") + "\n\n" + error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Files and links

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func share(_ file: URL) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        topPresented().present(sheet, animated: true)
    }

    private func topPresented() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        return top
    }

    private func showToast(_ text: String) {
        toast.text = "  " + text + "  "
        UIView.animate(withDuration: 0.2) { self.toast.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 3, options: []) { self.toast.alpha = 0 }
    }
}

// MARK: - WKNavigationDelegate

extension ShellViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        switch scheme {
        case "about", "blob", "data":
            decisionHandler(.allow)
        case "http", "https":
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if Config.isInternal(url) || !mainFrame {
                decisionHandler(.allow)
            } else {
                // A link to another site: Safari, not the app's web view.
                openExternally(url)
                decisionHandler(.cancel)
            }
        default:
            // mailto:, tel:, maps: and other apps' links.
            openExternally(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        if navigationResponse.isForMainFrame, let host = response.url?.host?.lowercased(), Config.isAccessHost(host) {
            // Access shows its login page: the session (org token) is gone. Sign in natively.
            decisionHandler(.cancel)
            showSignIn()
            return
        }
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        spinner.stopAnimating()
        webView.scrollView.refreshControl?.endRefreshing()
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        spinner.stopAnimating()
        webView.scrollView.refreshControl?.endRefreshing()
        let ns = error as NSError
        // Cancelled navigations (our own policy decisions) and "frame load interrupted" (a navigation
        // that became a download) are not failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        guard signInView.isHidden else { return }
        errorView.setMessage(L("error.message") + "\n\n" + ns.localizedDescription)
        errorView.isHidden = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

// MARK: - WKDownloadDelegate

extension ShellViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let destination = dir.appendingPathComponent(name)
        downloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        showToast(L("download.failed"))
    }
}

// MARK: - WKUIDelegate

extension ShellViewController: WKUIDelegate {
    /// window.open / target=_blank: other sites go to Safari; the site's own pages open in a sheet
    /// that shares the session (a plain Safari view would not have the Access cookie).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", !Config.isInternal(url) {
            openExternally(url)
            return nil
        }
        let popup = PopupViewController(configuration: configuration, delegateHost: self)
        topPresented().present(UINavigationController(rootViewController: popup), animated: true)
        return popup.webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("ok"), style: .default) { _ in completionHandler() })
        topPresented().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: L("ok"), style: .default) { _ in completionHandler(true) })
        topPresented().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: L("ok"), style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        topPresented().present(alert, animated: true)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView !== self.webView { topPresented().dismiss(animated: true) }
    }
}

/// A page the site opened in a new window, shown as a sheet with a Done button.
final class PopupViewController: UIViewController {
    let webView: WKWebView
    private weak var delegateHost: ShellViewController?

    init(configuration: WKWebViewConfiguration, delegateHost: ShellViewController) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.delegateHost = delegateHost
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = delegateHost
        webView.uiDelegate = delegateHost
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }
}
