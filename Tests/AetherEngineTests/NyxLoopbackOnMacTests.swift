// Nyx (2026-11-07) : test ajouté par Nyx, absent de l'amont. Voir Vendor/AetherEngine/NYX-MODIFICATIONS.md.
import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// Vrai là où Nyx garde le serveur HLS local sur la boucle locale (le Mac, App Review 2.4.5). Lu aussi par
/// `HLSLocalServerSlowPeerTests`, dont le test des pairs du réseau n'a plus d'objet sur le Mac.
let nyxEcouteSurLaBoucleLocaleSeulement: Bool = {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}()

/// Nyx : sur le Mac, le serveur n'écoute que sur 127.0.0.1, et rien ne réécrit l'adresse de lecture vers celle du réseau.
@Suite("Nyx : sur le Mac, le serveur HLS local reste sur la boucle locale", .serialized, .timeLimit(.minutes(1)))
struct NyxLoopbackOnMacTests {

    @Test("La boucle locale répond, avec le jeton de séance")
    func loopbackAnswers() throws {
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }

        let served = try #require(server.mediaPlaylistURL)
        #expect(served.host == "127.0.0.1")
        #expect(Self.status(host: "127.0.0.1", port: server.port, path: "/\(server.pathToken)/media.m3u8") == 200)
    }

    @Test(
        "L'adresse du Mac sur le réseau ne joint pas le serveur",
        .enabled(if: nyxEcouteSurLaBoucleLocaleSeulement && HLSLocalServer.localActiveIPAddress() != nil))
    func lanAddressIsRefused() throws {
        let lanIP = try #require(HLSLocalServer.localActiveIPAddress())
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }

        let fd = Self.connect(host: lanIP, port: server.port)
        if let fd { close(fd) }
        #expect(fd == nil, "le serveur a accepté une connexion par \(lanIP) : il écoute hors de la boucle locale")
    }

    #if os(macOS)
    @Test("Aucune adresse du réseau n'est fabriquée pour AirPlay")
    @MainActor
    func noLANRewrite() throws {
        let engine = try AetherEngine()
        let loopback = try #require(URL(string: "http://127.0.0.1:50123/0123456789abcdef0123456789abcdef/master.m3u8"))
        #expect(engine.airPlayPlaybackURL(base: loopback) == nil)
        #expect(engine.airPlayPlaybackURL(base: loopback, playlist: .master) == nil)
        #expect(engine.airPlayHostSwapped(loopback) == loopback)
    }
    #endif

    // MARK: - Outils

    private static func connect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Un GET, le statut HTTP, ou 0.
    private static func status(host: String, port: UInt16, path: String) -> Int {
        guard let fd = connect(host: host, port: port) else { return 0 }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
        let sent = request.utf8CString.withUnsafeBufferPointer { buffer in
            send(fd, buffer.baseAddress, buffer.count - 1, 0)
        }
        guard sent > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 512)
        let received = recv(fd, &bytes, bytes.count, 0)
        guard received > 0 else { return 0 }
        let head = String(decoding: bytes[0 ..< received], as: UTF8.self)
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }
}

/// Le plus petit fournisseur qui laisse le serveur bâtir et servir une playlist media.
private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
}
