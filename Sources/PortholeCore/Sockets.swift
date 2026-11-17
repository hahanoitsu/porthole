import Darwin
import Foundation

/// An IPv4 or IPv6 socket address.
struct SocketAddress: CustomStringConvertible {
    var storage = sockaddr_storage()
    var length: socklen_t = 0

    init() {}

    init(storage: sockaddr_storage, length: socklen_t) {
        self.storage = storage
        self.length = length
    }

    /// Parses a numeric IPv4 or IPv6 address.
    init?(host: String, port: UInt16) {
        var v4 = sockaddr_in()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: v4, as: sockaddr_in.self) }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            return
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: v6, as: sockaddr_in6.self) }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            return
        }
        return nil
    }

    var family: Int32 { Int32(storage.ss_family) }

    var port: UInt16 {
        withUnsafeBytes(of: storage) { raw in
            switch family {
            case AF_INET: return UInt16(bigEndian: raw.load(as: sockaddr_in.self).sin_port)
            case AF_INET6: return UInt16(bigEndian: raw.load(as: sockaddr_in6.self).sin6_port)
            default: return 0
            }
        }
    }

    func withPort(_ port: UInt16) -> SocketAddress {
        var copy = self
        let family = self.family
        withUnsafeMutableBytes(of: &copy.storage) { raw in
            switch family {
            case AF_INET:
                var address = raw.load(as: sockaddr_in.self)
                address.sin_port = port.bigEndian
                raw.storeBytes(of: address, as: sockaddr_in.self)
            case AF_INET6:
                var address = raw.load(as: sockaddr_in6.self)
                address.sin6_port = port.bigEndian
                raw.storeBytes(of: address, as: sockaddr_in6.self)
            default:
                break
            }
        }
        return copy
    }

    var host: String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withSockaddr { address, length in
            getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        }
        return result == 0 ? String(cString: buffer) : "?"
    }

    var description: String { family == AF_INET6 ? "[\(host)]:\(port)" : "\(host):\(port)" }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

enum Sockets {
    static func errorText(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var value = value
        _ = setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A dual-stack (IPv6 plus IPv4-mapped) socket bound to `port` on every interface; 0 picks a free port.
    static func makeBoundSocket(type: Int32, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET6, type, 0)
        guard fd >= 0 else { throw AirPlayError.socket("socket(): \(errorText())") }
        setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, 0)
        setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw AirPlayError.socket("bind(port \(port)): \(errorText(code))")
        }
        return (fd, localPort(of: fd))
    }

    static func localPort(of fd: Int32) -> UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin6_port)
    }

    /// Waits until `fd` is readable (true), `timeoutMs` passes (false), or it fails (nil).
    static func waitReadable(_ fd: Int32, timeoutMs: Int32) -> Bool? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMs)
        if result < 0 { return errno == EINTR ? false : nil }
        if result == 0 { return false }
        if descriptor.revents & Int16(POLLNVAL) != 0 { return nil }
        return true
    }

    /// Reads exactly `count` bytes; nil if the peer closed the connection or it failed.
    static func readExactly(_ fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var received = 0
            while received < count {
                let result = recv(fd, base + received, count - received, 0)
                if result > 0 {
                    received += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return complete ? data : nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let result = send(fd, base + sent, raw.count - sent, 0)
                if result > 0 {
                    sent += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// A listening TCP socket whose `accept` can time out, so the accepting thread can notice `close()`.
final class TCPListener {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16 = 0, backlog: Int32 = 16) throws {
        let (fd, boundPort) = try Sockets.makeBoundSocket(type: SOCK_STREAM, port: port)
        guard listen(fd, backlog) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw AirPlayError.socket("listen(): \(Sockets.errorText(code))")
        }
        self.fd = fd
        self.port = boundPort
    }

    deinit { close() }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The next client, or nil after `timeoutMs`, on error, or once closed.
    func accept(timeoutMs: Int32) -> (fd: Int32, peer: SocketAddress)? {
        guard !isClosed, Sockets.waitReadable(fd, timeoutMs: timeoutMs) == true, !isClosed else { return nil }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
        }
        guard client >= 0 else { return nil }
        Sockets.setOption(client, SOL_SOCKET, SO_NOSIGPIPE, 1)
        return (client, SocketAddress(storage: storage, length: length))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// A bound UDP socket with a timed receive.
final class UDPSocket {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16 = 0) throws {
        (fd, self.port) = try Sockets.makeBoundSocket(type: SOCK_DGRAM, port: port)
        Sockets.setOption(fd, SOL_SOCKET, SO_RCVBUF, 1 << 20)
    }

    deinit { close() }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    @discardableResult
    func send(_ data: Data, to address: SocketAddress) -> Bool {
        guard !isClosed else { return false }
        let sent = data.withUnsafeBytes { raw in
            address.withSockaddr { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
        }
        return sent == data.count
    }

    /// The next datagram, or nil after `timeoutMs`, on error, or once closed.
    func receive(maxLength: Int = 4096, timeoutMs: Int32) -> (data: Data, from: SocketAddress)? {
        guard !isClosed, Sockets.waitReadable(fd, timeoutMs: timeoutMs) == true, !isClosed else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, maxLength, 0, $0, &length)
            }
        }
        guard received >= 0 else { return nil }
        return (Data(buffer[0..<received]), SocketAddress(storage: storage, length: length))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
