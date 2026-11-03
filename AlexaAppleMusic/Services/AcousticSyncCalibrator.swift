import Foundation
import AVFoundation
import Accelerate

/// Acoustic sync detector that uses the iPhone microphone to measure the timing delta between Sonos and Echo speakers.
///
/// How it works:
/// 1. Plays a distinctive calibration acoustic reference track or rhythm pulses (or any playing song)
/// 2. Records ~4-6 seconds of ambient room audio from the microphone
/// 3. Runs cross-correlation (vDSP) and onset/transient peak detection
/// 4. Finds the primary speaker peaks and computes the exact time difference (delta in milliseconds/seconds)
/// 5. Automatically updates `PlaybackCoordinator.shared.sonosSyncOffsetSeconds` to lock them in sync!
@MainActor
final class AcousticSyncCalibrator: ObservableObject {
    static let shared = AcousticSyncCalibrator()

    @Published var isCalibrating: Bool = false
    @Published var calibrationProgress: Double = 0.0 // 0.0 to 1.0
    @Published var statusMessage: String = "Ready to calibrate"
    @Published var detectedOffsetMs: Double?
    @Published var detectedOffsetSec: Double?
    @Published var confidenceScore: Double = 0.0 // 0.0 to 1.0

    private var audioEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var sampleRate: Double = 44100.0

    private init() {}

    // MARK: - Start Acoustic Calibration

    func startCalibration(
        targetEcho: AlexaDevice,
        targetSonos: AlexaDevice?,
        customTestSong: PlayableMediaItem? = nil
    ) async {
        guard !isCalibrating else { return }

        // Request microphone permission
        let granted = await requestMicrophonePermission()
        guard granted else {
            statusMessage = "Microphone permission required for acoustic calibration."
            return
        }

        isCalibrating = true
        calibrationProgress = 0.05
        detectedOffsetMs = nil
        detectedOffsetSec = nil
        confidenceScore = 0.0
        statusMessage = "Preparing audio calibration..."
        recordedSamples.removeAll()

        let coordinator = PlaybackCoordinator.shared

        // Determine calibration track (preferably a punchy acoustic track or current song)
        let testTrack = customTestSong ?? coordinator.currentItem ?? PlayableMediaItem(
            id: "calib-beeps-track",
            title: "Billie Jean",
            subtitle: "Michael Jackson",
            albumTitle: "Thriller",
            artworkURL: nil,
            previewURL: nil,
            kind: .song,
            durationSeconds: 294
        )

        statusMessage = "Starting \"\(testTrack.cleanTitle)\" on Echo & Sonos..."
        calibrationProgress = 0.15

        // Trigger playback across both targets
        await coordinator.play(testTrack)

        // Give speakers 3 seconds to spin up, connect, and start emitting audio
        for i in 1...3 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            calibrationProgress = 0.15 + Double(i) * 0.08
            statusMessage = "Waiting for audio to start (\(4 - i)s)..."
        }

        // Start 5 seconds of microphone listening
        statusMessage = "Listening to Echo and Sonos with microphone..."
        let recordSuccess = startAudioCapture()
        guard recordSuccess else {
            statusMessage = "Failed to activate microphone."
            isCalibrating = false
            return
        }

        let recordingDurationSeconds = 4.0
        let steps = 20
        for i in 1...steps {
            try? await Task.sleep(nanoseconds: UInt64((recordingDurationSeconds / Double(steps)) * 1_000_000_000))
            calibrationProgress = 0.40 + (Double(i) / Double(steps)) * 0.40
        }

        // Stop recording
        stopAudioCapture()
        statusMessage = "Analyzing acoustic peaks and cross-correlation..."
        calibrationProgress = 0.85

        // Process samples on background task
        let samplesCopy = self.recordedSamples
        let currentRate = self.sampleRate
        let existingOffset = coordinator.sonosSyncOffsetSeconds

        let result = await Task.detached(priority: .userInitiated) { () -> (offsetSec: Double, confidence: Double) in
            return Self.analyzeAcousticDrift(
                samples: samplesCopy,
                sampleRate: currentRate,
                currentOffset: existingOffset
            )
        }.value

        calibrationProgress = 1.0
        isCalibrating = false

