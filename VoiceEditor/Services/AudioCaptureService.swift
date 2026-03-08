import AVFoundation
import Accelerate

final class AudioCaptureService {
    private let silenceThreshold: Float = 0.015
    private let silenceDurationLimit: TimeInterval = 1.5
    private let maxRecordingDuration: TimeInterval = 30.0

    /// Minimum samples (1 second at 16 kHz) before we attempt transcription.
    private static let minSamples = 16_000

    /// Minimum RMS energy for the recorded samples to be considered speech.
    /// Below this, the audio is just ambient noise / silence — reject before transcription.
    private static let minRMSEnergy: Float = 0.005

    /// Serial queue for off-RT-thread resampling and buffer accumulation.
    private let processingQueue = DispatchQueue(label: "com.voiceeditor.audio-processing")

    /// Records microphone input until silence is detected and returns 16 kHz mono Float32 samples.
    func recordUntilSilence() async throws -> [Float] {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphoneNotGranted
        }

        let (engine, inputNode, hwFormat) = try startEngineWithRetries()

        let audioBuffer = ThreadSafeAudioBuffer()
        let hwSampleRate = hwFormat.sampleRate
        let processingQ = self.processingQueue

        let threshold = self.silenceThreshold
        let silenceLimit = self.silenceDurationLimit
        let maxDuration = self.maxRecordingDuration

        let stream = AsyncStream<Void> { continuation in
            var silenceDuration: TimeInterval = 0
            var totalDuration: TimeInterval = 0
            var hasReceivedAudio = false

            inputNode.removeTap(onBus: 0)

            // Tap callback: ultra-lightweight — RMS + buffer copy, then dispatch heavy work
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
                let frames = buffer.frameLength
                guard frames > 0 else { return }

                let duration = Double(frames) / hwSampleRate
                totalDuration += duration

                // RMS via Accelerate — safe on RT thread
                let rms = Self.calculateRMS(buffer: buffer)

                if rms > threshold {
                    hasReceivedAudio = true
                    silenceDuration = 0
                } else if hasReceivedAudio {
                    silenceDuration += duration
                }

                // Copy buffer before dispatching — Core Audio reuses memory after callback
                guard let copy = Self.copyBuffer(buffer) else { return }

                // Resample to 16 kHz mono on background queue
                processingQ.async {
                    let samples = Self.toMono16k(buffer: copy)
                    audioBuffer.append(samples)
                }

                let shouldStop =
                    (hasReceivedAudio && silenceDuration >= silenceLimit)
                    || totalDuration >= maxDuration

                if shouldStop {
                    continuation.yield()
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }

        for await _ in stream {
            break
        }

        // Flush any pending processing before reading the buffer
        processingQueue.sync {}

        let samples = audioBuffer.getAll()
        guard samples.count >= Self.minSamples else {
            throw AudioCaptureError.emptyRecording
        }

        // Reject near-silent recordings before they reach the STT model
        // (prevents Whisper hallucinations on ambient noise)
        let rms = Self.calculateRMSOfSamples(samples)
        guard rms >= Self.minRMSEnergy else {
            throw AudioCaptureError.tooQuiet
        }

        return samples
    }

    // MARK: - Continuous Recording (Dictation)

    /// A long-running recording session that auto-detects silence.
    /// Audio accumulates in `audioBuffer`; the caller reads it periodically
    /// and checks `isSilenceDetected` to know when the user stopped speaking.
    final class ContinuousSession: @unchecked Sendable {
        let audioBuffer = ThreadSafeAudioBuffer()
        private let engine: AVAudioEngine
        private let inputNode: AVAudioInputNode
        private let processingQueue = DispatchQueue(label: "com.voiceeditor.dictation-processing")
        private var stopped = false

        /// Thread-safe flag set when silence is detected after speech.
        private let silenceFlag = LockedFlag()
        var isSilenceDetected: Bool { silenceFlag.value }

        /// Current audio level (RMS) — updated every tap callback (~93ms at 4096/44.1kHz).
        /// Read by the overlay to drive waveform animation.
        private let _audioLevel = LockedFloat()
        var audioLevel: Float { _audioLevel.value }

        fileprivate init(engine: AVAudioEngine, inputNode: AVAudioInputNode, hwFormat: AVAudioFormat) {
            self.engine = engine
            self.inputNode = inputNode

            let buffer = self.audioBuffer
            let queue = self.processingQueue
            let flag = self.silenceFlag
            let level = self._audioLevel
            let hwSampleRate = hwFormat.sampleRate

            // Mutable state captured by the tap closure (audio thread only)
            var hasReceivedAudio = false
            var silenceDuration: TimeInterval = 0
            let silenceThreshold: Float = 0.015
            let silenceLimit: TimeInterval = 1.5

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { pcmBuffer, _ in
                let frames = pcmBuffer.frameLength
                guard frames > 0 else { return }

                // Silence detection
                let duration = Double(frames) / hwSampleRate
                let rms = AudioCaptureService.calculateRMS(buffer: pcmBuffer)

                // Publish level for waveform visualization
                level.set(rms)

                if rms > silenceThreshold {
                    hasReceivedAudio = true
                    silenceDuration = 0
                } else if hasReceivedAudio {
                    silenceDuration += duration
                    if silenceDuration >= silenceLimit {
                        flag.set()
                    }
                }

                guard let copy = AudioCaptureService.copyBuffer(pcmBuffer) else { return }

                queue.async {
                    let samples = AudioCaptureService.toMono16k(buffer: copy)
                    buffer.append(samples)
                }
            }
        }

