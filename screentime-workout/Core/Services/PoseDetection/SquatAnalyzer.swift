//
//  SquatAnalyzer.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2026-01-11.
//

import Foundation

@Observable
final class SquatAnalyzer {
    // MARK: - Properties
    
    private(set) var repCount: Int = 0
    private(set) var currentState: SquatState = .unknown
    private(set) var feedback: String = "Position yourself in frame"
    private(set) var leftKneeAngle: Double?
    private(set) var rightKneeAngle: Double?
    private(set) var leftHipAngle: Double?
    private(set) var rightHipAngle: Double?
    
    // Whether to show positioning feedback (only before workout starts)
    private(set) var showPositioningFeedback: Bool = true
    
    // MARK: - Knee/Hip Angle Detection
    
    // Thresholds (in degrees)
    // Standing: knees and hips are relatively straight (~160-180°)
    // Squat: knees and hips are bent (~70-110°)
    private let standingThreshold: Double = 150   // Above this = standing
    private let squatThreshold: Double = 120      // Below this = squatting
    
    // MARK: - Timing
    
    private var lastStateChangeTime: Date = .distantPast
    private let minimumStateDuration: TimeInterval = 0.3  // Squats are slower than push-ups
    
    // STATE MACHINE FLAGS
    private var isReadyToCount = false
    private var isInSquatPosition = false
    private var hasCompletedSquatPhase = false
    
    // Hold timer for initial position
    private var standingPositionStartTime: Date?
    private let requiredHoldDuration: TimeInterval = 1.0
    
    // MARK: - Public Methods
    
    func reset() {
        repCount = 0
        currentState = .unknown
        isReadyToCount = false
        isInSquatPosition = false
        hasCompletedSquatPhase = false
        standingPositionStartTime = nil
        showPositioningFeedback = true
        feedback = "Position yourself in frame"
        leftKneeAngle = nil
        rightKneeAngle = nil
        leftHipAngle = nil
        rightHipAngle = nil
    }
    
    func analyze(pose: DetectedPose?) {
        let now = Date()
        
        guard let pose else {
            if !isReadyToCount {
                feedback = "Position yourself in frame"
                showPositioningFeedback = true
            }
            currentState = .unknown
            standingPositionStartTime = nil
            return
        }
        
        // ===========================================
        // CALCULATE KNEE ANGLES
        // Knee angle: hip -> knee -> ankle
        // ===========================================
        leftKneeAngle = pose.angle(
            from: .leftHip,
            through: .leftKnee,
            to: .leftAnkle
        )
        
        rightKneeAngle = pose.angle(
            from: .rightHip,
            through: .rightKnee,
            to: .rightAnkle
        )
        
        // ===========================================
        // CALCULATE HIP ANGLES
        // Hip angle: shoulder -> hip -> knee
        // ===========================================
        leftHipAngle = pose.angle(
            from: .leftShoulder,
            through: .leftHip,
            to: .leftKnee
        )
        
        rightHipAngle = pose.angle(
            from: .rightShoulder,
            through: .rightHip,
            to: .rightKnee
        )
        
        // Average available angles
        var kneeAngle: Double?
        if let left = leftKneeAngle, let right = rightKneeAngle {
            kneeAngle = (left + right) / 2.0
        } else if let left = leftKneeAngle {
            kneeAngle = left
        } else if let right = rightKneeAngle {
            kneeAngle = right
        }
        
        var hipAngle: Double?
        if let left = leftHipAngle, let right = rightHipAngle {
            hipAngle = (left + right) / 2.0
        } else if let left = leftHipAngle {
            hipAngle = left
        } else if let right = rightHipAngle {
            hipAngle = right
        }
        
        // Need at least knee angle to proceed
        guard let kneeAngle else {
            if !isReadyToCount {
                feedback = "Show your full body"
                showPositioningFeedback = true
            }
            return
        }
        
        processSquat(kneeAngle: kneeAngle, hipAngle: hipAngle, at: now)
    }
    
    // MARK: - Private Methods
    
    private func processSquat(kneeAngle: Double, hipAngle: Double?, at now: Date) {
        let timeSinceLastChange = now.timeIntervalSince(lastStateChangeTime)
        
        // Use knee angle as primary indicator (hip angle as secondary confirmation)
        let isStanding = kneeAngle >= standingThreshold
        let isSquatting = kneeAngle <= squatThreshold
        
        // ============================================
        // PHASE 1: SETUP - Wait for user to stand straight
        // ============================================
        if !isReadyToCount {
            if isStanding {
                if standingPositionStartTime == nil {
                    standingPositionStartTime = now
                    feedback = "Hold position..."
                    showPositioningFeedback = true
                } else if now.timeIntervalSince(standingPositionStartTime!) >= requiredHoldDuration {
                    // Ready to start counting!
                    isReadyToCount = true
                    showPositioningFeedback = false
                    feedback = ""
                    currentState = .standing
                    lastStateChangeTime = now
                    print("[Squat] ✓ Ready to count (knee angle: \(Int(kneeAngle))°)")
                }
            } else {
                standingPositionStartTime = nil
                feedback = isSquatting ? "Stand up straight first" : "Stand up straight"
                showPositioningFeedback = true
            }
            return
        }
        
        // ============================================
        // PHASE 2: COUNTING - Track STANDING → SQUAT → STANDING cycles
        // 
        // Logic:
        // 1. Start standing
        // 2. Go down into squat (count enters "squat phase")
        // 3. Come back up to standing → count +1
        // ============================================
        
        guard timeSinceLastChange >= minimumStateDuration else { return }
        
        // Detect SQUAT position (going down)
        if isSquatting && !isInSquatPosition {
            isInSquatPosition = true
            hasCompletedSquatPhase = true
            currentState = .squatting
            lastStateChangeTime = now
            print("[Squat] ↓ SQUAT detected (knee angle: \(Int(kneeAngle))°)")
        }
        // Detect STANDING position AFTER being in squat
        else if isStanding && isInSquatPosition && hasCompletedSquatPhase {
            // COUNT THE REP! They went DOWN and came back UP
            repCount += 1
            
            // Reset for next rep
            isInSquatPosition = false
            hasCompletedSquatPhase = false
            currentState = .standing
            lastStateChangeTime = now
            
            print("[Squat] ↑ STANDING - Rep #\(repCount) counted! (knee angle: \(Int(kneeAngle))°)")
        }
        // They're standing but weren't fully down - just update state
        else if isStanding && !isInSquatPosition {
            currentState = .standing
        }
        // Transitioning between positions
        else if !isStanding && !isSquatting {
            currentState = .transitioning
        }
    }
}

// MARK: - Supporting Types

enum SquatState: String {
    case standing
    case squatting
    case transitioning
    case unknown
}
