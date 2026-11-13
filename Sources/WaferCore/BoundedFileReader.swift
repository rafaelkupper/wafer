import Foundation

public enum BoundedFileReader {
    public enum ReadError: Error { case tooLarge }

    public static func prefix(from url: URL, maximumByteCount: Int) throws -> (data: Data, truncated: Bool) {
        precondition(maximumByteCount >= 0 && maximumByteCount < Int.max)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let truncated = data.count > maximumByteCount
        if truncated { data.removeLast() }
        return (data, truncated)
    }

    public static func read(from url: URL, maximumByteCount: Int) throws -> Data {
        // Avoid reading an already known oversized file; the bounded read also
        // covers growth after this check and missing size metadata.
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumByteCount {
            throw ReadError.tooLarge
        }
        let result = try prefix(from: url, maximumByteCount: maximumByteCount)
        guard !result.truncated else { throw ReadError.tooLarge }
        return result.data
    }
}
