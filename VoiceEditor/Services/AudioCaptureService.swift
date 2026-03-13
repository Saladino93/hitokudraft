import AVFoundation
import Accelerate
import os

final class AudioCaptureService {
    private let silenceThreshold: Float = 0.015
    private var silenceDurationLimit: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "silenceDurationLimit")
        return v > 0 ? v : 2.0
    }
    private var maxRecordingDuration: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "maxRecordingDuration")
        return v > 0 ? v : 30.0
    }

    /// Minimum samples (1 second at 16 kHz) before we attempt transcription.
    private static let minSamples = 16_000

    /// Minimum RMS energy for the recorded samples to be considered speech.
    /// Below this, the audio is just ambient noise / silence — reject before transcription.
    private static let minRMSEnergy: Float = 0.01

    /// Target format for STT: 16 kHz, mono, Float32, non-interleaved.
    private static let sttFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static let log = Logger(subsystem: "com.hitokudraft.audio", category: "capture")

    /// Serial queue for off-RT-thread resampling and buffer accumulation.
    private let processingQueue = DispatchQueue(label: "com.hitokudraft.audio-processing")

    /// Records microphone input until silence is detected and returns 16 kHz mono Float32 samples.
    func recordUntilSilence() async throws -> [Float] {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Self.log.error("Microphone permission not granted")
            throw AudioCaptureError.microphoneNotGranted
        }

        let (engine, inputNode, tapFormat) = try await startEngineWithRetries()

        let audioBuffer = ThreadSafeAudioBuffer()
        let tapSampleRate = tapFormat.sampleRate
        let processingQ = self.processingQueue

        let threshold = self.silenceThreshold
        let silenceLimit = self.silenceDurationLimit
        let maxDuration = self.maxRecordingDuration

        Self.log.info("recordUntilSilence: starting with tapFormat=\(tapFormat, privacy: .public)")

        let stream = AsyncStream<Void> { continuation in
            var silenceDuration: TimeInterval = 0
            var totalDuration: TimeInterval = 0
            var hasReceivedAudio = false

            inputNode.removeTap(onBus: 0)

            // Tap callback: ultra-lightweight — RMS + buffer copy, then dispatch heavy work.
            // format: tapFormat guarantees Float32 non-interleaved delivery.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                let frames = buffer.frameLength
                guard frames > 0 else { return }

                let duration = Double(frames) / tapSampleRate
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
                guard let copy = Self.copyBuffer(buffer) else {
                    Self.log.warning("copyBuffer failed — skipping \(frames) frames")
                    return
                }

                // Resample to 16 kHz mono on background queue — fresh converter per buffer
                processingQ.async {
                    let samples = Self.convertToSTT(copy)
                    audioBuffer.append(samples)
                }

                let shouldStop =
                    (hasReceivedAudio && silenceDuration >= silenceLimit)
                    || totalDuration >= maxDuration

                if shouldStop {
                    Self.log.info("recordUntilSilence: stopping — hasAudio=\(hasReceivedAudio) silenceDur=\(silenceDuration, format: .fixed(precision: 2))s totalDur=\(totalDuration, format: .fixed(precision: 2))s")
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
        Self.log.info("recordUntilSilence: total accumulated samples=\(samples.count)")

        guard samples.count >= Self.minSamples else {
            Self.log.warning("recordUntilSilence: too few samples (\(samples.count) < \(Self.minSamples)) — emptyRecording")
            throw AudioCaptureError.emptyRecording
        }

        // Reject near-silent recordings before they reach the STT model
        // (prevents Whisper hallucinations on ambient noise)
        let rms = Self.calculateRMSOfSamples(samples)
        guard rms >= Self.minRMSEnergy else {
            Self.log.warning("recordUntilSilence: RMS \(rms) < minEnergy \(Self.minRMSEnergy) — tooQuiet")
            throw AudioCaptureError.tooQuiet
        }

        Self.log.info("recordUntilSilence: success — \(samples.count) samples, RMS=\(rms)")
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
        private let processingQueue = DispatchQueue(label: "com.hitokudraft.dictation-processing")
        private var stopped = false

        /// Thread-safe flag set when silence is detected after speech.
        private let silenceFlag = LockedFlag()
        var isSilenceDetected: Bool { silenceFlag.value }

        /// Current audio level (RMS) — updated every tap callback (~93ms at 4096/44.1kHz).
        /// Read by the overlay to drive waveform animation.
        private let _audioLevel = LockedFloat()
        var audioLevel: Float { _audioLevel.value }

        fileprivate init(engine: AVAudioEngine, inputNode: AVAudioInputNode,
                         tapFormat: AVAudioFormat, silenceDurationLimit: TimeInterval) {
            self.engine = engine
            self.inputNode = inputNode

            let buffer = self.audioBuffer
            let queue = self.processingQueue
            let flag = self.silenceFlag
            let level = self._audioLevel
            let tapSampleRate = tapFormat.sampleRate

            // Mutable state captured by the tap closure (audio thread only)
            var hasReceivedAudio = false
            var silenceDuration: TimeInterval = 0
            let silenceThreshold: Float = 0.015
            let silenceLimit = silenceDurationLimit
            var cumulativeSamples = 0

            AudioCaptureService.log.info("ContinuousSession: starting with tapFormat=\(tapFormat, privacy: .public)")

            inputNode.removeTap(onBus: 0)
            // format: tapFormat guarantees Float32 non-interleaved delivery
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { pcmBuffer, _ in
                let frames = pcmBuffer.frameLength
                guard frames > 0 else { return }

                // Silence detection
                let duration = Double(frames) / tapSampleRate
                let rms = AudioCaptureService.calculateRMS(buffer: pcmBuffer)

                // Publish level for waveform visualization
                level.set(rms)

                if rms > silenceThreshold {
                    hasReceivedAudio = true
                    silenceDuration = 0
                } else if hasReceivedAudio {
                    silenceDuration += duration
                    if silenceDuration >= silenceLimit {
                        AudioCaptureService.log.info("ContinuousSession: silence detected after \(silenceDuration, format: .fixed(precision: 2))s")
                        flag.set()
                    }
                }

                guard let copy = AudioCaptureService.copyBuffer(pcmBuffer) else {
                    AudioCaptureService.log.warning("ContinuousSession: copyBuffer failed — skipping \(frames) frames")
                    return
                }

                // Fresh converter per buffer — no statefulness
                queue.async {
                    let samples = AudioCaptureService.convertToSTT(copy)
                    buffer.append(samples)
                    cumulativeSamples += samples.count
                    // Log periodically (~every 2 seconds at 16 kHz)
                    if cumulativeSamples % 32_000 < samples.count {
                        AudioCaptureService.log.info("ContinuousSession: cumulative STT samples=\(cumulativeSamples)")
                    }
                }
            }
        }

        /// Stops recording, removes the tap, and drains pending audio processing.
        /// Uses async drain instead of sync to avoid blocking the calling thread.
        func stop() {
            guard !stopped else { return }
            stopped = true
            inputNode.removeTap(onBus: 0)
            engine.stop()
            processingQueue.async {
                AudioCaptureService.log.info("ContinuousSession: stopped, processing drained")
            }
        }
    }

    /// Starts a continuous recording session for dictation.
    /// Returns a `ContinuousSession` whose `audioBuffer` grows as audio arrives.
    /// Call `session.stop()` when done.
    func startContinuousRecording() async throws -> ContinuousSession {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Self.log.error("Microphone permission not granted")
            throw AudioCaptureError.microphoneNotGranted
        }

        let (engine, inputNode, tapFormat) = try await startEngineWithRetries()
        return ContinuousSession(engine: engine, inputNode: inputNode, tapFormat: tapFormat,
                                 silenceDurationLimit: silenceDurationLimit)
    }

    // MARK: - Engine Start with Retries

    /// Attempts to start AVAudioEngine up to 3 times, recreating between attempts.
    /// Returns the started engine, its input node, and a Float32 tap format.
    ///
    /// The tap format is Float32/non-interleaved at the hardware sample rate and channel count.
    /// Passing this to `installTap(format:)` makes AVAudioEngine normalize audio internally,
    /// guaranteeing `floatChannelData` is always non-nil in the tap callback.
    private func startEngineWithRetries() async throws -> (AVAudioEngine, AVAudioInputNode, AVAudioFormat) {
        var lastError: Error?
        var formatFailureCount = 0

        for attempt in 1...3 {
            let engine = AVAudioEngine()
            // Access inputNode BEFORE prepare() — this forces the engine to
            // create its I/O node graph. Without this, prepare() asserts
            // "inputNode != nullptr || outputNode != nullptr".
            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                Self.log.warning("Attempt \(attempt): invalid hwFormat (sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)) — no usable audio input")
                lastError = AudioCaptureError.noAudioInput
                formatFailureCount += 1
                if attempt < 3 {
                    engine.stop()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                continue
            }

            // Negotiate a Float32 tap format at hardware sample rate / channel count.
            // AVAudioEngine handles the conversion from hardware format internally.
            guard let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hwFormat.sampleRate,
                channels: hwFormat.channelCount,
                interleaved: false
            ) else {
                Self.log.warning("Attempt \(attempt): AVAudioFormat returned nil for sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)")
                lastError = AudioCaptureError.noAudioInput
                formatFailureCount += 1
                if attempt < 3 {
                    engine.stop()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                continue
            }

            Self.log.info("Attempt \(attempt): hwFormat=\(hwFormat, privacy: .public) → tapFormat=\(tapFormat, privacy: .public)")

            engine.prepare()

            do {
                try engine.start()
                Self.log.info("Engine started successfully on attempt \(attempt)")
                return (engine, inputNode, tapFormat)
            } catch {
                Self.log.error("Attempt \(attempt): engine.start() failed — \(error.localizedDescription, privacy: .public)")
                lastError = error

                if attempt < 3 {
                    // Engine is in a bad state — let it deallocate before retrying
                    engine.stop()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        // All retries exhausted — distinguish "mic in use" from "no mic at all"
        if formatFailureCount == 3 {
            let hasDevice = AVCaptureDevice.default(for: .audio) != nil
            if hasDevice {
                Self.log.warning("All 3 attempts got invalid format but a device exists — likely another app contention")
                throw AudioCaptureError.microphoneInUse
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

    // MARK: - Format Conversion

    /// Converts a tap-format PCM buffer to 16 kHz mono Float32 samples for STT.
    ///
    /// Creates a **fresh** AVAudioConverter per call to avoid statefulness bugs.
    /// The old shared-converter approach broke after the first buffer because
    /// `.endOfStream` put the converter in a terminal state.
    static func convertToSTT(_ source: AVAudioPCMBuffer) -> [Float] {
        let frameCount = source.frameLength
        guard frameCount > 0 else { return [] }

        guard let converter = AVAudioConverter(from: source.format, to: sttFormat) else {
            log.error("convertToSTT: cannot create converter from \(source.format, privacy: .public) to \(sttFormat, privacy: .public)")
            return []
        }

        let ratio = sttFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: sttFormat, frameCapacity: capacity) else {
            log.error("convertToSTT: cannot allocate output buffer with capacity \(capacity)")
            return []
        }

        var inputConsumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return source
        }

        if let error = conversionError {
            log.error("convertToSTT: conversion error — \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard let data = output.floatChannelData, output.frameLength > 0 else {
            log.warning("convertToSTT: output has 0 frames from \(frameCount) input frames")
            return []
        }

        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: - Helpers

    enum AudioCaptureError: LocalizedError {
        case microphoneNotGranted
        case noAudioInput
        case microphoneInUse
        case engineStartFailed(Error)
        case emptyRecording
        case tooQuiet

        var errorDescription: String? {
            switch self {
            case .microphoneNotGranted:
                return L("error.mic_not_granted")
            case .noAudioInput:
                return L("error.no_audio_input")
            case .microphoneInUse:
                return L("error.mic_in_use")
            case .engineStartFailed(let underlying):
                return L("error.engine_failed", underlying.localizedDescription)
            case .emptyRecording:
                return L("error.empty_recording")
            case .tooQuiet:
                return L("error.too_quiet")
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

    /// RMS of a PCM buffer. Fast path uses `floatChannelData` (guaranteed non-nil
    /// when tap format is Float32). Fallback logs a warning and returns 0.
    static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            log.warning("calculateRMS: floatChannelData is nil — format may not be Float32 (\(buffer.format, privacy: .public))")
            return 0
        }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(channelData[0], 1, &meanSquare, vDSP_Length(count))
        return sqrtf(meanSquare)
    }

    /// Copies a PCM buffer so we can dispatch it off the real-time audio thread.
    /// Fast path uses `floatChannelData` (guaranteed non-nil with Float32 tap format).
    /// Fallback uses raw memcpy via AudioBufferList for any sample format.
    static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength

        // Fast path: Float32 non-interleaved (guaranteed by tap format negotiation)
        if let srcChannels = source.floatChannelData,
           let dstChannels = copy.floatChannelData {
            let channelCount = Int(source.format.channelCount)
            let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
            for ch in 0..<channelCount {
                memcpy(dstChannels[ch], srcChannels[ch], byteCount)
            }
            return copy
        }

        // Format-safe fallback: raw memcpy via AudioBufferList — works for any sample format
        log.warning("copyBuffer: floatChannelData nil — using raw AudioBufferList copy (format: \(source.format, privacy: .public))")
        let srcBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dstBufs = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<srcBufs.count {
            let src = srcBufs[i]
            let dst = dstBufs[i]
            guard let srcData = src.mData, let dstData = dst.mData else {
                log.warning("copyBuffer: mData is nil for buffer \(i)")
                continue
            }
            memcpy(dstData, srcData, Int(src.mDataByteSize))
        }

        return copy
    }
}

/// A thread-safe write-once boolean flag.
final class LockedFlag: @unchecked Sendable {
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
