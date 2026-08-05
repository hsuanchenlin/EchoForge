import AVFoundation
import Foundation
import SwiftUI
import AppKit
import CoreAudio

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false

    /// How loud the microphone is right now, 0…1, while something on screen is
    /// drawing it. Zero whenever nothing is being recorded.
    ///
    /// Published only after `setLevelMonitoring(enabled: true)`, because it is
    /// not free: it costs a 20 Hz timer plus a main-thread publish per tick for
    /// the whole recording, and nothing in the app draws a level meter unless the
    /// capsule HUD is switched on.
    @Published private(set) var inputLevel: Float = 0

    /// How often the level is sampled while it is being drawn. 20 Hz is what a
    /// level meter needs to look continuous; the waveform's own history supplies
    /// the rest of the motion.
    static let levelSampleInterval: TimeInterval = 0.05

    /// The reading treated as silence.
    ///
    /// Not the -160 dB floor `AVAudioRecorder` reports for true digital silence:
    /// a built-in microphone in a quiet room sits around -50 dB, so a meter
    /// scaled from the absolute floor never returns to rest.
    static let levelSilenceDecibels: Float = -50

    static let minimumRecordingDuration: TimeInterval = 1.0
    static let temporaryFileMaxAge: TimeInterval = 24 * 60 * 60
    /// Extra audio captured after a stop request, so the tail of the last word
    /// (released together with the hotkey) is not clipped.
    static let stopTailDuration: TimeInterval = 0.25
    
    // Serializes all recording state mutations (start/stop/cancel/connection monitoring)
    // so a stop arriving right after a start can never overtake it.
    private let workQueue = DispatchQueue(label: "com.opensuperwhisper.audiorecorder")
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var connectionCheckTimer: DispatchSourceTimer?
    private var levelCheckTimer: DispatchSourceTimer?
    /// Whether `inputLevel` is wanted. Read and written on `workQueue` only,
    /// like every other piece of recording state.
    private var wantsLevelMonitoring = false
    private var recordingDeviceID: AudioDeviceID?
    private var previousDefaultInputDeviceID: AudioDeviceID?

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    static var temporaryRecordingsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("temp_recordings")
    }
    
    override private init() {
        temporaryDirectory = Self.temporaryRecordingsDirectory
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        workQueue.async { [temporaryDirectory] in
            Self.cleanupOldTemporaryFiles(in: temporaryDirectory, olderThan: Self.temporaryFileMaxAge)
        }
        setup()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }
    
    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory: \(error)")
        }
    }
    
    static func cleanupOldTemporaryFiles(in directory: URL, olderThan maxAge: TimeInterval) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
    
    // Loaded once: decoding the mp3 from disk takes ~15 ms on the main thread,
    // which drops frames of the indicator appear animation on every hotkey press.
    private static let cachedNotificationSound: NSSound? = {
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3"),
              let sound = NSSound(contentsOf: soundURL, byReference: false) else {
            print("Failed to load notification sound file")
            return nil
        }
        sound.volume = 0.3
        return sound
    }()
    
    private func playNotificationSound() {
        guard let sound = Self.cachedNotificationSound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
        notificationSound = sound
    }
    
    func startRecording() {
        // Everything below costs CoreAudio HAL round-trips (device queries,
        // AudioQueue start for the notification sound) — 20-35 ms that used to
        // block the main thread right when the indicator appear animation
        // starts, so the whole start sequence runs on the work queue.
        let playSound = AppPreferences.shared.playSoundOnRecordStart
        workQueue.async {
            guard let activeMic = MicrophoneService.shared.getActiveMicrophone() else {
                print("Cannot start recording - no audio input available")
                return
            }
            
            if playSound {
                self.playNotificationSound()
            }
            
            let requiresConnection = MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
            self.updateRecordingState(isRecording: false, isConnecting: requiresConnection)
            self.performStart(activeMic: activeMic, monitorConnection: requiresConnection)
        }
    }
    
    private func performStart(activeMic: MicrophoneService.AudioDevice?, monitorConnection: Bool) {
        if audioRecorder != nil {
            print("stop recording while recording")
            _ = performStop(discard: true)
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = temporaryDirectory.appendingPathComponent("\(timestamp).wav")
        currentRecordingURL = fileURL
        
        print("start record file to \(fileURL)")
        
        var channelCount = 1
        #if os(macOS)
        if let activeMic = activeMic {
            switchSystemDefaultInput(to: activeMic)
            channelCount = MicrophoneService.shared.getInputChannelCount(for: activeMic)
            print("Recording with \(channelCount) input channel(s) from \(activeMic.displayName)")
        }
        #endif
        
        // 16-bit integer PCM: half the disk/IO of Float32 with no quality loss
        // for speech recognition (whisper consumes 16 kHz mono anyway).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = monitorConnection || wantsLevelMonitoring
            audioRecorder?.record()
            if wantsLevelMonitoring {
                startLevelMonitoring()
            }
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            print("Recording started successfully")
        } catch {
            print("Failed to start recording: \(error)")
            currentRecordingURL = nil
            restoreSystemDefaultInputIfNeeded()
            updateRecordingState(isRecording: false, isConnecting: false)
        }
    }
    
    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                guard let recorder = self.audioRecorder, let url = self.currentRecordingURL else {
                    continuation.resume(returning: self.performStop(discard: false))
                    return
                }
                
                // Detach the session immediately (UI state, connection monitoring),
                // then keep capturing a short tail before actually stopping, so the
                // end of the last word released together with the hotkey survives.
                self.audioRecorder = nil
                self.currentRecordingURL = nil
                self.stopConnectionMonitoring()
                self.stopLevelMonitoring()
                self.updateRecordingState(isRecording: false, isConnecting: false)
                
                self.workQueue.asyncAfter(deadline: .now() + Self.stopTailDuration) {
                    let recordedDuration = recorder.currentTime
                    recorder.stop()
                    // A new recording may have started during the tail window;
                    // it will restore the system input itself when it stops.
                    if self.audioRecorder == nil {
                        self.restoreSystemDefaultInputIfNeeded()
                    }
                    
                    if recordedDuration < Self.minimumRecordingDuration {
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }
    
    func cancelRecording() {
        workQueue.sync {
            _ = performStop(discard: true)
        }
    }
    
    private func performStop(discard: Bool) -> URL? {
        let recordedDuration = audioRecorder?.currentTime ?? 0
        audioRecorder?.stop()
        audioRecorder = nil
        stopConnectionMonitoring()
        stopLevelMonitoring()
        restoreSystemDefaultInputIfNeeded()
        updateRecordingState(isRecording: false, isConnecting: false)
        
        guard let url = currentRecordingURL else { return nil }
        currentRecordingURL = nil
        
        if discard || recordedDuration < Self.minimumRecordingDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
    
    #if os(macOS)
    private func switchSystemDefaultInput(to device: MicrophoneService.AudioDevice) {
        guard let targetID = MicrophoneService.shared.getCoreAudioDeviceID(for: device) else { return }
        recordingDeviceID = targetID
        
        let currentDefault = MicrophoneService.shared.getCurrentSystemDefaultInputDevice()
        guard currentDefault != targetID else { return }
        
        if MicrophoneService.shared.setSystemDefaultInputDevice(targetID) {
            previousDefaultInputDeviceID = currentDefault
            print("Set system default input to: \(device.displayName)")
        }
    }
    
    private func restoreSystemDefaultInputIfNeeded() {
        guard let previous = previousDefaultInputDeviceID else { return }
        previousDefaultInputDeviceID = nil
        
        // Restore only if the default is still the device we set,
        // so a manual change made by the user during recording is kept.
        if MicrophoneService.shared.getCurrentSystemDefaultInputDevice() == recordingDeviceID {
            _ = MicrophoneService.shared.setSystemDefaultInputDevice(previous)
        }
    }
    #else
    private func switchSystemDefaultInput(to device: MicrophoneService.AudioDevice) {}
    private func restoreSystemDefaultInputIfNeeded() {}
    #endif
    
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording: \(error), url: \(url)")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
    
    private func updateRecordingState(isRecording: Bool, isConnecting: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            self.isConnecting = isConnecting
        }
    }
    
    private func startConnectionMonitoring() {
        stopConnectionMonitoring()
        
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize: Int64 = 4096
        var growthCount = 0
        
        timer.setEventHandler { [weak self] in
            guard let self = self, let _ = self.audioRecorder, let url = self.currentRecordingURL else { return }
            
            let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let totalGrowth = currentFileSize - initialFileSize
            
            if totalGrowth > 8000 {
                growthCount += 1
            }
            
            if growthCount >= 2 {
                self.stopConnectionMonitoring()
                self.updateRecordingState(isRecording: true, isConnecting: false)
            }
        }
        connectionCheckTimer = timer
        timer.resume()
    }
    
    private func stopConnectionMonitoring() {
        connectionCheckTimer?.cancel()
        connectionCheckTimer = nil
    }

    // MARK: - Input level

    /// Turns publishing of `inputLevel` on or off.
    ///
    /// Explicit rather than always-on because the level is only ever wanted while
    /// something is drawing it: the capsule HUD asks for it when a dictation
    /// starts and gives it back when the capsule goes away, and a build where the
    /// HUD is switched off pays nothing for it.
    func setLevelMonitoring(enabled: Bool) {
        workQueue.async {
            guard self.wantsLevelMonitoring != enabled else { return }
            self.wantsLevelMonitoring = enabled

            guard enabled else {
                self.stopLevelMonitoring()
                return
            }
            // Asked for mid-recording: metering can be switched on while an
            // `AVAudioRecorder` is running, so the meter starts from here rather
            // than from the next recording.
            if let recorder = self.audioRecorder {
                recorder.isMeteringEnabled = true
                self.startLevelMonitoring()
            }
        }
    }

    /// Maps `AVAudioRecorder`'s dBFS reading onto the 0…1 a meter draws.
    ///
    /// Linear in decibels rather than in amplitude, which is what makes it look
    /// right: speech at a normal distance averages about -20 dBFS, and
    /// `pow(10, -20/20)` is 0.1 - a meter that barely moves while someone is
    /// talking. Scaled from `levelSilenceDecibels` instead, the same speech fills
    /// about 60 % of the bar and a raised voice most of it.
    static func normalizedLevel(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let floorDecibels = levelSilenceDecibels
        let clamped = min(0, max(floorDecibels, decibels))
        return (clamped - floorDecibels) / -floorDecibels
    }

    private func startLevelMonitoring() {
        stopLevelMonitoring()

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: Self.levelSampleInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, let recorder = self.audioRecorder else { return }
            recorder.updateMeters()
            let level = Self.normalizedLevel(decibels: recorder.averagePower(forChannel: 0))
            DispatchQueue.main.async {
                self.inputLevel = level
            }
        }
        levelCheckTimer = timer
        timer.resume()
    }

    private func stopLevelMonitoring() {
        levelCheckTimer?.cancel()
        levelCheckTimer = nil
        // The meter must read empty rather than hold the last sample: the next
        // thing the user sees of it is the start of their next dictation.
        DispatchQueue.main.async {
            self.inputLevel = 0
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        workQueue.async {
            guard recorder === self.audioRecorder else { return }
            self.currentRecordingURL = nil
        }
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
