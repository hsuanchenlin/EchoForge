import Foundation

actor ModelLoadCoordinator<Value> {
    private var inFlight: Task<Value, Error>?

    func run(_ operation: @escaping () async throws -> Value) async throws -> Value {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
