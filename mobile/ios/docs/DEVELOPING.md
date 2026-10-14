# Developing plMail for iOS

Notes for working on the app. For what it is and how to install it, see the
[README](../README.md).

A native iPhone and iPad client for [plMail](https://github.com/karatektus/pl_mail), talking to it
over JMAP (RFC 8620 / RFC 8621).

plMail is a **self-hosted** mail client, so there is no canonical server: the app asks for an
address at onboarding and expects LAN hostnames, Tailscale nodes, private-CA certificates and a
NAS that is sometimes rebooting. Everything the app does is shaped by that — cache aggressively,
poll rarely, degrade per-account, and never busy-loop against someone's home server.

The server's [docs/CLIENT_DEVELOPMENT.md](https://github.com/karatektus/pl_mail/blob/main/docs/CLIENT_DEVELOPMENT.md)
is the specification this app implements. Read it before changing anything here.

## Layout

| Path | What |
|---|---|
| `App/` | The app target: `@main`, the shell, xcconfigs. Deliberately thin. |
| `Packages/PLMail/Sources/JMAPKit` | Transport and codec. Foundation only — no SwiftData, no SwiftUI. |
| `Packages/PLMail/Sources/PLMailCore` | Persistence, sync, search, Keychain. |
| `Packages/PLMail/Sources/PLMailUI` | Theme tokens and views. |

`JMAPKit` has no dependencies on purpose: it is the code most worth testing, and keeping the
frameworks out means its suite runs on the host in seconds instead of booting a simulator.

## Building

```bash
swift test --package-path Packages/PLMail
```

```bash
xcodebuild build -project plMail.xcodeproj -scheme plMail -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Formatting is `swift-format`, which ships with the toolchain. Run it without
`--configuration` so it picks up the per-directory config:

```bash
swift format lint --strict --recursive App Packages
```

`Packages/PLMail/Tests/.swift-format` and the matching file in
`Sources/JMAPTestSupport` relax `NeverForceUnwrap` and `NeverUseForceTry`.
Force-unwrapping a literal URL, or a fixture the test itself just wrote, is not
the hazard those rules exist to catch — a wrong one fails the test loudly at the
line that caused it, and wrapping each in `#require` adds noise without adding
signal. Shipping code still forbids both.

`JMAPTestSupport` lives under `Sources/` only so that two test targets can share
it; it is not a product and nothing but tests depends on it, so it never links
into the app.

Device builds need a signing identity. Copy `App/Config/Signing.xcconfig.dist` to
`Signing.xcconfig` (gitignored) and fill in your team. Simulator builds need neither line.

## Running against a server

Bring up the server's own stack, then create an app password in **Settings → App passwords** and
paste it into onboarding. The secret is shown once and looks like `plmail_<64 hex>`.

```bash
docker compose up --build
```

For anything automated, prefer the server's isolated test stack (`npm run test:env:up`, serving at
`http://127.0.0.1:8001`) so tests never touch real mail.

## Two decisions worth knowing before you change things

**The store is disposable cache.** Everything in SwiftData is reconstructible from
the server, which is what licenses deleting and rebuilding it on any migration or
corruption failure rather than writing a migration stage for cache data. That is
only safe while it stays true — so the two things that are *not* reconstructible
live elsewhere on purpose: the credential in the Keychain, and unsent mail in
Application Support under `plmail-outbox/`. Do not put anything irreplaceable in
the store.

**Paging is by date keyset, never by `position`.** `EmailQueryRunner` fetches every
matching row into PHP before slicing, so `position: 5000` costs exactly what
`position: 0` costs — the whole mailbox, on someone's NAS. Pages are taken with
`before: <lastReceivedAt>` and `position: 0` always. `AccountPager` also tracks the
ids already emitted at the boundary timestamp, because `before` is strict `<` and
messages sharing a second across a page boundary would otherwise vanish.

## Rich text

The iOS 26 rich `TextEditor` stores bold and italic in `SwiftUI.Font`, which cannot
be introspected — there is no `font.isBold`, only equality against a font you built
yourself. `RichTextEditor` therefore pins the editor to `.body` and, after each
edit, matches every run's font against the handful of values that base can produce,
normalising into `MailInlineStyle` (a plain Foundation attribute) which
`MailHTML` serialises.

The direction matters. Visual attributes are the source of truth and our attribute
is derived, so ⌘B, the edit menu, the toolbar and paste all converge on one path. If
you invert it and make `MailInlineStyle` authoritative, every formatting route that
does not go through our own buttons is silently dropped.

Note also that `Font.body.bold().italic() != Font.body.italic().bold()` — the order
the user pressed the keys is part of the value, which is why the lookup table lists
both and normalisation rewrites to a canonical one.
