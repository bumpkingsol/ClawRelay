import Foundation

struct SessionPaths {
    let id: String
    let rootDir: String
    let audioPath: String
    let framesDir: String
}

final class SessionStore {
    let baseDir: String
    let maxAgeDays: Int

    init(baseDir: String = Config.sessionDir, maxAgeDays: Int = 30) {
        self.baseDir = baseDir
        self.maxAgeDays = maxAgeDays
    }

    func createSession(id: String) throws -> SessionPaths {
        let sessionDir = "\(baseDir)/\(id)"
        let framesDir = "\(sessionDir)/frames"
        let audioPath = "\(sessionDir)/audio.wav"

        try FileManager.default.createDirectory(
            atPath: framesDir,
            withIntermediateDirectories: true
        )

        return SessionPaths(
            id: id,
            rootDir: sessionDir,
            audioPath: audioPath,
            framesDir: framesDir
        )
    }

    func cleanupOldSessions() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir) else { return }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays * 86400))
        let contents = try fm.contentsOfDirectory(atPath: baseDir)

        for name in contents {
            let path = "\(baseDir)/\(name)"
            let attrs = try fm.attributesOfItem(atPath: path)
            if let created = attrs[.creationDate] as? Date, created < cutoff {
                try fm.removeItem(atPath: path)
            }
        }
    }
}
