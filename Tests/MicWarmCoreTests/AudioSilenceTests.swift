import CoreMedia
import MicWarmCore
import XCTest

final class AudioSilenceTests: XCTestCase {
    /// A block buffer made of separate memory blocks, one per span.
    func buffer(_ spans: [[UInt8]]) throws -> CMBlockBuffer {
        var buffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: nil, capacity: 0, flags: 0, blockBufferOut: &buffer), noErr)
        let result = try XCTUnwrap(buffer)
        for span in spans {
            XCTAssertEqual(CMBlockBufferAppendMemoryBlock(result, memoryBlock: nil, length: span.count,
                                                          blockAllocator: nil, customBlockSource: nil,
                                                          offsetToData: 0, dataLength: span.count, flags: 0), noErr)
            let offset = CMBlockBufferGetDataLength(result) - span.count
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: span, blockBuffer: result,
                                                         offsetIntoDestination: offset, dataLength: span.count), noErr)
        }
        return result
    }

    func testZeroBufferIsSilent() throws {
        XCTAssertEqual(AudioSilence.isAllZero(try buffer([[0, 0, 0, 0]])), true)
    }

    func testAnyNonzeroByteIsNotSilent() throws {
        XCTAssertEqual(AudioSilence.isAllZero(try buffer([[0, 0, 7, 0]])), false)
    }

    func testAudioInALaterSpanIsNotSilent() throws {
        let split = try buffer([[UInt8](repeating: 0, count: 128), [UInt8](repeating: 1, count: 128)])
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(split, atOffset: 0, length: 256))
        XCTAssertEqual(AudioSilence.isAllZero(split), false)
    }

    func testAllZeroSpansAreSilent() throws {
        XCTAssertEqual(AudioSilence.isAllZero(try buffer([[0, 0], [0, 0, 0]])), true)
    }

    func testEmptyBufferIsUnknown() throws {
        XCTAssertNil(AudioSilence.isAllZero(try buffer([])))
    }
}
