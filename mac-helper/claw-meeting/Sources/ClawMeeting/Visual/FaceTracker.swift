import Foundation

final class FaceTracker {
    private var knownFaces: [String: String] = [:] // gridPosition -> faceId

    func trackFaces(_ observations: [ParticipantObservation]) -> [ParticipantObservation] {
        observations.map { obs in
            let stableId: String
            if let existing = knownFaces[obs.gridPosition] {
                stableId = existing
            } else {
                stableId = "face_\(String(format: "%03d", knownFaces.count + 1))"
                knownFaces[obs.gridPosition] = stableId
            }
            return ParticipantObservation(
                faceId: stableId,
                gridPosition: obs.gridPosition,
                mouthOpen: obs.mouthOpen,
                gaze: obs.gaze,
                headTilt: obs.headTilt,
                bodyLean: obs.bodyLean,
                faceEmbeddingHash: obs.faceEmbeddingHash ?? stableId,
                landmarksSummary: obs.landmarksSummary
            )
        }
    }

    func reset() {
        knownFaces.removeAll()
    }
}
