import WebKit
import Foundation

/// JSwift – run JavaScript with natural `returnToSwift value` syntax
public enum JSwift {
    private static let engine = JSEngine()

    /// Execute JavaScript and get the value passed to `returnToSwift`
    /// Works exactly like you expect: `let x = await JSwift.execute("…")`
    public static func execute<T>(_ javascript: String) async -> T {
        await withCheckedContinuation { continuation in
            engine.evaluate(javascript) { result in
                switch result {
                case .success(let value):
                    // Safely cast – if it fails, we fall back to String representation
                    if let casted = value as? T {
                        continuation.resume(returning: casted)
                    } else if let string = value as? String, let casted = string as? T {
                        continuation.resume(returning: casted)
                    } else {
                        // Last resort: try JSON round-trip for complex objects
                        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                           let decoded = try? JSONDecoder().decode(T.self, from: data) {
                            continuation.resume(returning: decoded)
                        } else {
                            fatalError("JSwift: Could not convert JS result to \(T.self). Got: \(value)")
                        }
                    }
                case .failure(let error):
                    fatalError("JSwift JavaScript error: \(error)")
                }
            }
        }
    }
}

// MARK: - Private Engine (unchanged core, just cleaned up)

private actor JSEngine {
    private let webView: WKWebView
    private var continuations: [UUID: (Result<Any, Error>) -> Void] = [:]

    init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // Magic: makes `returnToSwift value` work without parentheses
        let bridgeScript = """
        (function() {
            const callback = (value) => {
                window.webkit.messageHandlers.jswift.postMessage({
                    id: window.__jswift_id,
                    value: value
                });
            };
            Object.defineProperty(window, 'returnToSwift', {
                set: callback,
                get: () => { throw new Error('returnToSwift is write-only') },
                configurable: false
            });
        })();
        """

        controller.addUserScript(WKUserScript(source: bridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(SwiftMessageHandler(engine: self), name: "jswift")
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true
        self.webView = wv

        wv.loadHTMLString("", baseURL: nil)
    }

    func evaluate(_ js: String, completion: @escaping (Result<Any, Error>) -> Void) {
        let id = UUID()
        continuations[id] = completion

        let wrapped = """
        (function() {
            window.__jswift_id = '\(id.uuidString)';
            try {
                \(js)
            } catch (e) {
                window.webkit.messageHandlers.jswift.postMessage({
                    id: '\(id.uuidString)',
                    error: e.message || String(e)
                });
            }
        })();
        """

        webView.evaluateJavaScript(wrapped)
    }

    func handle(id: UUID, value: Any) {
        continuations[id]?(.success(value))
        continuations.removeValue(forKey: id)
    }

    func handle(id: UUID, error: String) {
        continuations[id]?(.failure(NSError(domain: "JSwift", code: -1, userInfo: [NSLocalizedDescriptionKey: error])))
        continuations.removeValue(forKey: id)
    }
}

private class SwiftMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: JSEngine?

    init(engine: JSEngine) { self.engine = engine }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let idString = body["id"] as? String,
              let id = UUID(uuidString: idString) else { return }

        if let error = body["error"] as? String {
            engine?.handle(id: id, error: error)
        } else if let value = body["value"] {
            engine?.handle(id: id, value: value)
        }
    }
}
