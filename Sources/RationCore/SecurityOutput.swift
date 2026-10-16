import Foundation

/// The password `security find-generic-password -w` printed, without its newline. It prints the
/// whole password as hex when any byte isn't printable ASCII, such as a non-ASCII email or a
/// newline. Ration's items are JSON, which never consists of hex digits alone.
public func securityPasswordOutput(_ output: Data) -> Data {
    var data = output
    if data.last == UInt8(ascii: "\n") { data.removeLast() }
    return hexDecoded(data) ?? data
}

func hexDecoded(_ data: Data) -> Data? {
    guard !data.isEmpty, data.count % 2 == 0 else { return nil }
    func value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
    let bytes = Array(data)
    var decoded = Data(capacity: bytes.count / 2)
    for index in stride(from: 0, to: bytes.count, by: 2) {
        guard let high = value(bytes[index]), let low = value(bytes[index + 1]) else { return nil }
        decoded.append(high << 4 | low)
    }
    return decoded
}
