import Foundation
import WebKit

/// JSwift – sync + async JavaScript execution with natural `returnToSwift value` syntax
public final class JSwift {
    private static let engine = JSEngine()

    // MARK: - Synchronous (blocks until returnToSwift is called)
    public static func execute<T>(_ js: String) -> T {
        print("🔵 JSwift.execute() started")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        var executionError: Error?
        var timedOut = false

        Task {
            print("🔵 Task started")
            do {
                let value = try await engine.evaluate(js)
                print("🔵 Engine returned value: \(value)")
                result = value
            } catch {
                print("🔵 Engine returned error: \(error)")
                executionError = error
            }
            
            if !timedOut {
                semaphore.signal()
                print("🔵 Semaphore signaled")
            }
        }

        print("🔵 Waiting for semaphore...")
        
        // Add a 30-second timeout to prevent permanent hanging
        let timeoutResult = semaphore.wait(timeout: .now() + 30.0)
        
        if timeoutResult == .timedOut {
            timedOut = true
            print("🔴 JSwift execution timed out after 30 seconds")
            fatalError("JSwift JavaScript execution timed out after 30 seconds")
        }
        
        print("🔵 Semaphore passed")

        if let error = executionError {
            print("🔵 Throwing fatal error: \(error)")
            fatalError("JSwift JavaScript error: \(error.localizedDescription)")
        }

        print("🔵 Returning result: \(String(describing: result))")
        return result as! T
    }

    // Non-generic overload that returns Any
    public static func execute(_ js: String) -> Any {
        return JSwift.execute<Any>(js)
    }

    // MARK: - Async/Await
    public static func executeAsync<T: Decodable>(_ js: String) async throws -> T {
        let value = try await engine.evaluate(js)
        if let v = value as? T { return v }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // Non-generic async version that returns Any
    public static func executeAsync(_ js: String) async throws -> Any {
        return try await engine.evaluate(js)
    }
}

/// Engine that manages WKWebView and continuation handling.
private final class JSEngine: NSObject {
    private let webView: WKWebView
    /// pending continuations keyed by UUID
    private var pending: [UUID: CheckedContinuation<Any, Error>] = [:]
    /// serial queue to protect `pending`
    private let pendingQueue = DispatchQueue(label: "com.jswift.pending")
    
    private var isWebViewLoaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        print("🟡 JSEngine init started")
        // Build configuration + user content controller
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        let bridgeScript = """
        (function() {
            // Store the current callback ID
            window.__jswift_current_id = null;
            
            // Define returnToSwift function
            window.returnToSwift = function(value) {
                if (window.__jswift_current_id) {
                    webkit.messageHandlers.jswift.postMessage({
                        id: window.__jswift_current_id,
                        value: value
                    });
                }
            };
            
            // Also make it available as a property setter for compatibility
            Object.defineProperty(window, 'returnToSwift', {
                set: function(value) {
                    if (window.__jswift_current_id) {
                        webkit.messageHandlers.jswift.postMessage({
                            id: window.__jswift_current_id,
                            value: value
                        });
                    }
                },
                get: function() { 
                    return function(value) {
                        if (window.__jswift_current_id) {
                            webkit.messageHandlers.jswift.postMessage({
                                id: window.__jswift_current_id,
                                value: value
                            });
                        }
                    };
                }
            });
        })();
        """
        
        let userScript = WKUserScript(
            source: bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)

        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true

        self.webView = wv

        super.init()

        // Add message handler
        let handler = SwiftMessageHandler(engine: self)
        controller.add(handler, name: "jswift")

        // Load a blank page
        print("🟡 Loading blank page into WKWebView...")
        wv.loadHTMLString("""
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <title>JSwift</title>
            </head>
            <body>
                <script>
                    console.log('JSwift environment loaded');
                </script>
            </body>
            </html>
        """, baseURL: nil)
        
        wv.navigationDelegate = self
        print("🟡 JSEngine init completed")
    }

