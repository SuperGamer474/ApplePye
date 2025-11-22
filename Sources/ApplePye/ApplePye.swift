import Foundation
import WebKit
import UIKit

public final class ApplePye: NSObject {
    public static let shared = ApplePye()

    // MARK: - Public API

    /// Asynchronously execute Python code. `completion` is called on an unspecified background queue.
    public static func execute(_ code: String, completion: @escaping (String) -> Void) {
        shared.executeAsync(code: code, completion: completion)
    }

    /// Synchronously execute Python code. Blocks the calling thread until result or timeout.
    /// NOTE: Do NOT call on the main thread — WKWebView requires main-thread interactions. Use background thread or call execute(_:completion:).
    public static func executeSync(_ code: String, timeout: TimeInterval = 10) -> String {
        return shared.executeSync(code: code, timeout: timeout)
    }

    // MARK: - Implementation

    private var webView: WKWebView!
    private var isReady = false
    private var pendingQueue: [(id: String, code: String)] = []
    private var completions: [String: (String) -> Void] = [:]
    private let queueLock = DispatchQueue(label: "com.applepye.lock")
    private let readySemaphore = DispatchSemaphore(value: 0)

    private override init() {
        super.init()
        DispatchQueue.main.async {
            self.setupWebView()
        }
    }

