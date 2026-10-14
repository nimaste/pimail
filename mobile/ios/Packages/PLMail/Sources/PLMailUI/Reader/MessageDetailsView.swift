#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// The header, spelled out.
///
/// Everywhere else the app shows a display name, because that is what a person
/// is called and an address column would make a thread unreadable. But a
/// display name is the one field in a message that the sender chooses freely,
/// and "PayPal Service" is a display name anyone can set. This is the panel you
/// open when you suspect a message is not what it claims: every address in
/// full, every recipient including the ones the collapsed line dropped, and the
/// date to the minute rather than "yesterday".
///
/// Names are shown above their addresses rather than in the usual `Name
/// <address>` form. Run together on one line, a name containing an `@` reads as
/// part of the address — which is precisely the trick this exists to expose.
struct MessageDetailsView: View {
    let message: MessageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.ui("From"), addresses: [sender])

            if message.to.isEmpty == false {
                row(.ui("To"), addresses: message.to)
            }

            if message.cc.isEmpty == false {
                row(.ui("Cc"), addresses: message.cc)
            }

            if let receivedAt = message.receivedAt {
                row(
                    .ui("Date"),
                    // Long-form and to the minute, in the reader's own time
                    // zone. The header row above says "31 Jul"; if this said
                    // the same thing there would be no reason to open it.
                    values: [receivedAt.formatted(date: .complete, time: .standard)]
                )
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    private var sender: EmailAddress {
        EmailAddress(name: message.fromName, email: message.fromAddress ?? "")
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringResource, addresses: [EmailAddress]) -> some View {
        row(
            label,
            values: addresses.map { address in
                guard let name = address.name, name.isEmpty == false, name != address.email else {
                    return address.email
                }

                return "\(name)\n\(address.email)"
            })
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringResource, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                // A fixed column so From, To, Cc and Date line up. Sized in
                // ems rather than points so it grows with the text does.
                .frame(width: labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .fixedSize(horizontal: false, vertical: true)
                        // Never truncated. A truncated address is the one
                        // rendering of an address that is worse than none:
                        // "service@paypal…" hides the domain, which is the
                        // only part that settles the question.
                        .textCase(nil)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 42
}

#endif
