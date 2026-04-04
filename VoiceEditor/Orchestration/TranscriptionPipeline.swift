import Foundation
import os

private let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")

/// Runs the appropriate streaming loop for the current STT backend.
/// - **Path A** (legacy): 300ms re-transcription of the growing buffer
/// - **Path B** (native): Qwen3-ASR `StreamingInferenceSession`
///
/// Returns the final transcription text once silence is detected or the task is cancelled.
func runStreamingTranscription(
    session: AudioCaptureService.ContinuousSession,
    stt: any STTService,
    onTextUpdate: @escaping @MainActor (String) -> Void
) async -> String {
    // Path B: Native streaming — any STTService that supports it
    if let streamSession = stt.makeStreamingSession() {

        // Shared state — written by event task, read after it completes.
        // LockedString provides thread-safe access without nonisolated(unsafe).
        let lastConfirmed = LockedString()

        // Event listener — updates overlay with confirmed + provisional text
        let eventTask = Task.detached {
            for await event in streamSession.events {
                switch event {
                case .displayUpdate(let confirmedText, let provisionalText):
                    let display = confirmedText + provisionalText
                    lastConfirmed.set(confirmedText)
                    if !display.isEmpty {
                        await onTextUpdate(display)
                    }
                case .ended(let fullText):
                    lastConfirmed.set(fullText)
                }
            }
        }

        // Audio feed loop — polls buffer for new samples every 100ms
        var lastFedCount = 0
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled || session.isSilenceDetected { break }

            let currentCount = session.audioBuffer.count
            if currentCount > lastFedCount {
                let newSamples = session.audioBuffer.getSuffix(from: lastFedCount)
                streamSession.feedAudio(samples: newSamples)
                lastFedCount = currentCount
            }
        }

        // Flush pending audio, promote provisional tokens, emit .ended
        streamSession.stop()
        // Race eventTask against a 30s timeout so a stalled MLX session can't hang forever
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await eventTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(30)) }
            _ = await group.next()
            group.cancelAll()
        }
        return lastConfirmed.value ?? ""
    }

    // Path A: Non-blocking polling for non-streaming models (e.g. ForcedAligner)
    // Transcription runs in a detached Task so the main loop keeps
    // checking silence every 200ms without blocking on inference.
    var lastTranscription = ""
    let pendingText = LockedString()
    let taskDone = LockedFlag()
    var transcriptionTask: Task<Void, Never>? = nil

    while true {
        try? await Task.sleep(for: .milliseconds(200))
        if Task.isCancelled || session.isSilenceDetected { break }

        // Harvest completed transcription result
        if taskDone.value {
            if let text = pendingText.value {
                lastTranscription = text
                await MainActor.run { onTextUpdate(text) }
            }
            pendingText.set(nil)
            transcriptionTask = nil
            taskDone.reset()
        }

        // Launch new transcription if none in-flight and buffer has data
        if transcriptionTask == nil {
            let count = session.audioBuffer.count
            if count >= 16_000 {
                let snapshot = session.audioBuffer.getPrefix(count)
                let sttRef = stt
                transcriptionTask = Task.detached {
                    do {
                        let text = try await sttRef.transcribe(samples: snapshot)
                        pendingText.set(text)
                    } catch {
                        log.error("Path A transcription: \(error.localizedDescription, privacy: .public)")
                    }
                    taskDone.set()
                }
            }
        }
    }

    // Stop recording immediately — mic indicator off, no need to keep capturing.
    // The in-flight transcriptionTask already holds a buffer snapshot, so this is safe.
    // (Mirrors Path B which calls streamSession.stop() before its drain wait.)
    session.stop()

    // Wait for in-flight transcription (up to 45s) after silence detected
    if let task = transcriptionTask {
        log.info("Waiting for in-flight transcription (up to 45s)")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(45)) }
            _ = await group.next()
            group.cancelAll()
        }
        if let text = pendingText.value {
            lastTranscription = text
        }
    }

    return lastTranscription
}
