import Foundation
import Vision
import CoreImage
import AppKit
import Combine

@MainActor
class OCRManager: ObservableObject {
    @Published var isProcessing = false
    @Published var lastRecognizedText = ""
    @Published var recognizedRegions: [TextRegion] = []
    
    nonisolated(unsafe) private var textRecognitionRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var textObservationRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var ocrQueue = DispatchQueue(label: "com.overlook.ocr", qos: .userInitiated)
    
    init() {
        setupOCRRequests()
    }
    
    private func setupOCRRequests() {
        // Setup text recognition request for Live Text-style OCR
        textRecognitionRequest = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleTextRecognition(request: request, error: error)
            }
        }
        
        // Configure for high accuracy
        textRecognitionRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textRecognitionRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textRecognitionRequest?.automaticallyDetectsLanguage = true
        
        // Setup text observation request for real-time text detection
        textObservationRequest = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleTextObservation(request: request, error: error)
            }
        }
        
        textObservationRequest?.recognitionLevel = .fast
        textObservationRequest?.usesLanguageCorrection = false
        textObservationRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textObservationRequest?.automaticallyDetectsLanguage = true
    }
    
    func recognizeText(at point: CGPoint, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performTextRecognition(at: point, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    nonisolated private func performTextRecognition(at point: CGPoint, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }
        
        // Create a region of interest around the click point
        let roi = createRegionOfInterest(around: point, in: pixelBuffer)
        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: roi)
        
        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])
        
        Task { @MainActor in
            isProcessing = true
        }
        
        do {
            try handler.perform([request])
            
            // Get the recognized text from the request
            guard let observations = request.results else {
                completion(.failure(OCRError.noTextFound))
                return
            }
            
            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")
            
            Task { @MainActor in
                lastRecognizedText = recognizedText
                isProcessing = false
            }
            
            if recognizedText.isEmpty {
                completion(.failure(OCRError.noTextFound))
            } else {
                completion(.success(recognizedText))
            }
            
        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }
    
    func detectTextRegions(in pixelBuffer: CVPixelBuffer?) async throws -> [TextRegion] {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performTextDetection(in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    nonisolated private func performTextDetection(in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<[TextRegion], Error>) -> Void) {
        guard let request = textObservationRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                completion(.success([]))
                return
            }
            
            let textRegions = observations.compactMap { observation -> TextRegion? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                
                return TextRegion(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
            
            Task { @MainActor in
                recognizedRegions = textRegions
            }
            
            completion(.success(textRegions))
            
        } catch {
            completion(.failure(error))
        }
    }
    
    nonisolated private func createRegionOfInterest(around point: CGPoint, in pixelBuffer: CVPixelBuffer) -> CGRect {
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        
        let minAxis = min(bufferSize.width, bufferSize.height)
        let regionSize: CGFloat = min(800, minAxis)

        let centerX = clampedX * bufferSize.width
        let centerY = clampedY * bufferSize.height

        let rawX = centerX - regionSize / 2
        let rawY = centerY - regionSize / 2

        let x = max(0, min(rawX, bufferSize.width - regionSize))
        let y = max(0, min(rawY, bufferSize.height - regionSize))

        let regionRect = CGRect(x: x, y: y, width: regionSize, height: regionSize)
        
        return regionRect
    }
    
    nonisolated private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = ciImage.extent.integral
        let requested = rect.integral
        let clipped = requested.intersection(sourceExtent)

        if clipped.isEmpty {
            return pixelBuffer
        }

        let croppedImage = ciImage
            .cropped(to: clipped)
            .transformed(by: CGAffineTransform(translationX: -clipped.origin.x, y: -clipped.origin.y))
        
        var croppedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clipped.width),
            Int(clipped.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &croppedPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = croppedPixelBuffer else {
            return pixelBuffer
        }
        
        let context = CIContext()
        context.render(croppedImage, to: outputBuffer)
        
        return outputBuffer
    }
    
    private func handleTextRecognition(request: VNRequest, error: Error?) {
        if let error = error {
            print("Text recognition error: \(error)")
            return
        }
        
        guard let request = request as? VNRecognizeTextRequest,
              let observations = request.results else {
            return
        }
        
        let recognizedText = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }.joined(separator: "\n")
        
        Task { @MainActor in
            lastRecognizedText = recognizedText
            isProcessing = false
        }
    }
    
    private func handleTextObservation(request: VNRequest, error: Error?) {
        if let error = error {
            print("Text observation error: \(error)")
            return
        }
        
        guard let request = request as? VNRecognizeTextRequest,
              let observations = request.results else {
            return
        }
        
        let regions = observations.compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            
            return TextRegion(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
        
        Task { @MainActor in
            recognizedRegions = regions
        }
    }
    
    // MARK: - Advanced OCR Features
    
    func recognizeTextInRegion(_ region: CGRect, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }
        
        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performRegionTextRecognition(region: region, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    nonisolated private func performRegionTextRecognition(region: CGRect, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }
        
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let normalizedRegion = CGRect(
            x: region.origin.x * bufferSize.width,
            y: region.origin.y * bufferSize.height,
            width: region.size.width * bufferSize.width,
            height: region.size.height * bufferSize.height
        )
        
        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: normalizedRegion)
        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])
        
        Task { @MainActor in
            isProcessing = true
        }
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                completion(.failure(OCRError.noTextFound))
                return
            }
            
            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")
            
            Task { @MainActor in
                lastRecognizedText = recognizedText
                isProcessing = false
            }
            
            completion(.success(recognizedText))
            
        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }
    
    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    func getTextAtLocation(_ point: CGPoint, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        // First detect all text regions
        let regions = try await detectTextRegions(in: pixelBuffer)
        
        // Find the region that contains the click point
        for region in regions {
            if region.boundingBox.contains(point) {
                return region.text
            }
        }
        
        // If no region contains the point, perform OCR in a small area around the point
        let smallRegion = CGRect(
            x: max(0, point.x - 0.05),
            y: max(0, point.y - 0.05),
            width: min(0.1, 1.0),
            height: min(0.1, 1.0)
        )
        
        return try await recognizeTextInRegion(smallRegion, in: pixelBuffer)
    }
}

