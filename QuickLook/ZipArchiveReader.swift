import Compression
import Foundation

/// Minimal read-only ZIP reader for pulling small entries out of a package.
/// The extension is sandboxed and cannot spawn /usr/bin/unzip, so the format is parsed here.
struct ZipArchiveReader {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    enum ReadError: Error {
        case notAZip
        case malformed(String)
        case unsupported(String)
        case tooLarge(String)
    }

    /// Packages hold one entry per file of every scene, so the directory can be long, but
    /// anything past this is not something the exporter writes.
    static let maxCentralDirectorySize: UInt64 = 32 * 1024 * 1024

    let entries: [Entry]
    // FileHandle(forReadingFrom:) closes the descriptor when it is deallocated.
    private let handle: FileHandle
    private let fileSize: UInt64

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        fileSize = try handle.seekToEnd()
        entries = try Self.readCentralDirectory(handle: handle, fileSize: fileSize)
    }

    func data(for entry: Entry, maxSize: UInt64) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw ReadError.unsupported("encrypted entry") }
        guard entry.uncompressedSize <= maxSize else { throw ReadError.tooLarge(entry.name) }
        // Deflate never expands meaningfully beyond its input, so a compressed size far above
        // the declared uncompressed size means a lying header.
        guard entry.compressedSize <= entry.uncompressedSize + 64 * 1024 else {
            throw ReadError.malformed("compressed size of \(entry.name)")
        }

        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4B50
        else { throw ReadError.malformed("local header of \(entry.name)") }
        let nameLen = UInt64(header.u16(26))
        let extraLen = UInt64(header.u16(28))
        let (o1, of1) = entry.localHeaderOffset.addingReportingOverflow(30)
        let (o2, of2) = o1.addingReportingOverflow(nameLen)
        let (dataOffset, of3) = o2.addingReportingOverflow(extraLen)
        let (endOffset, of4) = dataOffset.addingReportingOverflow(entry.compressedSize)
        guard !of1, !of2, !of3, !of4, endOffset <= fileSize else {
            throw ReadError.malformed("data offset out of bounds for \(entry.name)")
        }
        let compressed = try read(at: dataOffset, count: entry.compressedSize)

        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ReadError.malformed("stored sizes of \(entry.name)")
            }
            return compressed
        case 8:
            return try Self.inflate(
                compressed,
                expectedSize: Int(entry.uncompressedSize),
                name: entry.name
            )
        default:
            throw ReadError.unsupported("compression method \(entry.method)")
        }
    }

    private func read(at offset: UInt64, count: UInt64) throws -> Data {
        try Self.read(handle: handle, fileSize: fileSize, at: offset, count: count)
    }

    private static func read(
        handle: FileHandle,
        fileSize: UInt64,
        at offset: UInt64,
        count: UInt64
    ) throws -> Data {
        guard offset <= fileSize, count <= fileSize - offset else {
            throw ReadError.malformed("range \(offset)+\(count) beyond file size \(fileSize)")
        }
        if count == 0 { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else {
            throw ReadError.malformed("short read at \(offset)")
        }
        return data
    }

    private static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        // One spare byte: if the stream fills it, the entry is larger than its header claims.
        var output = Data(count: expectedSize + 1)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                // COMPRESSION_ZLIB is raw deflate (RFC 1951), which is what ZIP stores.
                return compression_decode_buffer(
                    dstBase, dst.count,
                    srcBase, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ReadError
                .malformed("inflated \(written) bytes of \(name), expected \(expectedSize)")
        }
        output.removeLast()
        return output
    }

    private static func readCentralDirectory(
        handle: FileHandle,
        fileSize: UInt64
    ) throws -> [Entry] {
        guard fileSize >= 22 else { throw ReadError.notAZip }
        let tailLength = min(fileSize, 22 + 0xFFFF)
        let tailStart = fileSize - tailLength
        let tail = try read(handle: handle, fileSize: fileSize, at: tailStart, count: tailLength)

        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.u32(index) == 0x0605_4B50,
               index + 22 + Int(tail.u16(index + 20)) == tail.count {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocdIndex = eocd else { throw ReadError.notAZip }

        var entryCount = UInt64(tail.u16(eocdIndex + 10))
        var directorySize = UInt64(tail.u32(eocdIndex + 12))
        var directoryOffset = UInt64(tail.u32(eocdIndex + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locatorOffset = tailStart + UInt64(eocdIndex)
            guard locatorOffset >= 20 else { throw ReadError.malformed("missing ZIP64 locator") }
            let locator = try read(
                handle: handle,
                fileSize: fileSize,
                at: locatorOffset - 20,
                count: 20
            )
            guard locator.u32(0) == 0x0706_4B50
            else { throw ReadError.malformed("missing ZIP64 locator") }
            let record = try read(handle: handle, fileSize: fileSize, at: locator.u64(8), count: 56)
            guard record.u32(0) == 0x0606_4B50
            else { throw ReadError.malformed("bad ZIP64 end record") }
            entryCount = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }

        guard directorySize <= maxCentralDirectorySize
        else { throw ReadError.tooLarge("central directory") }
        let directory = try read(
            handle: handle,
            fileSize: fileSize,
            at: directoryOffset,
            count: directorySize
        )

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(entryCount, 100_000)))
        var cursor = 0
        while cursor + 46 <= directory.count {
            guard directory.u32(cursor) == 0x0201_4B50 else { break }
            let flags = directory.u16(cursor + 8)
            let method = directory.u16(cursor + 10)
            var compressedSize = UInt64(directory.u32(cursor + 20))
            var uncompressedSize = UInt64(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let commentLength = Int(directory.u16(cursor + 32))
            var localHeaderOffset = UInt64(directory.u32(cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count
            else { throw ReadError.malformed("central directory entry overruns") }
            let name = String(
                decoding: directory[directory.startIndex + nameStart ..< directory
                    .startIndex + extraStart],
                as: UTF8.self
            )

            // Entries that follow multi-gigabyte videos carry their real offset in the ZIP64
            // extra field; the fields present are exactly those saturated in the fixed header.
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let tag = directory.u16(extra)
                let size = Int(directory.u16(extra + 2))
                let body = extra + 4
                guard body + size <= extraStart + extraLength else { break }
                if tag == 0x0001 {
                    var field = body
                    func next64() -> UInt64? {
                        guard field + 8 <= body + size else { return nil }
                        defer { field += 8 }
                        return directory.u64(field)
                    }
                    if uncompressedSize == 0xFFFF_FFFF,
                       let value = next64() { uncompressedSize = value }
                    if compressedSize == 0xFFFF_FFFF,
                       let value = next64() { compressedSize = value }
                    if localHeaderOffset == 0xFFFF_FFFF,
                       let value = next64() { localHeaderOffset = value }
                }
                extra = body + size
            }

            entries.append(Entry(
                name: name,
                method: method,
                flags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cursor = next
        }
        return entries
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}
