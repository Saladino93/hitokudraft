import AVFoundation

/// Decodes an audio (or video) file to the 16 kHz mono Float32 PCM that the STT
/// backends expect — the same target format `AudioCaptureService` produces.
///
/// Uses `AVAssetReader` rather than `AVAudioFile`: `AVAudioFile` is unreliable
/// for compressed formats (it frequently fails to open MP3), whereas the asset
/// reader robustly decodes MP3 / M4A / AAC / WAV / AIFF / FLAC and the audio
/// track of video containers, and performs the resample + down-mix itself.
enum AudioFileDecoder {

    enum DecodeError: LocalizedError {
        case noAudioTrack
        case cannotRead
        case empty

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "That file has no audio track to transcribe."
            case .cannotRead:   return "Could not read audio from the file."
            case .empty:        return "The file contains no audio."
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    static func decodeToMono16k(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw DecodeError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeError.cannotRead
        }

        // Ask the reader to hand us exactly 16 kHz mono Float32 PCM.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.cannotRead }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? DecodeError.cannotRead
        }

        var samples = [Float]()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }

            var dataPointer: UnsafeMutablePointer<Int8>?
            var totalLength = 0
            let result = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength, dataPointerOut: &dataPointer
            )
            guard result == kCMBlockBufferNoErr, let pointer = dataPointer else { continue }

            let count = totalLength / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
            }
        }

        if reader.status == .failed {
            throw reader.error ?? DecodeError.cannotRead
        }
        guard !samples.isEmpty else { throw DecodeError.empty }
        return samples
    }
}
