public final class ApplePye {
    public static let shared = ApplePye()

    private var initialized = false

    private init() {
        initializeIfNeeded()
    }

    private func initializeIfNeeded() {
        if !initialized {
            applepye_initialize()
            initialized = true
        }
    }

    deinit {
        // optional: applepye_finalize()
    }

    // Instance method stays private or internal if you want
    private func executeInstance(_ code: String) -> String {
        initializeIfNeeded()
        let outPtr = code.withCString { cstr -> UnsafeMutablePointer<CChar>? in
            let res = applepye_execute(cstr)
            return UnsafeMutablePointer(mutating: res)
        }

        defer {
            if let p = outPtr {
                free(p)
            }
        }

        if let p = outPtr {
            return String(cString: p)
        } else {
            return ""
        }
    }

    // New public static method delegates to shared instance
    public static func execute(_ code: String) -> String {
        return shared.executeInstance(code)
    }
}
