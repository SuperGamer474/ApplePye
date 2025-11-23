// Sources/JSwift/JSwift.swift
import WebKit
import Foundation

public enum JSwift {
    private static let engine = JSEngine()

    // MARK: - Synchronous
    public static func execute<T>(_ js: String) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        var error: Error?

        Task {
            do {
                let value = try await engine.evaluate(js)
                result = value as? T ?? (value as! T)
            } catch {
                error = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let error = error {
            fatalError("JSwift error: \(error.localizedDescription)")
        }
        return result
    }

    // MARK: - Async/Await
    public static func executeAsync<T: Decodable>(_ js: String) async throws -> T {
        let value = try await engine.evaluate(js)
        if let value = value as? T { return value }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Actor Engine (Fixed: no use of 'self' during init)

private actor JSEngine {
    private let webView: WKWebView
    private var pending: [UUID: CheckedContinuation<Any, Error>] = [:]

    init() {
        // Step 1: Create config and controller
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // Step 2: Inject returnToSwift bridge
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

        // Step 3: Create web view
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true

        // Step 4: NOW assign all stored properties (no 'self' used yet!)
        self.webView = wv

        // Step 5: Create handler AFTER all properties are initialized
        let handler = SwiftMessageHandler(engine: self)
        controller.add(handler, name: "jswift")

        // Step 6: Load blank page to initialize JS context
        wv.loadHTMLString("<script></script>", baseURL: nil)
    }

    func evaluate(_ js: String) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            let id = UUID()
            pending[id] = cont

            let wrapped = """
            (function() {
                window.__jswift_id = '\(id.uuidString)';
                try { \(js) } catch(e) {
                    webkit.messageHandlers.jswift.postMessage({
                        id: '\(id.uuidString)',
                        error: e.message || String(e)
                    });
                }
            })();
            """

            webView.evaluateJavaScript(wrapped) { _, error in
                if let error = error {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func handle(id: UUID, value: Any?) {
        pending[id]?.resume(returning: value ?? NSNull())
        pending.removeValue(forKey: id)
    }

    func handle(id: UUID, error: String) {
        pending[id]?.resume(throwing: NSError(
            domain: "JSwift",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: error]
        ))
        pending.removeValue(forKey: id)
    }
}

// MARK: - Message Handler (weak to avoid retain cycle)

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
