import Foundation
import os

/// Unified-logging channels for failures that are handled without user
/// interaction. View them with
/// `log stream --predicate 'subsystem == "dev.wafer.app"'`.
/// File paths are logged as private values.
public enum WaferLog {
    public static let subsystem = "dev.wafer.app"
    public static let editing = Logger(subsystem: subsystem, category: "editing")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let rendering = Logger(subsystem: subsystem, category: "rendering")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let resources = Logger(subsystem: subsystem, category: "resources")
}
