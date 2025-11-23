import Foundation
import WebKit

/// JSwift – sync + async JavaScript execution with natural `returnToSwift value` syntax
public final class JSwift {
    private static let engine = JSEngine()

    // MARK: - Synchronous (blocks until returnToSwift is called)
    public static func execute<T = Any>(_ js: String) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        var executionError: Error?

        Task {
            do {
                let value = try await engine.evaluate(js)
                result = value
            } catch {
                executionError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let error = executionError {
            fatalError("JSwift JavaScript error: \(error.localizedDescription)")
        }

        // Force-cast because the API is intentionally ergonomic; caller may request a concrete T.
        return result as! T
    }

    // MARK: - Async/Await
    public static func executeAsync<T: Decodable>(_ js: String) async throws -> T {
        let value = try await engine.evaluate(js)
        if let v = value as? T { return v }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}


/// Engine that manages WKWebView and continuation handling.
private final class JSEngine: NSObject {
    private let webView: WKWebView
    /// pending continuations keyed by UUID
    private var pending: [UUID: CheckedContinuation<Any, Error>] = [:]
    /// serial queue to protect `pending`
    private let pendingQueue = DispatchQueue(label: "com.jswift.pending")

    override init() {
        // Build configuration + user content controller
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        let bridgeScript = """
        (function() {
            const send = v => webkit.messageHandlers.jswift.postMessage({
                id: window.__jswift_id,
                value: v
            });
            Object.defineProperty(window, 'returnToSwift', {
                set: send,
                get: () => { throw 'returnToSwift is write-only' }
            });
        })();
        """
        controller.addUserScript(WKUserScript(
            source: bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true

        self.webView = wv

        super.init()

        // Add message handler (weakly referencing this engine to avoid retain cycle)
        let handler = SwiftMessageHandler(engine: self)
        controller.add(handler, name: "jswift")

        // Load a tiny blank page so evaluateJavaScript will have a context.
        wv.loadHTMLString("<script></script>", baseURL: nil)
    }

    /// Evaluate JS and return result when `returnToSwift` is invoked from JS.
    func evaluate(_ js: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            // store continuation
            pendingQueue.sync {
                self.pending[id] = continuation
            }

            // Wrap script so it sets an identifier and reports exceptions directly
            let wrapped = """
            (function() {
                window.__jswift_id = '\(id.uuidString)';
                try { \(js) } catch(e) {
                    webkit.messageHandlers.jswift.postMessage({
                        id: '\(id.uuidString)',
                        error: e && (e.message || String(e)) || String(e)
                    });
                }
            })();
            """

            // Must run JS on main thread
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(wrapped) { _, jsError in
                    if let jsError = jsError {
                        // If evaluateJavaScript returned an immediate error, resume and remove continuation
                        self.pendingQueue.sync {
                            if let cont = self.pending[id] {
                                self.pending.removeValue(forKey: id)
                                cont.resume(throwing: jsError)
                            }
                        }
                    }
                    // otherwise: do nothing — the JS is expected to call `returnToSwift` which triggers the message handler.
                }
            }
        }
    }

    /// Called by message handler when JS posts a value
    fileprivate func handle(id: UUID, value: Any?) {
        pendingQueue.async {
            guard let cont = self.pending[id] else { return }
            self.pending.removeValue(forKey: id)
            cont.resume(returning: value ?? NSNull())
        }
    }

    /// Called by message handler when JS posts an error
    fileprivate func handle(id: UUID, error: String) {
        pendingQueue.async {
            guard let cont = self.pending[id] else { return }
            self.pending.removeValue(forKey: id)
            let nsErr = NSError(domain: "JSwift", code: -1, userInfo: [NSLocalizedDescriptionKey: error])
            cont.resume(throwing: nsErr)
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
        guard let body = message.body as? [String: Any],
              let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr) else { return }

        if let err = body["error"] as? String {
            engine?.handle(id: id, error: err)
        } else {
            engine?.handle(id: id, value: body["value"])
        }
    }
}
