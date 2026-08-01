import Foundation
import FluidAudio

actor ModelLoadCoordinator<Value> {
    private var inFlight: Task<Value, Error>?
    private var progressHandlers: [UUID: DownloadUtils.ProgressHandler] = [:]
    private var latestProgress: DownloadUtils.DownloadProgress?

    func run(
        progressHandler: DownloadUtils.ProgressHandler? = nil,
        _ operation: @escaping () async throws -> Value
    ) async throws -> Value {
        let handlerID = progressHandler.map { handler in
            let id = UUID()
            progressHandlers[id] = handler
            if let latestProgress { handler(latestProgress) }
            return id
        }
        defer {
            if let handlerID { progressHandlers[handlerID] = nil }
        }

        if let inFlight { return try await inFlight.value }

        latestProgress = nil
        let task = Task { try await operation() }
        inFlight = task
        defer {
            inFlight = nil
            latestProgress = nil
        }
        return try await task.value
    }

    func reportProgress(_ progress: DownloadUtils.DownloadProgress) {
        latestProgress = progress
        for handler in progressHandlers.values {
            handler(progress)
        }
    }
}
