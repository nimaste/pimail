import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

@Suite("ServerConnection")
struct ServerConnectionTests {
    @Test("a connection discovers through the address it was given, subpath included")
    func discoveryURL() throws {
        let connection = ServerConnection(
            address: try ServerAddress.parse("nas.local/plmail"),
            credential: .appPassword("plmail_" + String(repeating: "a", count: 64))
        )

        #expect(
            connection.address.sessionDiscoveryURL.absoluteString
                == "https://nas.local/plmail/.well-known/jmap"
        )
        #expect(connection.host == "nas.local")
    }

    /// The host is what the UI names when a server is unreachable — "can't
    /// reach nas.local" rather than "the network connection was lost", because
    /// the person reading it is also the person who administers the machine.
    @Test("the host survives a port and a scheme")
    func host() throws {
        #expect(
            try ServerConnection(
                address: ServerAddress.parse("http://192.168.1.5:8080"),
                credential: .appPassword("x")
            ).host == "192.168.1.5"
        )
    }
}
