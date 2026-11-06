import Foundation

extension URL {
    /// The byte size of the regular file at this URL. Throws instead of answering 0 when the
    /// size is unknown, so a size limit can never pass by accident.
    func regularFileSize() throws -> Int {
        guard let size = try resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: self])
        }
        return size
    }
}
