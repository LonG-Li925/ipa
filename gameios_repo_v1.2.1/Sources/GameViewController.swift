//
//  GameViewController.swift
//  WKWebView 外壳，支持两种包，代码自动判断：
//    · 包内有 resources/web/wz.html（离线大包）→ 起本地 HTTP 服务读本地资源
//    · 包内没有（联网小包）                    → 直接加载服务器地址
//

import UIKit
import WebKit

final class GameViewController: UIViewController {

    /// 联网版（lite 包）使用的服务器地址。
    /// 打包成离线大包时 App 内自带 web/ 目录，这个常量不会被用到。
    static let remoteURL = "http://36.134.112.211:951/wz.html"

    private var webView: WKWebView!
    private var spinner: UIActivityIndicatorView!
    /// 允许站内跳转的 host，站外链接交给 Safari
    private var selfHost: String = "127.0.0.1"

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        let bounds = view.bounds
        webView = WKWebView(frame: bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)

        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                    .flexibleLeftMargin, .flexibleRightMargin]
        spinner.startAnimating()
        view.addSubview(spinner)

        startLocalServer()
    }

    // MARK: - 启动
    //
    // 两种运行方式，代码自动判断：
    //   · bundle 里有 web/wz.html  → 离线包，起本地 HTTP 服务读 App 内资源
    //   · bundle 里没有            → 联网版，直接加载服务器地址

    private func startLocalServer() {
        guard let resourceURL = Bundle.main.resourceURL else {
            loadRemote()
            return
        }
        let root = resourceURL.appendingPathComponent("web")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("wz.html").path) else {
            print("[app] 包内无 web/ 资源，走联网模式")
            loadRemote()
            return
        }

        LocalHTTPServer.shared.start(rootURL: root) { [weak self] port in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/wz.html") else {
                    self.showFatal("本地服务启动失败")
                    return
                }
                self.selfHost = "127.0.0.1"
                print("[app] loading \(url.absoluteString)")
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                self.webView.load(req)
            }
        }
    }

    private func loadRemote() {
        guard let url = URL(string: GameViewController.remoteURL) else {
            showFatal("服务器地址无效")
            return
        }
        selfHost = url.host ?? ""
        print("[app] loading remote \(url.absoluteString)")
        var req = URLRequest(url: url)
        req.cachePolicy = .useProtocolCachePolicy
        req.timeoutInterval = 60
        webView.load(req)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    // MARK: - 启动

    private func showFatal(_ message: String) {
        spinner.stopAnimating()
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15)
        label.frame = view.bounds.insetBy(dx: 30, dy: 0)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
        print("[app] FATAL \(message)")
    }
}

// MARK: - 导航

extension GameViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[app] didFinish")
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[app] didFail \(error)")
        spinner.stopAnimating()
        promptRetry(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[app] didFailProvisional \(error)")
        spinner.stopAnimating()
        promptRetry(error)
    }

    /// 加载失败给一个重试入口（联网版在弱网下很常见，不给按钮玩家只能杀进程）
    private func promptRetry(_ error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return }   // 被新请求取消，不算失败
        let alert = UIAlertController(
            title: "加载失败",
            message: "网络不稳或服务器繁忙，点「重试」再试一次。\n(\(code))",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.spinner.startAnimating()
            if self.selfHost == "127.0.0.1" {
                self.webView.reload()
            } else {
                self.loadRemote()
            }
        })
        present(alert, animated: true, completion: nil)
    }

    /// 内存吃紧被系统回收时自动重载（Cocos 大场景在低端机上有概率触发）
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("[app] web content process terminated -> reload")
        webView.reload()
    }

    /// 站外链接（充值/客服/协议）交给系统 Safari 打开
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let host = url.host,
           host != selfHost {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - JS 弹窗（不实现的话 window.alert/confirm 会被静默吞掉）

extension GameViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default) { _ in completionHandler() })
        present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true, completion: nil)
    }
}
