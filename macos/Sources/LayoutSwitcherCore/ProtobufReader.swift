import Foundation

/// Minimal zero-dependency Protobuf wire reader for Caramba's Logos schema.
struct ProtobufReader {
    let data: Data
    var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw LogosModelError.corruptedProtobuf("Varint overflow")
            }
        }
        throw LogosModelError.corruptedProtobuf("Unexpected EOF in varint")
    }

    mutating func readTag() throws -> (fieldNumber: Int, wireType: Int)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        guard fieldNumber > 0 else {
            throw LogosModelError.corruptedProtobuf("Invalid field number 0")
        }
        return (fieldNumber, wireType)
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, offset + length <= data.count else {
            throw LogosModelError.corruptedProtobuf("Length-delimited field out of bounds")
        }
        let start = data.startIndex + offset
        offset += length
        return data[start..<(start + length)]
    }

    mutating func readString() throws -> String {
        let bytes = try readLengthDelimited()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw LogosModelError.corruptedProtobuf("Invalid UTF-8 string")
        }
        return str
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard offset + 8 <= data.count else { throw LogosModelError.corruptedProtobuf("EOF in 64-bit field") }
            offset += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard offset + 4 <= data.count else { throw LogosModelError.corruptedProtobuf("EOF in 32-bit field") }
            offset += 4
        default:
            throw LogosModelError.corruptedProtobuf("Unsupported wire type \(wireType)")
        }
    }
}
