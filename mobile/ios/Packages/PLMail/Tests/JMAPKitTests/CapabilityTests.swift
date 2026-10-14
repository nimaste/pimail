import Foundation
import Testing

@testable import JMAPKit

@Suite("Capability")
struct CapabilityTests {
    @Test("URNs match the wire form exactly")
    func urns() {
        #expect(Capability.core.rawValue == "urn:ietf:params:jmap:core")
        #expect(Capability.mail.rawValue == "urn:ietf:params:jmap:mail")
        #expect(Capability.submission.rawValue == "urn:ietf:params:jmap:submission")
        #expect(Capability.push.rawValue == "urn:plmail:params:jmap:push")
    }

    @Test("plMail's own URNs are spelled the way the server spells them")
    func vendorURNs() {
        #expect(Capability.apns.rawValue == "urn:plmail:params:jmap:apns")
        #expect(Capability.calendars.rawValue == "urn:plmail:params:jmap:calendars")
        #expect(Capability.appearance.rawValue == "urn:plmail:params:jmap:appearance")
    }

    /// The server advertises `push` and `apns` in its Session but has neither
    /// in `Capability::SUPPORTED`, so either in `using` refuses the **whole**
    /// request with `unknownCapability`. Nothing about the URNs themselves says
    /// so, and the cost is not a degraded feature but every unrelated call in
    /// the same batch, so the split is pinned exactly rather than sampled.
    @Test("only the capabilities the server accepts are declarable in `using`")
    func declarableSet() {
        #expect(
            Capability.supportedInUsing == [.core, .mail, .submission, .calendars, .appearance])

        for capability in Capability.allCases {
            #expect(
                capability.isSupportedInUsing
                    == (capability != .push && capability != .apns),
                "\(capability.rawValue) is on the wrong side of `supportedInUsing`")
        }
    }

    /// **No method anywhere in the package may declare an undeclarable URN.**
    ///
    /// This is the check that would have caught `PushSubscriptionSet` naming
    /// `apns` — a Core method — which put a URN the server has never heard of
    /// into `using` and would have refused every request batched with it. There
    /// is no method registry to iterate, deliberately, and `RequestBuilder`'s
    /// precondition only fires once a wrong method is actually added to a
    /// request. So the source is read instead, which covers methods in both
    /// modules and every one written after this.
    @Test("every method in the package declares a capability that may appear in `using`")
    func everyMethodDeclaresADeclarableCapability() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()  // JMAPKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
            .appending(path: "Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        var checked = 0

        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in source.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)

                guard code.hasPrefix("//") == false,
                    let range = code.range(of: "static let capability = Capability.")
                else { continue }

                let name = code[range.upperBound...]
                    .prefix { $0.isLetter }

                checked += 1

                guard
                    let capability = Capability.allCases.first(where: {
                        "\($0)" == String(name)
                    })
                else {
                    offenders.append("\(url.lastPathComponent): unknown case .\(name)")

                    continue
                }

                if capability.isSupportedInUsing == false {
                    offenders.append("\(url.lastPathComponent): .\(name)")
                }
            }
        }

        #expect(checked > 0, "No method capabilities were found — did the sources move?")
        #expect(
            offenders.isEmpty,
            """
            These methods would put an undeclarable URN in `using`, refusing \
            the whole request: \(offenders.joined(separator: ", "))
            """)
    }

    /// The end-to-end shape, since the two facts above could both hold while
    /// the builder still leaked something into the array.
    @Test("a built request declares only URNs the server accepts")
    func builtRequestIsClean() {
        var builder = RequestBuilder()
        builder.add(EmailGet(accountID: AccountID("1"), ids: .value([EmailID("e1")])))

        let declared = Set(builder.makeRequest().using)
        let allowed = Set(Capability.supportedInUsing.map(\.rawValue))

        #expect(declared.isEmpty == false)
        #expect(declared.subtracting(allowed).isEmpty)
    }
}
