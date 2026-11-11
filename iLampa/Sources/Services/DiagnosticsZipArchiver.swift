import Foundation
import zlib

/// Lightweight, zero-dependency ZIP archive creator implementing standard PKZIP format.
/// Used to bundle diagnostics into shareable archives without external pods.
final class DiagnosticsZipArchiver {
    struct FileEntry {
        let name: String
        let data: Data
    }

    /// Creates a standard .zip archive containing the provided files.
    static func createZip(entries: [FileEntry], destinationURL: URL) throws {
        var zipData = Data()
        var centralDirectory = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let offset = UInt32(zipData.count)
            offsets.append(offset)

            let filenameBytes = Array(entry.name.utf8)
            let filenameLength = UInt16(filenameBytes.count)
            let fileData = entry.data
            let crc = UInt32(crc32(0, [UInt8](fileData), uInt(fileData.count)))
            let size = UInt32(fileData.count)

            // Local File Header
            var localHeader = Data()
            localHeader.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // Signature
            localHeader.append(contentsOf: [20, 0]) // Version needed (2.0)
            localHeader.append(contentsOf: [0x00, 0x08])  // UTF-8 filenames, ZIP general flag bit 11
            localHeader.append(contentsOf: [0, 0])  // Compression: 0 (Stored)
            localHeader.append(contentsOf: [0, 0, 0, 0]) // Mod time & date
            localHeader.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
            localHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            localHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            localHeader.append(contentsOf: withUnsafeBytes(of: filenameLength.littleEndian) { Array($0) })
            localHeader.append(contentsOf: [0, 0])  // Extra field length
            localHeader.append(contentsOf: filenameBytes)
            localHeader.append(fileData)

            zipData.append(localHeader)

            // Central Directory Header
            var cdHeader = Data()
            cdHeader.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // Signature
            cdHeader.append(contentsOf: [20, 0]) // Version made by
            cdHeader.append(contentsOf: [20, 0]) // Version needed
            cdHeader.append(contentsOf: [0x00, 0x08])  // UTF-8 filenames, ZIP general flag bit 11
            cdHeader.append(contentsOf: [0, 0])  // Compression: 0
            cdHeader.append(contentsOf: [0, 0, 0, 0]) // Mod time & date
            cdHeader.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
            cdHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            cdHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            cdHeader.append(contentsOf: withUnsafeBytes(of: filenameLength.littleEndian) { Array($0) })
            cdHeader.append(contentsOf: [0, 0])  // Extra field length
            cdHeader.append(contentsOf: [0, 0])  // File comment length
            cdHeader.append(contentsOf: [0, 0])  // Disk number start
            cdHeader.append(contentsOf: [0, 0])  // Internal file attributes
            cdHeader.append(contentsOf: [0, 0, 0, 0]) // External file attributes
            cdHeader.append(contentsOf: withUnsafeBytes(of: offset.littleEndian) { Array($0) })
            cdHeader.append(contentsOf: filenameBytes)

            centralDirectory.append(cdHeader)
        }

        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        let count = UInt16(entries.count)

        zipData.append(centralDirectory)

        // End of Central Directory Record
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // Signature
        eocd.append(contentsOf: [0, 0]) // Disk number
        eocd.append(contentsOf: [0, 0]) // Disk with central dir
        eocd.append(contentsOf: withUnsafeBytes(of: count.littleEndian) { Array($0) })
        eocd.append(contentsOf: withUnsafeBytes(of: count.littleEndian) { Array($0) })
        eocd.append(contentsOf: withUnsafeBytes(of: cdSize.littleEndian) { Array($0) })
        eocd.append(contentsOf: withUnsafeBytes(of: cdOffset.littleEndian) { Array($0) })
        eocd.append(contentsOf: [0, 0]) // Comment length

        zipData.append(eocd)

        try zipData.write(to: destinationURL, options: .atomic)
    }
}