    /// Evaluate JS and return result when `returnToSwift` is invoked from JS.
    func evaluate(_ js: String) async throws -> Any {
        print("🟡 JSEngine.evaluate() called")
        
        // Wait for webview to load if needed
        if !isWebViewLoaded {
            print("🟡 Waiting for webview to load...")
            try await waitForLoad()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            print("🟡 Created UUID: \(id)")
            
            pendingQueue.sync {
                self.pending[id] = continuation
                print("🟡 Stored continuation for \(id), pending count: \(self.pending.count)")
            }

            let wrapped = """
            (function() {
                window.__jswift_current_id = '\(id.uuidString)';
                try {
                    \(js)
                } catch(e) {
                    console.error('JSwift JS Error:', e);
                    if (window.__jswift_current_id) {
                        webkit.messageHandlers.jswift.postMessage({
                            id: window.__jswift_current_id,
                            error: e && (e.message || String(e)) || String(e)
                        });
                    }
                }
            })();
            """

            print("🟡 Wrapped script length: \(wrapped.count) characters")
            
            DispatchQueue.main.async {
                print("🟡 Evaluating JavaScript on main thread...")
                self.webView.evaluateJavaScript(wrapped) { jsResult, jsError in
                    print("🟡 evaluateJavaScript completion handler called")
                    if let jsError = jsError {
                        print("🟡 JavaScript evaluation error: \(jsError)")
                        self.pendingQueue.sync {
                            if let cont = self.pending[id] {
                                self.pending.removeValue(forKey: id)
                                print("🟡 Removed pending continuation due to error")
                                cont.resume(throwing: jsError)
                            }
                        }
                    } else {
                        print("🟡 JavaScript evaluation completed without immediate error, result: \(String(describing: jsResult))")
                        // Don't resume here - wait for returnToSwift to be called
                    }
                }
            }
        }
    }
    
    private func waitForLoad() async throws {
        print("🟡 waitForLoad() called")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            
            // If it's already loaded, resume immediately
            if isWebViewLoaded {
                continuation.resume()
                return
            }
            
            // Set a timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if let cont = self.loadContinuation {
                    self.loadContinuation = nil
                    cont.resume(throwing: NSError(domain: "JSEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView load timeout"]))
                }
            }
        }
    }

    /// Called by message handler when JS posts a value
    fileprivate func handle(id: UUID, value: Any?) {
        print("🟢 Message handler received value: \(String(describing: value)) for id: \(id)")
        pendingQueue.async {
            guard let cont = self.pending[id] else { 
                print("🔴 No pending continuation found for id: \(id)")
                return 
            }
            self.pending.removeValue(forKey: id)
            print("🟢 Resuming continuation with value, remaining pending: \(self.pending.count)")
            cont.resume(returning: value ?? NSNull())
        }
    }

    /// Called by message handler when JS posts an error
    fileprivate func handle(id: UUID, error: String) {
        print("🔴 Message handler received error: \(error) for id: \(id)")
        pendingQueue.async {
            guard let cont = self.pending[id] else { 
                print("🔴 No pending continuation found for error id: \(id)")
                return 
            }
            self.pending.removeValue(forKey: id)
            let nsErr = NSError(domain: "JSwift", code: -1, userInfo: [NSLocalizedDescriptionKey: error])
            print("🟢 Resuming continuation with error, remaining pending: \(self.pending.count)")
            cont.resume(throwing: nsErr)
        }
    }
    
    fileprivate func webViewDidFinishLoad() {
        print("🟢 WebView finished loading")
        isWebViewLoaded = true
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume()
        }
    }
}

extension JSEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("🟢 WKNavigationDelegate: webView didFinish navigation")
        webViewDidFinishLoad()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("🔴 WKNavigationDelegate: webView didFail with error: \(error)")
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: error)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("🔴 WKNavigationDelegate: webView didFailProvisionalNavigation with error: \(error)")
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: error)
        }
    }
}

/// Message handler that forwards messages into the engine.
/// Holds a weak reference to JSEngine to avoid retain cycles (WKUserContentController retains the handler).
private final class SwiftMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var engine: JSEngine?

    init(engine: JSEngine) {
        self.engine = engine
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        print("🟢 Message handler received message: \(message.name)")
        guard message.name == "jswift" else { return }
        guard let body = message.body as? [String: Any] else {
            print("🔴 Invalid message body: \(message.body)")
            return
        }
        
        print("🟢 Message body: \(body)")
        
        guard let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr) else {
            print("🔴 Invalid ID in message: \(body)")
            return
        }

        if let err = body["error"] as? String {
            engine?.handle(id: id, error: err)
        } else {
            engine?.handle(id: id, value: body["value"])
        }
    }
}
