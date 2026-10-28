import Foundation

/// Keeps each run's error output and crash backtrace in Documents/Crash Logs, readable in the Files app.
enum CrashLog {
    private static var fd: Int32 = -1

    static func start() {
        let dir = URL.documentsDirectory.appending(path: "Crash Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appending(path: "last-run.txt")
        let previous = dir.appending(path: "previous-run.txt")
        // a run that ended in a crash is kept aside, a clean one is dropped
        if let text = try? String(contentsOf: current, encoding: .utf8), text.contains("CRASH") {
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: current, to: previous)
        }
        guard freopen(current.path, "w", stderr) != nil else { return }
        setvbuf(stderr, nil, _IONBF, 0)
        fd = fileno(stderr)
        let info = Bundle.main.infoDictionary
        fputs("Inkwell \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), \(Date())\n", stderr)

        NSSetUncaughtExceptionHandler { exception in
            fputs("CRASH exception \(exception.name.rawValue): \(exception.reason ?? "")\n", stderr)
            fputs(exception.callStackSymbols.joined(separator: "\n") + "\n", stderr)
        }
        for sig in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { sig in
                // not strictly signal-safe, but the app is going down anyway
                fputs("CRASH signal \(sig)\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n", stderr)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}
