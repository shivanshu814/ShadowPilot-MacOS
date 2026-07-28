import ScreenCaptureKit
import AppKit

class ScreenshotCapture {
    func capture() async throws -> Data {
        if #available(macOS 14.0, *) {
            return try await captureModern()
        } else {
            return try captureLegacy()
        }
    }

    // macOS 14+ — SCScreenshotManager (excludes our overlay)
    @available(macOS 14.0, *)
    private func captureModern() async throws -> Data {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ourApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let excluded = ourApp.map { [$0] } ?? []
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width  = display.width
        config.height = display.height
        config.capturesAudio = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try encode(cgImage)
    }

    // macOS 13 — CGWindowListCreateImage
    private func captureLegacy() throws -> Data {
        guard let cgImage = CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .nominalResolution]
        ) else { throw CaptureError.captureAPIFailed }
        return try encode(cgImage)
    }

    private func encode(_ cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw CaptureError.encodingFailed
        }
        return jpeg
    }

    enum CaptureError: LocalizedError {
        case noDisplay, captureAPIFailed, encodingFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay:        return "No display found"
            case .captureAPIFailed: return "Screen capture API failed"
            case .encodingFailed:   return "Failed to encode screenshot"
            }
        }
    }
}
