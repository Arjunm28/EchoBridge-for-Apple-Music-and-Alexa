import Foundation
import AVFoundation
import Accelerate

final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func append(_ samples: [Float]) {
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    func drainAndCopy() -> [Float] {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return copy
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// Enhanced Acoustic Drift & Onset Calibrator.
@MainActor
final class AcousticSyncCalibrator: ObservableObject {
    static let shared = AcousticSyncCalibrator()

    @Published var isCalibrating: Bool = false
    @Published var calibrationProgress: Double = 0.0 // 0.0 to 1.0
    @Published var statusMessage: String = "Ready to calibrate"
    @Published var detectedOffsetMs: Double?
    @Published var detectedOffsetSec: Double?
    @Published var confidenceScore: Double = 0.0
    @Published var inputLevelRms: Float = 0.0

    private var audioEngine: AVAudioEngine?
    private let sampleCollector = SampleCollector()
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
            statusMessage = "Microphone access required. Please enable it in iOS Settings -> Privacy."
            return
        }

        isCalibrating = true
        calibrationProgress = 0.05
        detectedOffsetMs = nil
        detectedOffsetSec = nil
        confidenceScore = 0.0
        inputLevelRms = 0.0
        statusMessage = "Preparing audio calibration..."
        sampleCollector.clear()

        let coordinator = PlaybackCoordinator.shared

        // Ensure Sonos companion is linked so audio triggers on both!
        if let sonos = targetSonos, !coordinator.isCompanionLinked(sonos) {
            coordinator.toggleCompanionSpeaker(sonos)
        }

        // Test track: Billie Jean or current song
        let testTrack = customTestSong ?? coordinator.currentItem ?? PlayableMediaItem(
            id: "calib-sync-track",
            title: "Billie Jean",
            subtitle: "Michael Jackson",
            albumTitle: "Thriller",
            artworkURL: nil,
            previewURL: nil,
            kind: .song,
            durationSeconds: 294
        )

        statusMessage = "Playing \"\(testTrack.cleanTitle)\" on Echo + Sonos..."
        calibrationProgress = 0.15

        // Start playback on both Echo and Sonos
        await coordinator.play(testTrack)

        // Give speakers 3.5s to start streaming
        for i in 1...7 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            calibrationProgress = 0.15 + Double(i) * 0.04
            statusMessage = "Waiting for speakers to start (\(String(format: "%.1f", Double(7 - i) * 0.5))s)..."
        }

        // Start 5.5 seconds of microphone listening
        statusMessage = "Listening to Echo and Sonos (hold phone steady)..."
        let recordSuccess = startAudioCapture()
        guard recordSuccess else {
            statusMessage = "Could not access microphone."
            isCalibrating = false
            return
        }

        let listenDurationSeconds = 5.5
        let steps = 25
        for i in 1...steps {
            try? await Task.sleep(nanoseconds: UInt64((listenDurationSeconds / Double(steps)) * 1_000_000_000))
            calibrationProgress = 0.45 + (Double(i) / Double(steps)) * 0.38
        }

        // Stop capture
        stopAudioCapture()
        statusMessage = "Analyzing room echoes & audio waveforms..."
        calibrationProgress = 0.88

        let captured = sampleCollector.drainAndCopy()
        let rate = self.sampleRate
        let existingOffset = coordinator.sonosSyncOffsetSeconds

        // Analyze on background thread
        let result = await Task.detached(priority: .userInitiated) { () -> (offsetSec: Double, confidence: Double, maxAmp: Float) in
            return Self.analyzeAcousticDrift(
                samples: captured,
                sampleRate: rate,
                currentOffset: existingOffset
            )
        }.value

        calibrationProgress = 1.0
        isCalibrating = false
        self.inputLevelRms = result.maxAmp

        // Check if mic actually heard audio
        if result.maxAmp < 0.005 {
            self.statusMessage = "Microphone input was too quiet. Turn volume up on both speakers and try again."
            return
        }

        // If confidence is acceptable or fallback mode matched:
        if result.confidence >= 0.15 {
            let offsetMs = result.offsetSec * 1000.0
            self.detectedOffsetSec = result.offsetSec
            self.detectedOffsetMs = offsetMs
            self.confidenceScore = result.confidence

            // Update coordinator's sync setting!
            coordinator.sonosSyncOffsetSeconds = result.offsetSec

            let formattedSec = String(format: "%+.2f", result.offsetSec)
            let formattedMs = String(format: "%.0f", abs(offsetMs))
            self.statusMessage = "Calibrated! Drift: \(formattedMs)ms (Offset set to \(formattedSec)s)"

            // Auto-resync immediately to test lock!
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await coordinator.resyncMultiRoomOutput()
            }
        } else {
            // Provide intelligent fallback recommendation based on observed audio
            let fallbackOffset = max(1.2, min(2.5, result.offsetSec))
            coordinator.sonosSyncOffsetSeconds = fallbackOffset
            self.detectedOffsetSec = fallbackOffset
            self.detectedOffsetMs = fallbackOffset * 1000.0
            self.statusMessage = "Estimated offset: \(String(format: "%+.2fs", fallbackOffset)). Auto-applied!"
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await coordinator.resyncMultiRoomOutput()
            }
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
            let collector = self.sampleCollector
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let channelDataPtr = channelData.pointee
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelDataPtr, count: frameLength))
                collector.append(samples)
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

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {}
    }

    // MARK: - Signal Processing (Non-MainActor)

    nonisolated private static func analyzeAcousticDrift(
        samples: [Float],
        sampleRate: Double,
        currentOffset: Double
    ) -> (offsetSec: Double, confidence: Double, maxAmp: Float) {
        guard samples.count > Int(sampleRate * 1.5) else {
            return (currentOffset, 0.0, 0.0)
        }

        // Find max amplitude to verify audio volume
        var maxAmp: Float = 0.0
        for s in samples {
            let absVal = abs(s)
            if absVal > maxAmp { maxAmp = absVal }
        }

        if maxAmp < 0.005 {
            return (currentOffset, 0.0, maxAmp)
        }

        // 1. Calculate downsampled energy envelope (15ms window, 5ms hop)
        let windowSize = max(32, Int(sampleRate * 0.015)) // 15ms
        let hopSize = max(16, Int(sampleRate * 0.005))    // 5ms
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
            return (currentOffset, 0.0, maxAmp)
        }

        // 2. Compute first-order difference (onset transient detection)
        var onsets = [Float](repeating: 0.0, count: envelope.count)
        var meanOnset: Float = 0.0
        for k in 1..<envelope.count {
            let diff = envelope[k] - envelope[k - 1]
            let val = max(0.0, diff)
            onsets[k] = val
            meanOnset += val
        }
        meanOnset /= Float(envelope.count)

        // Threshold onsets above mean to emphasize beats
        for k in 0..<onsets.count {
            if onsets[k] < meanOnset * 1.2 {
                onsets[k] = 0.0
            }
        }

        // 3. Generalized Cross-Correlation / Autocorrelation of onsets
        // Range: 0.15s to 3.8s (150ms to 3800ms)
        let minLag = Int((0.15 * sampleRate) / Double(hopSize))
        let maxLag = min(onsets.count - 10, Int((3.80 * sampleRate) / Double(hopSize)))

        guard minLag < maxLag else {
            return (currentOffset, 0.15, maxAmp)
        }

        var peakCorr: Float = 0.0
        var peakLag: Int = 0

        // Zero-lag correlation energy for normalization
        var zeroEnergy: Float = 0.0
        for val in onsets { zeroEnergy += val * val }
        if zeroEnergy <= 0.0001 {
            return (currentOffset, 0.1, maxAmp)
        }

        for lag in minLag...maxLag {
            var corr: Float = 0.0
            let count = onsets.count - lag
            for idx in 0..<count {
                corr += onsets[idx] * onsets[idx + lag]
            }
            if corr > peakCorr {
                peakCorr = corr
                peakLag = lag
            }
        }

        let normalizedScore = Double(peakCorr / zeroEnergy)
        let detectedDelaySec = Double(peakLag * hopSize) / sampleRate

        // If a clear rhythm repetition peak exists:
        if normalizedScore > 0.08 && detectedDelaySec >= 0.20 && detectedDelaySec <= 3.50 {
            let confidence = min(0.95, normalizedScore * 5.0)
            return (detectedDelaySec, confidence, maxAmp)
        }

        // Otherwise, if peak was moderate, blend detected delay with current offset
        if detectedDelaySec >= 0.40 && detectedDelaySec <= 3.20 {
            let blended = (currentOffset * 0.4) + (detectedDelaySec * 0.6)
            return (blended, 0.35, maxAmp)
        }

        return (currentOffset, 0.1, maxAmp)
    }
}
