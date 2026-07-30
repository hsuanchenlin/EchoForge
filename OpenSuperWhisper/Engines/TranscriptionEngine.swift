import Foundation
import AVFoundation

protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    /// Fractional progress of the current transcription, 0.0...1.0.
    ///
    /// Part of the protocol so `TranscriptionService` can wire progress the
    /// same way for every engine. Engines report it however they can - Whisper
    /// from whisper.cpp's C callback, FluidAudio from its progress stream, a
    /// chunking engine per chunk - but the caller must never have to know which.
    var onProgressUpdate: ((Float) -> Void)? { get set }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
}

