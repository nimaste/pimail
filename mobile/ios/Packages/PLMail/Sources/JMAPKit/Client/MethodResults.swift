import Foundation

/// The decoded results of one request, addressed by the handles the builder
/// handed out.
///
/// Results are *not* decoded eagerly. A batch can carry a failing call
/// alongside successful ones — the server reports method errors inline in a
/// 200 — so decoding on access lets a caller read the calls that worked and
/// handle the one that didn't, rather than losing the whole response.
public struct MethodResults: Sendable {
    private let responses: [CallID: ResponseInvocation]

    /// The session state at the time of the response. A change here means
    /// something moved and a `/changes` pull is due.
    public let sessionState: StateToken?

    init(response: JMAPResponse) {
        // Last write wins: a call id is unique within a request by
        // construction, so a duplicate would be a server bug rather than
        // something to reconcile.
        responses = Dictionary(
            response.methodResponses.map { ($0.callID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        sessionState = response.sessionState
    }

    /// Decodes one call's result.
    ///
    /// - Throws: ``JMAPError/methodFailed(_:description:callID:)`` when that
    ///   call failed, ``JMAPError/malformedResponse(_:)`` when it did not
    ///   decode, or ``JMAPError/noSuchCall(_:)`` when the server answered
    ///   nothing for it.
    public func result<Method: JMAPMethod>(of handle: CallHandle<Method>) throws -> Method.Result {
        guard let response = responses[handle.callID] else {
            throw JMAPError.noSuchCall(handle.callID)
        }

        if response.isError {
            throw Self.methodError(from: response)
        }

        guard response.name == Method.name else {
            throw JMAPError.malformedResponse(
                "\(handle.callID) answered \"\(response.name)\", expected \"\(Method.name)\"."
            )
        }

        do {
            return try response.arguments.decode(as: Method.Result.self)
        } catch {
            throw JMAPError.malformedResponse(
                "Could not decode \(Method.name) for \(handle.callID): \(error)"
            )
        }
    }

    /// Whether a call failed, without decoding it. Lets a caller skip one
    /// degraded account and keep the rest of a batch.
    public func failure<Method: JMAPMethod>(of handle: CallHandle<Method>) -> JMAPError? {
        guard let response = responses[handle.callID], response.isError else { return nil }
        return Self.methodError(from: response)
    }

    private static func methodError(from response: ResponseInvocation) -> JMAPError {
        let problem = try? response.arguments.decode(as: ProblemDocument.self)

        return .methodFailed(
            MethodErrorType(rawValue: problem?.type ?? "serverFail"),
            description: problem?.description ?? problem?.detail,
            callID: response.callID
        )
    }
}

/// The body of a successful `POST` to `apiUrl`.
struct JMAPResponse: Decodable {
    var methodResponses: [ResponseInvocation]
    var sessionState: StateToken?
    var createdIds: [String: String]?
}

extension MethodResults {
    /// Parses a response body, mapping HTTP status and `problem+json` onto
    /// ``JMAPError`` before any method result is looked at.
    ///
    /// Request-level failures — a 401, or a malformed request — arrive as
    /// `application/problem+json` with no `methodResponses` at all, which is a
    /// different shape from a method error and has to be handled first.
    public static func decode(
        body: Data,
        statusCode: Int,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MethodResults {
        guard statusCode == 200 else {
            let problem = try? decoder.decode(ProblemDocument.self, from: body)

            switch statusCode {
            case 401:
                throw JMAPError.notAuthenticated(detail: problem?.detail)
            case 400:
                throw JMAPError.requestFailed(
                    type: problem?.type ?? "unknown", detail: problem?.detail)
            default:
                throw JMAPError.unexpectedStatus(code: statusCode)
            }
        }

        do {
            return MethodResults(response: try decoder.decode(JMAPResponse.self, from: body))
        } catch {
            throw JMAPError.malformedResponse("Not a JMAP response: \(error)")
        }
    }
}
