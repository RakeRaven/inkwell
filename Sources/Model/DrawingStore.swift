import Foundation
import PencilKit

/// PKDrawings keyed by name, cached in memory and written to disk shortly after edits.
final class DrawingStore {
    private let dir: URL
    private var cache: [String: PKDrawing] = [:]
    private var dirty: Set<String> = []
    private var pendingFlush: DispatchWorkItem?

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        dir.appending(path: "\(key).drawing")
    }

    func drawing(_ key: String) -> PKDrawing {
        if let cached = cache[key] { return cached }
        var drawing = PKDrawing()
        if let data = try? Data(contentsOf: url(key)) {
            if let loaded = try? PKDrawing(data: data) {
                drawing = loaded
            } else {
                // move it aside so the next save doesn't destroy it
                try? FileManager.default.moveItem(at: url(key), to: dir.appending(path: "\(key)-unreadable-\(Int(Date().timeIntervalSince1970)).drawing"))
            }
        }
        cache[key] = drawing
        return drawing
    }

    func set(_ drawing: PKDrawing, for key: String) {
        cache[key] = drawing
        dirty.insert(key)
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func remove(_ key: String) {
        cache[key] = nil
        dirty.remove(key)
        try? FileManager.default.removeItem(at: url(key))
    }

    func flush() {
        pendingFlush?.cancel()
        var failed: Set<String> = []
        for key in dirty {
            guard let drawing = cache[key] else { continue }
            do {
                try drawing.dataRepresentation().write(to: url(key), options: .atomic)
            } catch {
                print("Saving drawing \(key) failed: \(error)")
                failed.insert(key)
            }
        }
        dirty = failed
    }
}
