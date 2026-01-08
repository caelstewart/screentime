//
//  PushUpAnalyzer.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Foundation

@Observable
final class PushUpAnalyzer {
    // MARK: - Properties
    
    private(set) var repCount: Int = 0
    private(set) var currentState: PushUpState = .unknown
    private(set) var feedback: String = "Position yourself in frame"
    private(set) var leftElbowAngle: Double?
    private(set) var rightElbowAngle: Double?
    
    // Whether to show positioning feedback (only before workout starts)
    private(set) var showPositioningFeedback: Bool = true
    
    // MARK: - Arm-based Detection (Primary when visible)
    
    // Thresholds (in degrees)
    private let upThreshold: Double = 140    // Arms mostly straight
    private let downThreshold: Double = 120  // Arms bent
    
    // MARK: - Head/Shoulder-based Detection (Fallback - always works)
    
    // Track vertical position of head for movement detection
    private var headPositionHistory: [Double] = []  // Y positions (0 = top, 1 = bottom)
    private let positionHistorySize = 10
    private var baselineHeadY: Double?  // Starting "up" position
    private let headMovementThreshold: Double = 0.04  // 4% of screen = significant movement
    
    // MARK: - Timing
    
    private var lastStateChangeTime: Date = .distantPast
    private let minimumStateDuration: TimeInterval = 0.2
    
    // Track last known values for state persistence
    private var lastKnownElbowAngle: Double?
    private var lastAngleUpdateTime: Date = .distantPast
    private let angleMemoryDuration: TimeInterval = 0.5
    
    // STATE MACHINE FLAGS
    private var isReadyToCount = false
    private var isInDownPosition = false
    private var hasCompletedDownPhase = false
    
    // Detection mode
    private var useHeadTracking = false  // Falls back to head tracking if arms not visible
    
    // Hold timer for initial position
    private var upPositionStartTime: Date?
    private let requiredHoldDuration: TimeInterval = 1.0
    
    // MARK: - Public Methods
    
    func reset() {
        repCount = 0
        currentState = .unknown
        isReadyToCount = false
        isInDownPosition = false
        hasCompletedDownPhase = false
        upPositionStartTime = nil
        showPositioningFeedback = true
        feedback = "Position yourself in frame"
        
        // Reset head tracking
        headPositionHistory.removeAll()
        baselineHeadY = nil
        useHeadTracking = false
        lastKnownElbowAngle = nil
    }
    
    func analyze(pose: DetectedPose?) {
        let now = Date()
        
        guard let pose else {
            if !isReadyToCount {
                feedback = "Position yourself in frame"
                showPositioningFeedback = true
            }
            currentState = .unknown
            upPositionStartTime = nil
            return
        }
        
        // ===========================================
        // TRACK HEAD POSITION (Always available)
        // ===========================================
        let headY = getHeadY(from: pose)
        if let y = headY {
            updateHeadHistory(y)
        }
        
        // ===========================================
        // TRY ARM-BASED DETECTION FIRST
        // ===========================================
        leftElbowAngle = pose.angle(
            from: .leftShoulder,
            through: .leftElbow,
            to: .leftWrist
        )
        
        rightElbowAngle = pose.angle(
            from: .rightShoulder,
            through: .rightElbow,
            to: .rightWrist
        )
        
        // Determine elbow angle
        var elbowAngle: Double?
        if let left = leftElbowAngle, let right = rightElbowAngle {
            elbowAngle = (left + right) / 2.0
        } else if let left = leftElbowAngle {
            elbowAngle = left
        } else if let right = rightElbowAngle {
            elbowAngle = right
        }
        
        // ===========================================
        // DECIDE DETECTION METHOD
        // ===========================================
        
        // If we have arm angles, use arm-based detection
        if let angle = elbowAngle {
            lastKnownElbowAngle = angle
            lastAngleUpdateTime = now
            useHeadTracking = false
            processWithArmAngle(angle, at: now)
            return
        }
        
        // No arms visible - use head tracking fallback
        if headY != nil {
            useHeadTracking = true
            processWithHeadTracking(at: now)
            return
        }
        
        // Nothing visible
        if !isReadyToCount {
            feedback = "Position yourself in frame"
            showPositioningFeedback = true
        }
    }
    
    // MARK: - Head Position Tracking
    
    private func getHeadY(from pose: DetectedPose) -> Double? {
        // Try nose first, then eyes, then ears
        if let nose = pose.joint(.nose) {
            return Double(nose.position.y)
        }
        if let leftEye = pose.joint(.leftEye), let rightEye = pose.joint(.rightEye) {
            return Double(leftEye.position.y + rightEye.position.y) / 2.0
        }
        if let leftEar = pose.joint(.leftEar) {
            return Double(leftEar.position.y)
        }
        if let rightEar = pose.joint(.rightEar) {
            return Double(rightEar.position.y)
        }
        // Fallback to shoulder center
        if let leftShoulder = pose.joint(.leftShoulder), let rightShoulder = pose.joint(.rightShoulder) {
            return Double(leftShoulder.position.y + rightShoulder.position.y) / 2.0
        }
        return nil
    }
    
    private func updateHeadHistory(_ y: Double) {
        headPositionHistory.append(y)
        if headPositionHistory.count > positionHistorySize {
            headPositionHistory.removeFirst()
        }
    }
    