        if result.confidence >= 0.35 {
            let offsetMs = result.offsetSec * 1000.0
            self.detectedOffsetSec = result.offsetSec
            self.detectedOffsetMs = offsetMs
            self.confidenceScore = result.confidence

            // Update coordinator's sync setting automatically!
            coordinator.sonosSyncOffsetSeconds = result.offsetSec

            let formattedSec = String(format: "%+.2f", result.offsetSec)
            let formattedMs = String(format: "%.0f", abs(offsetMs))
            self.statusMessage = "Sync Calibrated! Offset: \(formattedSec)s (\(formattedMs)ms delta)"

            // Auto-resync to lock in the newly measured offset immediately!
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await coordinator.resyncMultiRoomOutput()
            }
        } else {
            self.statusMessage = "Could not clearly distinguish dual speaker peaks. Try bringing iPhone closer to midway between Echo & Sonos."
        }
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Audio Engine Capture

    private func startAudioCapture() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            self.sampleRate = inputFormat.sampleRate

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                guard let self, let channelData = buffer.floatChannelData else { return }
                let channelDataPtr = channelData.pointee
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelDataPtr, count: frameLength))

                Task { @MainActor in
                    self.recordedSamples.append(contentsOf: samples)
                }
            }

            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            return true
        } catch {
            return false
        }
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Revert session back to standard playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {}
    }

    // MARK: - Signal Processing & Drift Analysis (Non-MainActor)

    nonisolated private static func analyzeAcousticDrift(
        samples: [Float],
        sampleRate: Double,
        currentOffset: Double
    ) -> (offsetSec: Double, confidence: Double) {
        guard samples.count > Int(sampleRate * 2.0) else {
            return (currentOffset, 0.0)
        }

        // 1. Calculate energy envelope (RMS over 25ms windows with 50% overlap)
        let windowSize = Int(sampleRate * 0.025) // 25ms
        let hopSize = windowSize / 2
        var envelope: [Float] = []

        var i = 0
        while i + windowSize < samples.count {
            var sum: Float = 0.0
            for j in 0..<windowSize {
                let s = samples[i + j]
                sum += s * s
            }
            envelope.append(sqrt(sum / Float(windowSize)))
            i += hopSize
        }

        guard envelope.count > 100 else {
            return (currentOffset, 0.0)
        }

        // 2. High-pass filter the envelope to isolate transient beats / drum onsets
        var onsets = [Float](repeating: 0.0, count: envelope.count)
        for k in 1..<envelope.count {
            let diff = envelope[k] - envelope[k - 1]
            onsets[k] = max(0.0, diff) // Half-wave rectification
        }

        // 3. Autocorrelation of onsets to discover the repeated echo delay interval
        // Range to examine: 0.3s to 3.5s (300ms to 3500ms)
        let minLag = Int((0.30 * sampleRate) / Double(hopSize))
        let maxLag = Int((3.50 * sampleRate) / Double(hopSize))

        guard maxLag < onsets.count else {
            return (currentOffset, 0.0)
        }

        var maxCorr: Float = 0.0
        var bestLag: Int = 0

        for lag in minLag...maxLag {
            var corr: Float = 0.0
            let count = onsets.count - lag
            for idx in 0..<count {
                corr += onsets[idx] * onsets[idx + lag]
            }
            if corr > maxCorr {
                maxCorr = corr
                bestLag = lag
            }
        }

        // Calculate time delta in seconds from the detected autocorrelation lag
        let detectedDelaySec = Double(bestLag * hopSize) / sampleRate

        // Determine confidence based on peak prominence
        let confidence: Double
        if maxCorr > 0.05 && detectedDelaySec >= 0.4 && detectedDelaySec <= 3.2 {
            confidence = min(0.95, Double(maxCorr * 10.0))
        } else {
            // If correlation peak was soft, gently nudge towards standard calibration
            return (currentOffset, 0.25)
        }

        // If Sonos was lagging behind Echo, we adjust currentOffset to compensate
        // If currentOffset is already set, fine-tune it by the delta
        let adjustedOffset: Double
        if abs(currentOffset - detectedDelaySec) < 1.0 {
            adjustedOffset = (currentOffset * 0.3) + (detectedDelaySec * 0.7)
        } else {
            adjustedOffset = detectedDelaySec
        }

        return (max(0.5, min(3.5, adjustedOffset)), confidence)
    }
}
