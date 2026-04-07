import Foundation

/// Encodes raw PCM Float32 samples into WAV format for multimodal LLM backends.
enum AudioEncoder {

    /// Encode 16kHz mono Float32 samples as a WAV file in memory.
    /// Returns a `Data` containing a valid WAV with 16-bit PCM encoding.
    static func wavData(from samples: [Float], sampleRate: Int = 16_000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(bytesPerSample)
        let fileSize = 36 + dataSize  // header (44) - 8 bytes for RIFF chunk ID + size

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))                          // sub-chunk size
        data.append(littleEndian: UInt16(1))                           // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate) * UInt32(numChannels) * UInt32(bytesPerSample))  // byte rate
        data.append(littleEndian: numChannels * bytesPerSample)        // block align
        data.append(littleEndian: bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        // Convert Float32 [-1.0, 1.0] → Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.append(littleEndian: int16)
        }

        return data
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
    mutating func append(littleEndian value: Int16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
}
