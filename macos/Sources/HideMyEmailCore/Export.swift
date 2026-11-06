import Foundation

public enum Export {
    public static func csv(_ addresses: [HMEAddress]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = ["Address", "Label", "Note", "Forward To", "Active", "Created"]
        let rows = addresses.map { address in
            [address.hme, address.label, address.note, address.forwardToEmail,
             address.isActive ? "yes" : "no", formatter.string(from: address.createdAt)]
        }
        return ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func json(_ addresses: [HMEAddress]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(addresses)
    }

    static func escape(_ field: String) -> String {
        // Prefix formula-like values so spreadsheets don't evaluate them.
        let safe = field.first.map { "=+-@".contains($0) } == true ? "'" + field : field
        guard safe.contains(where: { ",\"\r\n".contains($0) }) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
