import Foundation
import FluidAudio

actor ModelLoadCoordinator<Value> {
    private var inFlight: Task<Value, Error>?
    private var waiters: Set<UUID> = []
    private var progressHandlers: [UUID: DownloadUtils.ProgressHandler] = [:]
    private var latestProgress: DownloadUtils.DownloadProgress?

    func run(
        progressHandler: DownloadUtils.ProgressHandler? = nil,
        _ operation: @escaping () async throws -> Value
    ) async throws -> Value {
        let waiterID = UUID()
        waiters.insert(waiterID)
        if let progressHandler {
            progressHandlers[waiterID] = progressHandler
            if let latestProgress { progressHandler(latestProgress) }
        }

        let task: Task<Value, Error>
        if let inFlight {
            task = inFlight
        } else {
            latestProgress = nil
            task = Task { try await operation() }
            inFlight = task
        }

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                detach(waiterID, cancelLoadIfEmpty: false)
                finish()
                return value
            } catch {
                detach(waiterID, cancelLoadIfEmpty: false)
                finish()
                throw error
            }
        } onCancel: {
            Task { await self.detach(waiterID, cancelLoadIfEmpty: true) }
        }
    }

    func reportProgress(_ progress: DownloadUtils.DownloadProgress) {
        latestProgress = progress
        for handler in progressHandlers.values {
            handler(progress)
        }
    }

    private func detach(_ waiterID: UUID, cancelLoadIfEmpty: Bool) {
        waiters.remove(waiterID)
        progressHandlers[waiterID] = nil
        if cancelLoadIfEmpty, waiters.isEmpty {
            inFlight?.cancel()
        }
    }

    private func finish() {
        guard waiters.isEmpty else { return }
        inFlight = nil
        latestProgress = nil
    }
}
