import Foundation

/// Double-array DAWG trie matching dawg_lite / dawgdic in Caramba Switcher Core.
public struct DawgTrie: Sendable {
    private let units: [UInt32]

    public var unitCount: Int { units.count }

    public init(data: Data) throws {
        guard data.count >= 4 else {
            throw LogosModelError.corruptedDawg("DAWG blob shorter than 4 bytes")
        }
        let count = data.withUnsafeBytes { raw -> Int in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
        }
        let expectedBytes = 4 + count * 4
        guard data.count == expectedBytes else {
            throw LogosModelError.corruptedDawg("DAWG size mismatch: got \(data.count), expected \(expectedBytes)")
        }
        var array = [UInt32](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            array.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[4..<(4 + count * 4)]))
            }
        }
        #if _endian(big)
        for i in 0..<count {
            array[i] = UInt32(littleEndian: array[i])
        }
        #endif
        self.units = array
    }

    @inline(__always)
    private static func offset(_ unit: UInt32) -> Int {
        let base = Int(unit >> 10)
        let extShift = Int((unit & 0x200) >> 6) // 0 or 8
        return base << extShift
    }

    @inline(__always)
    private static func hasLeaf(_ unit: UInt32) -> Bool {
        (unit & 0x100) != 0
    }

    @inline(__always)
    private static func label(_ unit: UInt32) -> UInt32 {
        unit & 0x8000_00FF
    }

    @inline(__always)
    private static func value(_ unit: UInt32) -> UInt32 {
        unit & 0x7FFF_FFFF
    }

    /// Exact byte-key lookup in the DAWG.
    public func exactLookup(_ key: String) -> UInt32? {
        exactLookup(utf8: Array(key.utf8))
    }

    public func exactLookup(utf8 bytes: [UInt8]) -> UInt32? {
        guard !units.isEmpty else { return nil }
        var idx = 0
        let count = units.count
        for byte in bytes {
            let unit = units[idx]
            let next = idx ^ Self.offset(unit) ^ Int(byte)
            guard next >= 0, next < count, Self.label(units[next]) == UInt32(byte) else {
                return nil
            }
            idx = next
        }
        let terminal = units[idx]
        guard Self.hasLeaf(terminal) else { return nil }
        let leafIdx = idx ^ Self.offset(terminal)
        guard leafIdx >= 0, leafIdx < count else { return nil }
        return Self.value(units[leafIdx])
    }

    /// Returns all values for every substring of key that exists in the DAWG,
    /// matching caramba-core (0x1002e5fb8).
    public func allSubstringValues(_ key: String) -> [UInt32] {
        allSubstringValues(utf8: Array(key.utf8))
    }

    public func allSubstringValues(utf8 bytes: [UInt8]) -> [UInt32] {
        guard !units.isEmpty, !bytes.isEmpty else { return [] }
        var results: [UInt32] = []
        let n = bytes.count
        let count = units.count
        for start in 0..<n {
            var idx = 0
            for pos in start..<n {
                let byte = bytes[pos]
                let unit = units[idx]
                let next = idx ^ Self.offset(unit) ^ Int(byte)
                guard next >= 0, next < count, Self.label(units[next]) == UInt32(byte) else {
                    break
                }
                idx = next
                let current = units[idx]
                if Self.hasLeaf(current) {
                    let leafIdx = idx ^ Self.offset(current)
                    if leafIdx >= 0, leafIdx < count {
                        results.append(Self.value(units[leafIdx]))
                    }
                }
            }
        }
        return results
    }

    /// Counts total keys stored in the DAWG (for diagnostics and tests).
    public func keyCount() -> Int {
        guard !units.isEmpty else { return 0 }
        var total = 0
        var stack: [Int] = [0]
        let count = units.count
        while let idx = stack.popLast() {
            let u = units[idx]
            let off = Self.offset(u)
            if Self.hasLeaf(u) {
                total += 1
            }
            for byte in 1...255 {
                let next = idx ^ off ^ byte
                if next >= 0, next < count, Self.label(units[next]) == UInt32(byte) {
                    stack.append(next)
                }
            }
        }
        return total
    }
}
