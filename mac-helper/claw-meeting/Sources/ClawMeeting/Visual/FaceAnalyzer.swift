import Vision
import AppKit
import Foundation

final class FaceAnalyzer {
    func analyze(imageURL: URL) throws -> [ParticipantObservation] {
        guard let cgImage = loadCGImage(from: imageURL) else { return [] }

        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPose3DRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, bodyRequest])

        let faces = faceRequest.results ?? []
        let bodies = bodyRequest.results ?? []

        return faces.enumerated().map { index, face in
            let landmarks = face.landmarks
            let mouthOpen = isMouthOpen(landmarks: landmarks)
            let browFurrowed = isBrowFurrowed(landmarks: landmarks)
            let gaze = estimateGaze(landmarks: landmarks)
            let headTilt = estimateHeadTilt(face: face)
            let bodyLean = estimateBodyLean(bodies: bodies, faceIndex: index)
            let gridPosition = estimateGridPosition(
                boundingBox: face.boundingBox,
                imageSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
            let mouthOpenness = computeMouthOpenness(landmarks: landmarks)

            return ParticipantObservation(
                faceId: "face_\(String(format: "%03d", index))",
                gridPosition: gridPosition,
                mouthOpen: mouthOpen,
                gaze: gaze,
                headTilt: headTilt,
                bodyLean: bodyLean,
                faceEmbeddingHash: stableFaceHash(gridPosition: gridPosition, headTilt: headTilt),
                landmarksSummary: LandmarksSummary(
                    browRaised: false, // TODO: implement brow raise detection
                    browFurrowed: browFurrowed,
                    mouthOpenness: mouthOpenness
                )
            )
        }
    }

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    private func isMouthOpen(landmarks: VNFaceLandmarks2D?) -> Bool {
        guard let outerLips = landmarks?.outerLips,
              let innerLips = landmarks?.innerLips else { return false }
        let outerPoints = outerLips.normalizedPoints
        let innerPoints = innerLips.normalizedPoints
        guard outerPoints.count >= 6, innerPoints.count >= 4 else { return false }
        let mouthWidth = abs(outerPoints[0].x - outerPoints[outerPoints.count / 2].x)
        let mouthHeight = abs(innerPoints[1].y - innerPoints[innerPoints.count - 1].y)
        return mouthWidth > 0 && (mouthHeight / mouthWidth) > 0.15
    }

    private func computeMouthOpenness(landmarks: VNFaceLandmarks2D?) -> Double {
        guard let outerLips = landmarks?.outerLips,
              let innerLips = landmarks?.innerLips else { return 0 }
        let outerPoints = outerLips.normalizedPoints
        let innerPoints = innerLips.normalizedPoints
        guard outerPoints.count >= 6, innerPoints.count >= 4 else { return 0 }
        let mouthWidth = abs(outerPoints[0].x - outerPoints[outerPoints.count / 2].x)
        guard mouthWidth > 0 else { return 0 }
        let mouthHeight = abs(innerPoints[1].y - innerPoints[innerPoints.count - 1].y)
        return Double(mouthHeight / mouthWidth)
    }

    private func isBrowFurrowed(landmarks: VNFaceLandmarks2D?) -> Bool {
        guard let leftBrow = landmarks?.leftEyebrow,
              let leftEye = landmarks?.leftEye else { return false }
        let browPoints = leftBrow.normalizedPoints
        let eyePoints = leftEye.normalizedPoints
        guard browPoints.count > 2, let eyeTop = eyePoints.max(by: { $0.y < $1.y }) else { return false }
        let browMid = browPoints[browPoints.count / 2]
        return abs(browMid.y - eyeTop.y) < 0.03
    }

    private func estimateGaze(landmarks: VNFaceLandmarks2D?) -> String {
        guard let leftPupil = landmarks?.leftPupil,
              let rightPupil = landmarks?.rightPupil,
              let nose = landmarks?.nose else { return "at_camera" }
        let leftP = leftPupil.normalizedPoints
        let rightP = rightPupil.normalizedPoints
        let noseP = nose.normalizedPoints
        guard let lp = leftP.first, let rp = rightP.first, noseP.count > 2 else { return "at_camera" }
        let np = noseP[noseP.count / 2]
        let pupilCenterX = (lp.x + rp.x) / 2
        let offset = pupilCenterX - np.x
        if abs(offset) < 0.02 { return "at_camera" }
        return offset > 0 ? "right" : "left"
    }

    private func estimateHeadTilt(face: VNFaceObservation) -> Double {
        return Double(face.roll?.doubleValue ?? 0) * 180.0 / .pi
    }

    private func estimateBodyLean(bodies: [VNHumanBodyPose3DObservation], faceIndex: Int) -> String {
        guard faceIndex < bodies.count else { return "neutral" }
        guard let head = try? bodies[faceIndex].recognizedPoint(.centerHead),
              let spine = try? bodies[faceIndex].recognizedPoint(.centerShoulder) else {
            return "neutral"
        }
        // position is simd_float4x4; translation Z is in columns.3.z
        let zDiff = head.position.columns.3.z - spine.position.columns.3.z
        if zDiff > 0.05 { return "forward" }
        if zDiff < -0.05 { return "back" }
        return "neutral"
    }

    private func estimateGridPosition(boundingBox: CGRect, imageSize: CGSize) -> String {
        let centerX = boundingBox.midX
        let centerY = 1.0 - boundingBox.midY // Vision uses bottom-left origin
        let col = centerX < 0.5 ? "left" : "right"
        let row = centerY < 0.5 ? "bottom" : "top"
        return "\(row)-\(col)"
    }

    private func stableFaceHash(gridPosition: String, headTilt: Double) -> String {
        let quantizedTilt = Int((headTilt * 10).rounded())
        return "\(gridPosition)-\(quantizedTilt)"
    }
}
