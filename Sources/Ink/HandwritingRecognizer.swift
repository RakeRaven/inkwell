import UIKit
import Vision

enum HandwritingRecognizer {
    /// Recognizes handwriting off the main thread; calls back on main with alternatives, best first.
    static func recognize(_ image: UIImage, forMath: Bool, completion: @escaping ([String]) -> Void) {
        guard let cgImage = image.cgImage else {
            completion([])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = !forMath
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            let results = request.results ?? []
            let texts: [String]
            if results.count == 1 {
                texts = results[0].topCandidates(5).map(\.string)
            } else {
                texts = [HandwritingRecognizer.join(results, forMath: forMath)].filter { !$0.isEmpty }
            }
            DispatchQueue.main.async { completion(texts) }
        }
    }

    /// Orders observations into lines, top to bottom then left to right.
    private static func join(_ observations: [VNRecognizedTextObservation], forMath: Bool) -> String {
        // Vision's origin is bottom-left, so a larger midY is higher up
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in sorted {
            if let first = lines.last?.first, abs(first.boundingBox.midY - observation.boundingBox.midY) < first.boundingBox.height / 2 {
                lines[lines.count - 1].append(observation)
            } else {
                lines.append([observation])
            }
        }
        return lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: forMath ? "" : " ")
        }
        .joined(separator: forMath ? "" : "\n")
    }
}