    deinit {
        DispatchQueue.main.async {
            self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "applepye")
            self.webView?.stopLoading()
            self.webView = nil
        }
    }

    // MARK: - Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.userContentController.add(self, name: "applepye")

        // hidden webview (offscreen)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.isHidden = true

        // Keep a strong reference
        self.webView = wv

        // Load the HTML that loads Pyodide from CDN.
        let html = Self.htmlStringForPyodide()
        wv.loadHTMLString(html, baseURL: nil)

        // start a brief timer in case ready message doesn't arrive (optional)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20.0) { [weak self] in
            guard let self = self else { return }
            if !self.isReady {
                // still not ready — signal anyway to avoid infinite blocking in sync call
                self.queueLock.sync {
                    if !self.isReady {
                        self.isReady = true
                        self.readySemaphore.signal()
                    }
                }
            }
        }
    }

    // MARK: - Execute

    private func executeAsync(code: String, completion: @escaping (String) -> Void) {
        let id = UUID().uuidString
        queueLock.sync {
            completions[id] = completion
        }

        // Ensure webview ready
        ensureReady { [weak self] in
            guard let self = self else { return }
            self.sendCodeToWebView(code: code, id: id)
        }
    }

    private func executeSync(code: String, timeout: TimeInterval) -> String {
        if Thread.isMainThread {
            // It's unsafe to block the main thread here because WKWebView callbacks require main thread.
            // We'll still allow it, but warn in logs and attempt to run the operation by dispatching to a background thread.
            assertionFailure("executeSync should not be called from main thread. Use execute(_:completion:) instead.")
        }

        let sem = DispatchSemaphore(value: 0)
        var resultStr = ""

        executeAsync(code: code) { out in
            resultStr = out
            sem.signal()
        }

        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return "/* ApplePye.executeSync timed out after \(timeout) s */"
        }
        return resultStr
    }

    // MARK: - Helpers

    private func ensureReady(readyAction: @escaping () -> Void) {
        queueLock.async {
            if self.isReady {
                readyAction()
            } else {
                // Wait until readySemaphore is signaled, then run
                DispatchQueue.global().async {
                    // Wait with a reasonable timeout in case something fails
                    let _ = self.readySemaphore.wait(timeout: .now() + 20.0)
                    DispatchQueue.main.async {
                        readyAction()
                    }
                }
            }
        }
    }

    private func sendCodeToWebView(code: String, id: String) {
        // Prepare JS-safe code string literal by JSON-encoding it
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [code], options: []),
              let jsonArrayStr = String(data: jsonData, encoding: .utf8),
              let jsStringLiteral = try? JSONSerialization.jsonObject(with: Data(jsonArrayStr.utf8), options: []) as? [String],
              let encoded = jsStringLiteral?.first
        else {
            completeWith(id: id, text: "/* ApplePye: failed to encode code to JSON string */")
            return
        }

        // call runPythonCode(code, id)
        // Note: we call evaluateJavaScript on the main thread
        DispatchQueue.main.async {
            let js = "runPythonCode(\(jsonEncodeString(encoded)), '\(id)');"
            self.webView.evaluateJavaScript(js) { (_, err) in
                if let e = err {
                    self.completeWith(id: id, text: "/* ApplePye: JS eval error: \(e.localizedDescription) */")
                }
            }
        }
    }

    private func completeWith(id: String, text: String) {
        var comp: ((String) -> Void)?
        queueLock.sync {
            comp = completions[id]
            completions.removeValue(forKey: id)
        }
        if let c = comp {
            // call on background queue (callback not guaranteed main)
            DispatchQueue.global().async {
                c(text)
            }
        }
    }

    // Helper to create a JSON-literal string in a safe way
    private func jsonEncodeString(_ s: String) -> String {
        // Return a JS literal like "the string..." properly escaped
        if let d = try? JSONSerialization.data(withJSONObject: s, options: []),
           let lit = String(data: d, encoding: .utf8) {
            return lit
        } else {
            // fallback basic escaping
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
    }

    // HTML loaded into the web view (uses Pyodide CDN for simplicity).
    // If you want to bundle pyodide files locally, replace the <script src=...> with your local file path.
    private static func htmlStringForPyodide() -> String {
        return """
<!doctype html>
<html>
  <head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <script src="https://cdn.jsdelivr.net/pyodide/v0.29.0/full/pyodide.js"></script>
  </head>
  <body>
    <script type="text/javascript">
      // global pyodide
      async function main(){
        try {
          self.pyodide = await loadPyodide();
          // signal ready
          window.webkit.messageHandlers.applepye.postMessage(JSON.stringify({type:'ready'}));
        } catch (err) {
          window.webkit.messageHandlers.applepye.postMessage(JSON.stringify({type:'init_error', error: String(err)}));
        }
      }

      // Run Python code and capture stdout/stderr using an IO buffer wrapper.
      // 'code' is a JS string. 'id' is an identifier that is returned to native.
      async function runPythonCode(code, id) {
        try {
          // Put the code into pyodide globals safely (avoids quoting troubles)
          pyodide.globals.set("__applepye_user_code__", code);

          const wrapper = `
import sys, io
_buf = io.StringIO()
_old_out, _old_err = sys.stdout, sys.stderr
sys.stdout = _buf
sys.stderr = _buf
try:
    # execute user code from JS-provided variable
    exec(__applepye_user_code__)
except Exception:
    import traceback
    traceback.print_exc()
finally:
    sys.stdout = _old_out
    sys.stderr = _old_err
_result = _buf.getvalue()
`;

          let result = await pyodide.runPythonAsync(wrapper);
          // clear the global to free memory
          try { pyodide.globals.delete("__applepye_user_code__"); } catch (e) {}
          window.webkit.messageHandlers.applepye.postMessage(JSON.stringify({type:'result', id:id, result: String(result)}));
        } catch (err) {
          window.webkit.messageHandlers.applepye.postMessage(JSON.stringify({type:'error', id:id, error: String(err)}));
        }
      }

      main();
    </script>
  </body>
</html>
"""
    }
}

// MARK: - WKScriptMessageHandler

extension ApplePye: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // message.body is usually a string because JS posted JSON.stringify(...)
        guard let body = message.body as? String else {
            return
        }
        guard let data = body.data(using: .utf8) else { return }

        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            if let type = obj["type"] as? String {
                switch type {
                case "ready":
                    queueLock.sync {
                        if !isReady {
                            isReady = true
                            readySemaphore.signal()
                        }
                    }
                    // flush any pending queued code if needed (we always call ensureReady before sending)
                    return
                case "init_error":
                    // initialization failed
                    let err = obj["error"] as? String ?? "unknown"
                    // signal ready to unblock waiting callers, but pass error to any queue completions
                    queueLock.sync {
                        if !isReady {
                            isReady = true
                            readySemaphore.signal()
                        }
                    }
                    // no specific queued action in this simplified example
                    return
                case "result", "error":
                    let id = obj["id"] as? String ?? ""
                    let res = (type == "result") ? (obj["result"] as? String ?? "") : (obj["error"] as? String ?? "")
                    completeWith(id: id, text: res)
                    return
                default:
                    return
                }
            }
        }
    }
}
