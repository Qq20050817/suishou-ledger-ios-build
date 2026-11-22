import Foundation
import ReceiptCore
import Vision

enum ScreenshotImageText {
    /// Shortcuts can return the two columns in separate blocks. Preserve the visual rows locally.
    nonisolated static func rows(in jpeg: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: jpeg, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).compactMap { observation -> ReceiptTextBox? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ReceiptTextBox(text: text, left: box.minX, top: 1 - box.maxY, height: box.height)
        }
        return ReceiptTextBox.rows(observations)
    }
}
