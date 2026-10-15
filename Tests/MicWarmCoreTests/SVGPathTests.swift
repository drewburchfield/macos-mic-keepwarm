import MicWarmCore
import XCTest

final class SVGPathTests: XCTestCase {
    func testMoveLineClose() throws {
        XCTAssertEqual(try parseSVGPath("M3.6 1.8L14.6 12.8Z"), [
            .move(x: 3.6, y: 1.8), .line(x: 14.6, y: 12.8), .close,
        ])
    }

    func testCurveWithNegativesAndLeadingDots() throws {
        XCTAssertEqual(try parseSVGPath("M0,0C-1 .5 2-3 4.5.25"), [
            .move(x: 0, y: 0), .curve(x1: -1, y1: 0.5, x2: 2, y2: -3, x: 4.5, y: 0.25),
        ])
    }

    func testRepeatedPairsAfterMoveAreLines() throws {
        XCTAssertEqual(try parseSVGPath("M1 2 3 4"), [.move(x: 1, y: 2), .line(x: 3, y: 4)])
    }

    func testRepeatedCurves() throws {
        let cmds = try parseSVGPath("M6.6 12.4C4.6 11 8.6 9.7 6.6 8.3 4.6 6.9 8.6 5.6 6.6 4.2")
        XCTAssertEqual(cmds.count, 3)
        XCTAssertEqual(cmds[2], .curve(x1: 4.6, y1: 6.9, x2: 8.6, y2: 5.6, x: 6.6, y: 4.2))
    }

    func testExponent() throws {
        XCTAssertEqual(try parseSVGPath("M1e1 2E-1"), [.move(x: 10, y: 0.2)])
    }

    func testRejectsRelativeAndArcCommands() {
        XCTAssertThrowsError(try parseSVGPath("M0 0l1 1")) { error in
            XCTAssertEqual(error as? SVGPathError, .unsupportedCommand("l"))
        }
        XCTAssertThrowsError(try parseSVGPath("M0 0A1 1 0 0 1 2 2")) { error in
            XCTAssertEqual(error as? SVGPathError, .unsupportedCommand("A"))
        }
    }

    func testRejectsTruncatedInput() {
        XCTAssertThrowsError(try parseSVGPath("M1")) { error in
            XCTAssertEqual(error as? SVGPathError, .expectedNumber(offset: 2))
        }
        XCTAssertThrowsError(try parseSVGPath("1 2")) { error in
            XCTAssertEqual(error as? SVGPathError, .missingCommand)
        }
    }

    func testEveryStateHasADistinctAccessibilityLabel() {
        let labels = Set(WarmState.allCases.map(\.accessibilityLabel))
        XCTAssertEqual(labels.count, WarmState.allCases.count)
        XCTAssertEqual(WarmState(rawValue: "needs-access"), .needsAccess)
        XCTAssertEqual(WarmState.allCases.filter(\.isAnimated), [.recovering])
    }
}
