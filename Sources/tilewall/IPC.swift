import Foundation
import TilewallCore

/// One request line in, one text reply out, over a Unix socket in the tilewall home directory.
enum IPC {
    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Paths.socket.path
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        return addr
    }

    private static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        guard var addr = address() else { return nil }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Sends a command to the running daemon. Returns nil when no daemon answers.
    static func send(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard withAddress({ connect(fd, $0, $1) }) == 0 else { return nil }
        let line = Array((command + "\n").utf8)
        guard write(fd, line, line.count) == line.count else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Serves commands forever on background threads. The handler runs on the main thread.
    static func serve(handler: @escaping (String, @escaping (String) -> Void) -> Void) throws {
        try FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        unlink(Paths.socket.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let bound = withAddress({ bind(fd, $0, $1) }) else {
            throw NSError(domain: "tilewall", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path is too long: \(Paths.socket.path)"])
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            throw NSError(domain: "tilewall", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot listen on \(Paths.socket.path): \(String(cString: strerror(errno)))"])
        }
        chmod(Paths.socket.path, 0o600)
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                // Each client gets its own thread, so a slow command or a silent client cannot block the others.
                DispatchQueue.global(qos: .userInitiated).async { answer(client, handler: handler) }
            }
        }
    }

    private static func answer(_ client: Int32, handler: @escaping (String, @escaping (String) -> Void) -> Void) {
        defer { close(client) }
        var patience = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var complete = false
        while bytes.count < 4096, read(client, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { complete = true; break }
            bytes.append(byte)
        }
        // No full line within the timeout: not a tilewall client, or one that died.
        guard complete else { return }
        let command = String(decoding: bytes, as: UTF8.self)
        let finished = DispatchSemaphore(value: 0)
        var reply = ""
        DispatchQueue.main.async {
            handler(command) {
                reply = $0
                finished.signal()
            }
        }
        finished.wait()
        let out = Array((reply + "\n").utf8)
        _ = write(client, out, out.count)
    }
}
