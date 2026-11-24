// SPDX-License-Identifier: MIT
import os

/// View with: log stream --predicate 'subsystem == "com.talha90a1.hush"'
enum Log {
    private static let logger = Logger(subsystem: "com.talha90a1.hush", category: "app")
    static func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
}
