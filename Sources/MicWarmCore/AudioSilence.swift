import CoreMedia

public enum AudioSilence {
    /// Whether every byte of `buffer` is zero, checking every span of a noncontiguous
    /// block buffer. Returns nil for an empty or unreadable buffer.
    public static func isAllZero(_ buffer: CMBlockBuffer) -> Bool? {
        let total = CMBlockBufferGetDataLength(buffer)
        guard total > 0 else { return nil }
        var offset = 0
        while offset < total {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(buffer, atOffset: offset, lengthAtOffsetOut: &length,
                                              totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
                  let pointer, length > 0 else { return nil }
            if !UnsafeRawBufferPointer(start: pointer, count: length).allSatisfy({ $0 == 0 }) {
                return false
            }
            offset += length
        }
        return true
    }
}
