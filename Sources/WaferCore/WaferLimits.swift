/// Shared resource limits. Byte counts use binary units except the document limit,
/// which preserves the app's existing decimal 32 MB policy. Callers may choose lower budgets.
public enum WaferLimits {
    public static let documentSourceByteCount = 32_000_000
    public static let assetByteCount = 25 * 1024 * 1024
    public static let libraryFileByteCount = 2 * 1024 * 1024
    public static let libraryByteCount = 128 * 1024 * 1024
    public static let libraryFileCount = 2_000
    public static let linkedDocumentSummaryByteCount = 256 * 1024
    public static let previewSourceByteCount = 2 * 1024 * 1024
    public static let previewAttachmentByteCount = 10 * 1024 * 1024

    /// I/O chunk size, not a maximum accepted file size.
    public static let fileReadChunkByteCount = 64 * 1024
}
