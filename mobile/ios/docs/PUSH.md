# Push — what the app does, and what the server would need

The client half is built. The server half does not exist, and cannot be built
without something only you can supply.

## The short version

plMail has no way to send an Apple push. It needs an APNs key, which comes from
a **paid Apple Developer account** — a self-hosted server has no relationship
with Apple of its own. Until that exists, the app registers nothing, prompts
for nothing, and keeps refreshing the way it already does.

## What the app does today

- On connecting to a server it calls `registerForRemoteNotifications()` and
  gets a device token. This needs no permission and shows nothing.
- It asks the session whether the server advertises
  `urn:plmail:params:jmap:apns`. Today nothing does, so the token is
  discarded and a line goes in the log.
- It **only** shows the notification permission prompt when that capability is
  present. Spending a one-shot prompt on a server that cannot send is worse
  than not asking — refusing it is close to permanent.
- If a silent push ever arrives, the app does an ordinary delta pull. That is
  all.

## What a push would carry

Nothing about the mail. No subject, no sender, no body:

```json
{ "aps": { "content-available": 1 }, "accountId": "71" }
```

The payload says *something changed on this account* and the app fetches. This
is not squeamishness — it is the point of the product. A self-hosted mail
client whose whole premise is that the mail stays on your server should not
relay message contents through Apple for the sake of a richer banner. It also
means a dropped or coalesced push costs latency and nothing else, and there is
no notification-service extension to maintain.

The cost is real and worth stating: the notification cannot say who wrote to
you until the app has fetched.

## What the server would need

1. **An APNs key** (`.p8`) from the Apple Developer account that signs the app,
   plus its key id and team id. This is the blocking item.

2. **Somewhere to keep device tokens** — one row per device per user: token,
   environment (`sandbox` or `production`), a device name for the settings
   screen, and a last-seen date so dead tokens get pruned.

3. **A `PushSubscription/set` method** behind the capability
   `urn:plmail:params:jmap:apns`, advertised in the session object as:

   ```json
   "urn:plmail:params:jmap:apns": { "environment": "production", "topic": "de.plmail" }
   ```

   The method the app already sends:

   ```json
   ["PushSubscription/set", {
     "update": {
       "thisDevice": {
         "deviceToken": "a1b2…",
         "deviceName": "Paul's iPhone",
         "environment": "sandbox"
       }
     }
   }, "c0"]
   ```

   `deviceToken: null` means *forget this device* — sent on sign-out. It
   arrives as an explicit null rather than an absent key, and the two must not
   be treated the same.

4. **A sender**, on the existing message bus: when an account's state token
   changes, push to that account's tokens. Coalesce — one push per account per
   few seconds is plenty, and APNs will collapse them anyway.

5. **Environment matching.** A token minted by a debug build is a sandbox
   token and must go to `api.sandbox.push.apple.com`. Sending it to production
   fails with an error that does not explain itself. The app reports which
   environment it was built for on every registration; use that field rather
   than guessing.

## Verified, and not

Verified on the simulator: registration returns an 80-byte device token, the
capability check correctly finds no APNs support and declines to send it, and
the encoding is covered by tests — including that a nil token serialises as
`null` rather than vanishing, which it originally did.

**Not verified:** that a silent push actually reaches
`application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` and
triggers a sync. `xcrun simctl push` delivers the payload — the system log
shows a `UIFetchContentInBackgroundAction` decoded and replied to — but the
delegate method was never called, with the selector exposed via `@objc`, via
`nonisolated`, and via the `async` variant, in foreground and background. This
looks like a simulator limitation rather than an app fault, but it is
untested either way and should not be described as working until a real device
and a real sender have proved it.
