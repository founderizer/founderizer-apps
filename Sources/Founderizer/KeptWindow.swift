import Compression
import FleetCore
import Foundation

/// The saved fleet window. A compressed file starts with its format and decoded byte count.
/// Older windows and small windows that take less room as plain JSON use their original bytes.
enum KeptWindow {
    private static let format = Data("FZW1".utf8)
    private static let headerSize = 8

    static func stored(_ json: Data) -> Data? {
        guard json.count <= HubState.maximumBytes else { return nil }
        guard json.count > headerSize,
              let packed = try? (json as NSData).compressed(using: .lzfse) as Data,
              packed.count < json.count - headerSize else { return json }
        var result = format
        var size = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(packed)
        return result
    }

    static func restored(_ file: Data, atMost limit: Int = HubState.maximumBytes) -> Data? {
        guard file.count <= limit else { return nil }
        guard file.starts(with: format) else { return file }
        guard file.count > headerSize else { return nil }
        let size = file.withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: format.count, as: UInt32.self)))
        }
        guard size > 0, size <= limit else { return nil }
        // The decoder returns the destination size on overflow. One extra byte distinguishes
        // an exact fit from a stream that expands past the size written in its header.
        let capacity = size + 1
        var json = Data(count: capacity)
        let written = json.withUnsafeMutableBytes { destination in
            file.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress! + headerSize,
                                          file.count - headerSize, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == size else { return nil }
        json.removeLast()
        return json
    }
}