    private func processWithHeadTracking(at now: Date) {
        guard headPositionHistory.count >= 3 else { return }
        
        let currentY = headPositionHistory.last!
        let timeSinceLastChange = now.timeIntervalSince(lastStateChangeTime)
        
        // ===========================================
        // PHASE 1: SETUP - Establish baseline
        // ===========================================
        if !isReadyToCount {
            // Use the first stable position as baseline (up position)
            if baselineHeadY == nil {
                // Wait for stable readings
                let recentPositions = Array(headPositionHistory.suffix(5))
                if recentPositions.count >= 5 {
                    let variance = recentPositions.max()! - recentPositions.min()!
                    if variance < 0.02 {  // Stable enough
                        baselineHeadY = recentPositions.reduce(0.0, +) / Double(recentPositions.count)
                        upPositionStartTime = now
                        feedback = "Hold position..."
                        showPositioningFeedback = true
                    } else {
                        feedback = "Hold still..."
                        showPositioningFeedback = true
                    }
                }
                return
            }
            
            // Check if holding position
            if let startTime = upPositionStartTime {
                let holdDuration = now.timeIntervalSince(startTime)
                if holdDuration >= requiredHoldDuration {
                    isReadyToCount = true
                    showPositioningFeedback = false
                    feedback = ""
                    currentState = .up
                    lastStateChangeTime = now
                    print("[PushUp] ✓ Ready to count (head tracking mode)")
                }
            }
            return
        }
        
        // ===========================================
        // PHASE 2: COUNT REPS - Track head movement
        // ===========================================
        guard let baseline = baselineHeadY else { return }
        guard timeSinceLastChange >= minimumStateDuration else { return }
        
        // In Vision coordinates: Y increases downward (0 = top of screen)
        // So head going DOWN in push-up = Y value INCREASES
        let movementFromBaseline = currentY - baseline
        
        // Detect DOWN position (head moved down significantly)
        let isDown = movementFromBaseline > headMovementThreshold
        // Detect UP position (head back near baseline)
        let isUp = movementFromBaseline < headMovementThreshold * 0.5
        
        if isDown && !isInDownPosition {
            isInDownPosition = true
            hasCompletedDownPhase = true
            currentState = .down
            lastStateChangeTime = now
            print("[PushUp] ↓ DOWN detected (head Y: \(String(format: "%.3f", currentY)), baseline: \(String(format: "%.3f", baseline)))")
        }
        else if isUp && isInDownPosition && hasCompletedDownPhase {
            repCount += 1
            isInDownPosition = false
            hasCompletedDownPhase = false
            currentState = .up
            lastStateChangeTime = now
            print("[PushUp] ↑ UP - Rep #\(repCount) counted! (head tracking)")
        }
        else if isUp && !isInDownPosition {
            currentState = .up
        }
        else if !isUp && !isDown {
            currentState = .transitioning
        }
    }
    
    private func processWithArmAngle(_ elbowAngle: Double, at now: Date) {
        let timeSinceLastChange = now.timeIntervalSince(lastStateChangeTime)
        
        // Determine current position
        let isUp = elbowAngle >= upThreshold
        let isDown = elbowAngle <= downThreshold
        
        // ============================================
        // PHASE 1: SETUP - Wait for user to hold UP
        // ============================================
        if !isReadyToCount {
            if isUp {
                if upPositionStartTime == nil {
                    upPositionStartTime = now
                    feedback = "Hold position..."
                    showPositioningFeedback = true
                } else if now.timeIntervalSince(upPositionStartTime!) >= requiredHoldDuration {
                    // Ready to start counting!
                    isReadyToCount = true
                    showPositioningFeedback = false
                    feedback = ""
                    currentState = .up
                    lastStateChangeTime = now
                    print("[PushUp] ✓ Ready to count (angle: \(Int(elbowAngle))°)")
                }
            } else {
                upPositionStartTime = nil
                feedback = isDown ? "Push up first, then hold" : "Get into position"
                showPositioningFeedback = true
            }
            return
        }
        
        // ============================================
        // PHASE 2: COUNTING - Track DOWN → UP cycles
        // ============================================
        // 
        // Logic:
        // 1. Wait for DOWN position (arms bent)
        // 2. When they push back UP → count +1
        // 3. Reset and wait for next DOWN
        //
        // This ensures: DOWN → UP = 1 rep (counted at TOP)
        // ============================================
        
        guard timeSinceLastChange >= minimumStateDuration else { return }
        
        // Detect DOWN position
        if isDown && !isInDownPosition {
            isInDownPosition = true
            hasCompletedDownPhase = true
            currentState = .down
            lastStateChangeTime = now
            print("[PushUp] ↓ DOWN detected (angle: \(Int(elbowAngle))°)")
        }
        // Detect UP position AFTER being down
        else if isUp && isInDownPosition && hasCompletedDownPhase {
            // COUNT THE REP! They went DOWN and came back UP
            repCount += 1
            
            // Reset for next rep
            isInDownPosition = false
            hasCompletedDownPhase = false
            currentState = .up
            lastStateChangeTime = now
            
            print("[PushUp] ↑ UP - Rep #\(repCount) counted! (angle: \(Int(elbowAngle))°)")
        }
        // They came up but weren't fully down - just update state
        else if isUp && !isInDownPosition {
            currentState = .up
            // Don't update lastStateChangeTime - no state change
        }
        // Transitioning
        else if !isUp && !isDown {
            currentState = .transitioning
        }
    }
}

// MARK: - Supporting Types

enum PushUpState: String {
    case up
    case down
    case transitioning
    case unknown
}
