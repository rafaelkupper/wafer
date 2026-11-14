import Darwin
import Foundation

/// Shared by reader and export URLSession requests, including every redirect.
struct RemoteAssetURLGuard: Sendable {
    enum Rejection: Error { case invalidURL, unresolvedHost, nonPublicAddress }
    let resolve: @Sendable (String) throws -> [String]

    init(resolve: @escaping @Sendable (String) throws -> [String] = Self.resolveHost) {
        self.resolve = resolve
    }

    func validate(_ url: URL?) throws {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { throw Rejection.invalidURL }
        let name = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        // Literal addresses are checked even when tests inject a DNS resolver.
        if Self.isIPAddress(name) {
            guard Self.isPublicAddress(name) else { throw Rejection.nonPublicAddress }
            return
        }
        let addresses = try resolve(name)
        guard !addresses.isEmpty else { throw Rejection.unresolvedHost }
        guard addresses.allSatisfy(Self.isPublicAddress) else { throw Rejection.nonPublicAddress }
    }

    static func resolveHost(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw Rejection.unresolvedHost
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            let info = current.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
            entry = info.ai_next
        }
        return addresses
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { isPublicIPv4(Array($0)) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        // RFC 6052 well-known /96: the final 32 bits are the IPv4 destination.
        if bytes.prefix(12) == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        // The RFC 8215 local-use /48 can contain several RFC 6052 prefix
        // lengths. Reject it as local rather than guessing the site's layout.
        if bytes.prefix(6) == [0x00, 0x64, 0xff, 0x9b, 0, 1] { return false }
        // 6to4 embeds the destination IPv4 immediately after 2002::/16.
        if bytes.prefix(2) == [0x20, 0x02] {
            return isPublicIPv4(Array(bytes[2..<6]))
        }
        // Teredo embeds a server IPv4 and an obfuscated client IPv4.
        if bytes.prefix(4) == [0x20, 0x01, 0, 0] {
            return isPublicIPv4(Array(bytes[4..<8])) && isPublicIPv4(bytes.suffix(4).map { $0 ^ 0xff })
        }
        // IPv4-compatible, unspecified and loopback addresses share ::/96.
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return false }
        if bytes[0] & 0xfe == 0xfc || bytes[0] == 0xff { return false }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
        return true
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        let a = bytes[0], b = bytes[1]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 169 && b == 254 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        return true
    }
}
