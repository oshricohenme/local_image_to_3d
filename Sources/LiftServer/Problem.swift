import Foundation
import HTTPTypes
import LiftCore
import OpenAPIRuntime

/// A risky command called without `confirm: true` (spec §10). Nothing changed.
struct ConfirmationRequired: Error { var impact: String }

/// The value of a gated command, or `ConfirmationRequired` with its impact.
func gated<T>(_ result: Gated<T>) throws -> T {
    switch result {
    case .done(let value): return value
    case .confirmationRequired(let impact): throw ConfirmationRequired(impact: impact)
    }
}

/// The one error body of both adapters: HTTP sends it with `status`, MCP as an `isError` tool result.
struct Problem: Error, Codable, Sendable, Equatable {
    var error: String
    var message: String
    var fields: [FieldError]?
    var impact: String?
    var command: String?
    var exitCode: Int32?
    var tail: [String]?
    /// Not encoded; the HTTP status.
    var status = 500

    enum CodingKeys: String, CodingKey { case error, message, fields, impact, command, exitCode, tail }

    init(error: String, message: String, status: Int) {
        self.error = error
        self.message = message
        self.status = status
    }

    /// 422 invalid_input, 404 not_found, 409 invalid_state / prerequisite / confirmation_required, 500 command_failed.
    /// A request body that doesn't match openapi.yaml is invalid_input too, with the JSON path as the field.
    static func from(_ error: any Error) -> Problem {
        switch error {
        case let p as Problem:
            return p
        case let c as ConfirmationRequired:
            var p = Problem(error: "confirmation_required", message: "This changes things; call again with confirm: true to go ahead.", status: 409)
            p.impact = c.impact
            return p
        case let server as ServerError:
            if server.underlyingError is LiftError || server.underlyingError is ConfirmationRequired || server.underlyingError is Problem
                || server.underlyingError is DecodingError {
                return from(server.underlyingError)
            }
            let status = Int(server.httpStatus.code)
            return Problem(error: status < 500 ? "bad_request" : "internal", message: server.causeDescription, status: status)
        case let decoding as DecodingError:
            var p = Problem(error: "invalid_input", message: "the request doesn't match the API schema", status: 422)
            p.fields = [Self.field(decoding)]
            return p
        case let lift as LiftError:
            switch lift {
            case .notFound: return Problem(error: "not_found", message: lift.description, status: 404)
            case .invalidInput(let errors):
                var p = Problem(error: "invalid_input", message: lift.description, status: 422)
                p.fields = errors
                return p
            case .invalidState: return Problem(error: "invalid_state", message: lift.description, status: 409)
            case .prerequisite: return Problem(error: "prerequisite", message: lift.description, status: 409)
            case .commandFailed(let command, let code, let tail):
                var p = Problem(error: "command_failed", message: "`\(command)` failed with exit code \(code)", status: 500)
                p.command = command
                p.exitCode = code
                p.tail = tail
                return p
            }
        default:
            return Problem(error: "internal", message: "\(error)", status: 500)
        }
    }

    static func field(_ error: DecodingError) -> FieldError {
        func path(_ keys: [any CodingKey]) -> String {
            keys.reduce("") { out, key in
                if let i = key.intValue { return out + "[\(i)]" }
                return out.isEmpty ? key.stringValue : out + "." + key.stringValue
            }
        }
        switch error {
        case .keyNotFound(let key, let ctx): return FieldError(path(ctx.codingPath + [key]), "required")
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return FieldError(path(ctx.codingPath), ctx.debugDescription)
        @unknown default: return FieldError("", "\(error)")
        }
    }

    var json: Data { (try? Wire.data(self)) ?? Data() }
}

/// Turns every error a generated handler throws into a `Problem` response.
struct ProblemMiddleware: ServerMiddleware {
    func intercept(_ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?))
        async throws -> (HTTPResponse, HTTPBody?) {
        do {
            return try await next(request, body, metadata)
        } catch {
            let problem = Problem.from(error)
            return (HTTPResponse(status: .init(code: problem.status), headerFields: [.contentType: "application/json"]), HTTPBody(problem.json))
        }
    }
}
