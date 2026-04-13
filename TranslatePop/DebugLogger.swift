import Foundation
import OSLog

enum DebugLogger {
    static let app = Logger(subsystem: "top.mrlb.TranslatePop", category: "App")
    static let network = Logger(subsystem: "top.mrlb.TranslatePop", category: "Network")
}
