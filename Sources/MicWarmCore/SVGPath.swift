import Foundation

/// One drawing command from an SVG path's `d` attribute, in absolute coordinates.
public enum PathCommand: Equatable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
    case close
}

public enum SVGPathError: Error, Equatable {
    /// The parser handles absolute M, L, C and Z, which is all the icon artwork uses.
    case unsupportedCommand(Character)
    case expectedNumber(offset: Int)
    case missingCommand
}

/// Parse the subset of SVG path syntax used by the Mic Warm glyphs, so the app draws
/// the exact geometry from the design comps instead of a hand-transcribed copy.
public func parseSVGPath(_ d: String) throws -> [PathCommand] {
    var scanner = NumberScanner(Array(d.utf8))
    var commands: [PathCommand] = []
    var current: Character?

    while true {
        scanner.skipSeparators()
        guard let byte = scanner.peek() else { break }

        if isCommandLetter(byte) {
            let letter = Character(UnicodeScalar(byte))
            scanner.advance()
            guard "MLCZ".contains(letter) else { throw SVGPathError.unsupportedCommand(letter) }
            if letter == "Z" {
                commands.append(.close)
                current = nil
                continue
            }
            current = letter
        }

        // Numbers after the first pair repeat the command; after M they mean L.
        switch current {
        case "M":
            commands.append(.move(x: try scanner.number(), y: try scanner.number()))
            current = "L"
        case "L":
            commands.append(.line(x: try scanner.number(), y: try scanner.number()))
        case "C":
            commands.append(.curve(x1: try scanner.number(), y1: try scanner.number(),
                                   x2: try scanner.number(), y2: try scanner.number(),
                                   x: try scanner.number(), y: try scanner.number()))
        default:
            throw SVGPathError.missingCommand
        }
    }
    return commands
}

private func isCommandLetter(_ byte: UInt8) -> Bool {
    // Letters other than the exponent marker; "e" inside a number is consumed by the scanner.
    let isLetter = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    return isLetter && byte != UInt8(ascii: "e") && byte != UInt8(ascii: "E")
}

private struct NumberScanner {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }
    mutating func advance() { pos += 1 }

    mutating func skipSeparators() {
        while let b = peek(), b == UInt8(ascii: " ") || b == UInt8(ascii: ",")
                || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\r") {
            pos += 1
        }
    }

    /// Read one number. A second "." or a sign starts the next number, as SVG allows ("1.2.5" is 1.2 then .5).
    mutating func number() throws -> Double {
        skipSeparators()
        let start = pos
        if let b = peek(), b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { pos += 1 }
        var sawDot = false, sawDigit = false
        while let b = peek() {
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                sawDigit = true
            } else if b == UInt8(ascii: ".") && !sawDot {
                sawDot = true
            } else {
                break
            }
            pos += 1
        }
        if sawDigit, let b = peek(), b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
            pos += 1
            if let s = peek(), s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { pos += 1 }
            while let d = peek(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") { pos += 1 }
        }
        guard sawDigit, let value = Double(String(decoding: bytes[start..<pos], as: UTF8.self)) else {
            throw SVGPathError.expectedNumber(offset: start)
        }
        return value
    }
}
