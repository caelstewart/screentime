//
//  PoseDetector.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Vision
import CoreMedia
import simd

@Observable
final class PoseDetector {
    // MARK: - Properties
    
    private(set) var detectedPose: DetectedPose?
    private(set) var isProcessing = false
    
    private let sequenceHandler = VNSequenceRequestHandler()
    private var lastProcessedTime: CFAbsoluteTime = 0
    private let minProcessingInterval: CFAbsoluteTime = 1.0 / 30.0 // 30 FPS max
    
    // MARK: - Public Methods
    
    func processFrame(_ sampleBuffer: CMSampleBuffer) {
        let currentTime = CFAbsoluteTimeGetCurrent()
        guard currentTime - lastProcessedTime >= minProcessingInterval else { return }
        lastProcessedTime = currentTime
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectHumanBodyPoseRequest { [weak self] request, error in
            guard error == nil,
                  let observations = request.results as? [VNHumanBodyPoseObservation],
                  let observation = observations.first else {
                DispatchQueue.main.async {
                    self?.detectedPose = nil
                }
                return
            }
            
            let pose = self?.extractPose(from: observation)
            DispatchQueue.main.async {
                self?.detectedPose = pose
            }
        }
        
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            print("Pose detection error: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    private func extractPose(from observation: VNHumanBodyPoseObservation) -> DetectedPose? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        
        // Extract key joints - use LOW confidence threshold (0.1) to keep tracking during motion
        // Push-ups cause rapid position changes that reduce Vision's confidence
        let joints: [JointName: Joint] = Dictionary(uniqueKeysWithValues:
            JointName.allCases.compactMap { jointName in
                guard let point = points[jointName.visionKey],
                      point.confidence > 0.1 else { return nil }
                return (jointName, Joint(
                    position: CGPoint(x: point.location.x, y: 1 - point.location.y), // Flip Y
                    confidence: Double(point.confidence)
                ))
            }
        )
        
        guard !joints.isEmpty else { return nil }
        
        return DetectedPose(joints: joints)
    }
}

// MARK: - Supporting Types

struct DetectedPose {
    let joints: [JointName: Joint]
    
    func joint(_ name: JointName) -> Joint? {
        joints[name]
    }
    
    // Calculate angle at joint B formed by points A-B-C
    func angle(from a: JointName, through b: JointName, to c: JointName) -> Double? {
        guard let jointA = joints[a],
              let jointB = joints[b],
              let jointC = joints[c] else { return nil }
        
        let vectorBA = SIMD2<Double>(
            jointA.position.x - jointB.position.x,
            jointA.position.y - jointB.position.y
        )
        let vectorBC = SIMD2<Double>(
            jointC.position.x - jointB.position.x,
            jointC.position.y - jointB.position.y
        )
        
        let dot = simd_dot(vectorBA, vectorBC)
        let magnitudeBA = simd_length(vectorBA)
        let magnitudeBC = simd_length(vectorBC)
        
        guard magnitudeBA > 0, magnitudeBC > 0 else { return nil }
        
        let cosAngle = dot / (magnitudeBA * magnitudeBC)
        let clampedCos = max(-1, min(1, cosAngle))
        
        return acos(clampedCos) * 180 / .pi
    }
}

struct Joint {
    let position: CGPoint
    let confidence: Double
}

enum JointName: String, CaseIterable {
    case nose
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
    
    var visionKey: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }
}

// MARK: - Skeleton Connections

extension DetectedPose {
    static let skeletonConnections: [(JointName, JointName)] = [
        // Upper body
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        
        // Torso
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        
        // Lower body
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
    ]
}