// MARK: - Supporting Types
struct TextRegion: Identifiable, Codable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
    
    var displayText: String {
        return confidence > 0.5 ? text : "[\(text)]"
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

enum OCRError: Error, LocalizedError {
    case noVideoFrame
    case requestNotInitialized
    case noTextFound
    case processingFailed
    
    var errorDescription: String? {
        switch self {
        case .noVideoFrame:
            return "No video frame available for OCR"
        case .requestNotInitialized:
            return "OCR request not properly initialized"
        case .noTextFound:
            return "No text found in the specified region"
        case .processingFailed:
            return "OCR processing failed"
        }
    }
}

// MARK: - OCR Configuration
extension OCRManager {
    func updateRecognitionLanguages(_ languages: [String]) {
        textRecognitionRequest?.recognitionLanguages = languages
        textObservationRequest?.recognitionLanguages = languages
    }
    
    func setRecognitionLevel(_ level: VNRequestTextRecognitionLevel) {
        textRecognitionRequest?.recognitionLevel = level
    }
    
    func enableLanguageCorrection(_ enabled: Bool) {
        textRecognitionRequest?.usesLanguageCorrection = enabled
    }
    
    func setMinimumTextHeight(_ height: Float) {
        textRecognitionRequest?.minimumTextHeight = height
        textObservationRequest?.minimumTextHeight = height
    }
}

// MARK: - Performance Optimization
extension OCRManager {
    func optimizeForRealTime() {
        textRecognitionRequest?.recognitionLevel = .fast
        textObservationRequest?.recognitionLevel = .fast
        textRecognitionRequest?.usesLanguageCorrection = false
        textObservationRequest?.usesLanguageCorrection = false
    }
    
    func optimizeForAccuracy() {
        textRecognitionRequest?.recognitionLevel = .accurate
        textObservationRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textObservationRequest?.usesLanguageCorrection = true
    }
}
