/// Caps how many requests are in flight at once.
///
/// The server advertises `maxConcurrentRequests`, and on plMail that number is
/// not advisory: it runs on FrankenPHP with a small worker pool, and the
/// machine is frequently a NAS or a Raspberry Pi. A client that ignores the
/// limit does not get rate-limited — it occupies every worker and the server
/// stops answering, including for the web UI in another tab.
public actor RequestGate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// How many permits are reserved and unavailable — used to hold one back
    /// for the duration of an SSE connection. SSE takes no JMAP slot in the
    /// protocol's model, but it does hold a PHP worker for its whole life,
    /// which is the resource that actually runs out.
    private var reserved = 0

    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        available = max(1, capacity)
    }

    public init(session: Session) {
        self.init(capacity: session.capabilities.core.maxConcurrentRequests)
    }

    /// Runs `body` holding one permit.
    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T
    {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Holds a permit back until the returned token is discarded.
    ///
    /// Always at least one permit stays available, so reserving cannot
    /// deadlock a client that then needs to make a request.
    public func reserve() async -> Reservation {
        guard capacity - reserved > 1 else { return Reservation(gate: nil) }

        await acquire()
        reserved += 1

        return Reservation(gate: self)
    }

    fileprivate func endReservation() {
        guard reserved > 0 else { return }
        reserved -= 1
        release()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            // Hand the permit straight to the next waiter rather than
            // returning it to the pool and racing for it.
            waiting.removeFirst().resume()
        }
    }

    /// A held-back permit. Call ``end()`` when the work that justified it is
    /// over; deinit does not release it, because doing so would need an
    /// unstructured task and hide the lifetime.
    public struct Reservation: Sendable {
        fileprivate let gate: RequestGate?

        public func end() async {
            await gate?.endReservation()
        }
    }
}