        /// Stops recording, removes the tap, and flushes pending audio processing.
        func stop() {
            guard !stopped else { return }
            stopped = true
            inputNode.removeTap(onBus: 0)
            engine.stop()
            processingQueue.sync {}
        }
    }

    /// Starts a continuous recording session for dictation.
    /// Returns a `ContinuousSession` whose `audioBuffer` grows as audio arrives.
    /// Call `session.stop()` when done.
    func startContinuousRecording() throws -> ContinuousSession {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphoneNotGranted
        }

        let (engine, inputNode, hwFormat) = try startEngineWithRetries()
        return ContinuousSession(engine: engine, inputNode: inputNode, hwFormat: hwFormat)
    }

    // MARK: - Engine Start with Retries

    /// Attempts to start AVAudioEngine up to 3 times, recreating between attempts.
    /// Returns the started engine, its input node, and the hardware format.
    private func startEngineWithRetries() throws -> (AVAudioEngine, AVAudioInputNode, AVAudioFormat) {
        var lastError: Error?

        for attempt in 1...3 {
            let engine = AVAudioEngine()
            // Access inputNode BEFORE prepare() — this forces the engine to
            // create its I/O node graph. Without this, prepare() asserts
            // "inputNode != nullptr || outputNode != nullptr".
            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            guard hwFormat.sampleRate > 0 else {
                lastError = AudioCaptureError.noAudioInput
                if attempt < 3 { engine.stop() }
                continue
            }

            engine.prepare()

            do {
                try engine.start()
                return (engine, inputNode, hwFormat)
            } catch {
                lastError = error

                if attempt < 3 {
                    // Engine is in a bad state — let it deallocate before retrying
                    engine.stop()
                }
            }
        }

        throw AudioCaptureError.engineStartFailed(
            lastError ?? NSError(
                domain: "AudioCaptureService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown engine start failure"]
            )
        )
    }

    // MARK: - Manual Resampling (matches FluidVoice pattern)

    /// Converts an AVAudioPCMBuffer to 16 kHz mono [Float].
    /// Fast-path: if already 16 kHz mono, just copies the data.
    private static func toMono16k(buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        if format.sampleRate == 16_000.0,
           format.commonFormat == .pcmFormatFloat32,
           format.channelCount == 1,
           let channelData = buffer.floatChannelData
        {
            let frameCount = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        let mono = downmixToMono(buffer)
        return resampleTo16k(mono, sourceSampleRate: format.sampleRate)
    }

    /// Downmixes multi-channel audio to mono using vDSP.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            let src = channelData[c]
            vDSP_vadd(src, 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        var div = Float(channels)
        vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(frameCount))
        return mono
    }

    /// Linear-interpolation resample to 16 kHz.
    private static func resampleTo16k(_ samples: [Float], sourceSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if sourceSampleRate == 16_000.0 { return samples }
        let ratio = 16_000.0 / sourceSampleRate
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] + (samples[idx + 1] - samples[idx]) * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }

    // MARK: - Helpers

    enum AudioCaptureError: LocalizedError {
        case microphoneNotGranted
        case noAudioInput
        case engineStartFailed(Error)
        case emptyRecording
        case tooQuiet

        var errorDescription: String? {
            switch self {
            case .microphoneNotGranted:
                return "Microphone access not granted. Open Preferences → General to grant it."
            case .noAudioInput:
                return "No audio input available. Check your microphone."
            case .engineStartFailed(let underlying):
                return "Audio engine failed to start: \(underlying.localizedDescription)"
            case .emptyRecording:
                return "Recording produced no audio. Check your microphone."
            case .tooQuiet:
                return "Recording was too quiet — no speech detected."
            }
        }
    }

    /// RMS of a flat [Float] sample array (for post-recording energy check).
    private static func calculateRMSOfSamples(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrtf(meanSquare)
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(channelData[0], 1, &meanSquare, vDSP_Length(count))
        return sqrtf(meanSquare)
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength

        guard let srcChannels = source.floatChannelData,
              let dstChannels = copy.floatChannelData else { return nil }

        let channelCount = Int(source.format.channelCount)
        let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
        for ch in 0..<channelCount {
            memcpy(dstChannels[ch], srcChannels[ch], byteCount)
        }
        return copy
    }
}

/// A thread-safe write-once boolean flag.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock()
        _value = true
        lock.unlock()
    }
}

/// A thread-safe float for publishing audio level from the RT thread to the UI.
final class LockedFloat: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float = 0

    var value: Float {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Float) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}
