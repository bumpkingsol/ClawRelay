import Foundation

enum SocketCommand: Equatable {
    case stop
    case status
    case pause
    case resume
    case unknown

    static func parse(_ input: String) -> SocketCommand {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "STOP": return .stop
        case "STATUS": return .status
        case "PAUSE": return .pause
        case "RESUME": return .resume
        default: return .unknown
        }
    }
}

final class SocketServer {
    private let path: String
    private var fileDescriptor: Int32 = -1
    private var running = false
    var onCommand: ((SocketCommand) -> String)?

    init(path: String = Config.socketPath) {
        self.path = path
    }

    func start() throws {
        // Remove stale socket
        unlink(path)

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "SocketServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        // Verify path fits in sockaddr_un.sun_path (104 bytes on macOS)
        guard path.utf8.count < 104 else {
            close(fileDescriptor)
            throw NSError(domain: "SocketServer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Socket path too long (\(path.utf8.count) bytes, max 103)"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(sunPathSize, path.count + 1))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw NSError(domain: "SocketServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to bind: \(String(cString: strerror(errno)))"])
        }

        listen(fileDescriptor, 5)
        running = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let clientFd = accept(fileDescriptor, nil, nil)
            guard clientFd >= 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead > 0 {
                let input = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                let command = SocketCommand.parse(input)
                let response = onCommand?(command) ?? "{\"error\": \"no handler\"}"
                write(clientFd, response, response.utf8.count)
            }
            close(clientFd)
        }
    }
}
