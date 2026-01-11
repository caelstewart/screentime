//
//  PlankAnalyzer.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2026-01-11.
//

import Foundation

@Observable
final class PlankAnalyzer {
    // MARK: - Properties
    
    private(set) var repCount: Int = 0  // Each "rep" = 20 seconds of plank
    private(set) var currentState: PlankState = .unknown
    private(set) var feedback: String = "Get into plank position"
    private(set) var secondsHeld: Int = 0  // Total seconds in valid plank position
    
    // Whether to show positioning feedback (only before workout starts)
    private(set) var showPositioningFeedback: Bool = true
    
    // MARK: - Plank Detection
    
    // For plank detection, we check:
    // 1. Body is roughly horizontal (shoulders and hips at similar Y level)
    // 2. Body is low (not standing)
    private let horizontalToleranceRatio: Double = 0.15  // Allow 15% variance in Y position
    private let minBodyLowness: Double = 0.4  // Body should be in lower 40% of screen (higher Y value)
    
    // MARK: - Timing
    
    private var plankStartTime: Date?
    private var lastTickTime: Date?
    private let secondsPerRep: Int = 20  // +1 rep for every 20 seconds
    
    // Track accumulated time for current plank hold
    private var currentHoldDuration: TimeInterval = 0
    
    // STATE MACHINE
    private var isReadyToCount = false
    private var isInPlankPosition = false
    
    // Hold timer for initial position detection
    private var positionHoldStartTime: Date?
    private let requiredInitialHold: TimeInterval = 1.0
    
    // Grace period for brief pose detection loss
    private var lastValidPoseTime: Date?
    private let gracePeriod: TimeInterval = 0.5
    
    // MARK: - Public Methods
    
    func reset() {
        repCount = 0
        secondsHeld = 0
        currentState = .unknown
        feedback = "Get into plank position"
        showPositioningFeedback = true
        plankStartTime = nil
        lastTickTime = nil
        currentHoldDuration = 0
        isReadyToCount = false
        isInPlankPosition = false
        positionHoldStartTime = nil
        lastValidPoseTime = nil
    }
    
    func analyze(pose: DetectedPose?) {
        let now = Date()
        
        // Check if pose is valid for plank
        let plankDetected = pose != nil && isValidPlankPosition(pose!)
        
        if plankDetected {
            lastValidPoseTime = now
        }
        
        // Allow brief pose detection loss (grace period)
        let effectivelyInPlank: Bool
        if plankDetected {
            effectivelyInPlank = true
        } else if let lastValid = lastValidPoseTime,
                  now.timeIntervalSince(lastValid) < gracePeriod {
            effectivelyInPlank = true  // Still within grace period
        } else {
            effectivelyInPlank = false
        }
        
        // ============================================
        // PHASE 1: SETUP - Wait for user to get into plank
        // ============================================
        if !isReadyToCount {
            if effectivelyInPlank {
                if positionHoldStartTime == nil {
                    positionHoldStartTime = now
                    feedback = "Hold position..."
                    showPositioningFeedback = true
                    currentState = .gettingInPosition
                } else if now.timeIntervalSince(positionHoldStartTime!) >= requiredInitialHold {
                    // Ready to start counting!
                    isReadyToCount = true
                    isInPlankPosition = true
                    showPositioningFeedback = false
                    feedback = ""
                    currentState = .holding
                    plankStartTime = now
                    lastTickTime = now
                    print("[Plank] ✓ Ready to count - plank position detected")
                }
            } else {
                positionHoldStartTime = nil
                currentState = .notInPosition
                feedback = "Get into plank position"
                showPositioningFeedback = true
            }
            return
        }
        
        // ============================================
        // PHASE 2: COUNTING - Track hold duration
        // ============================================
        
        if effectivelyInPlank {
            if !isInPlankPosition {
                // Returned to plank position
                isInPlankPosition = true
                currentState = .holding
                print("[Plank] Returned to plank position")
            }
            
            // Update hold duration
            if let lastTick = lastTickTime {
                let increment = now.timeIntervalSince(lastTick)
                currentHoldDuration += increment
                
                // Check if we've completed a second
                let newSecondsHeld = Int(currentHoldDuration)
                if newSecondsHeld > secondsHeld {
                    secondsHeld = newSecondsHeld
                    
                    // Check if we've earned another rep (every 20 seconds)
                    let newRepCount = secondsHeld / secondsPerRep
                    if newRepCount > repCount {
                        repCount = newRepCount
                        print("[Plank] +1 rep! Total: \(repCount) (held for \(secondsHeld) seconds)")
                    }
                }
            }
            lastTickTime = now
            
        } else {
            // Lost plank position
            if isInPlankPosition {
                isInPlankPosition = false
                currentState = .broken
                feedback = "Get back into position!"
                showPositioningFeedback = true
                print("[Plank] Position lost after \(secondsHeld) seconds")
            }
            // Don't reset lastTickTime - we'll resume counting when they get back in position
        }
    }
    
    // MARK: - Private Methods
    
    private func isValidPlankPosition(_ pose: DetectedPose) -> Bool {
        // Get key body points
        guard let leftShoulder = pose.joint(.leftShoulder),
              let rightShoulder = pose.joint(.rightShoulder),
              let leftHip = pose.joint(.leftHip),
              let rightHip = pose.joint(.rightHip) else {
            return false
        }
        
        // Calculate average positions
        let shoulderY = (leftShoulder.position.y + rightShoulder.position.y) / 2.0
        let hipY = (leftHip.position.y + rightHip.position.y) / 2.0
        
        // Check 1: Body should be roughly horizontal
        // Shoulders and hips should be at similar Y levels
        let yDifference = abs(shoulderY - hipY)
        let bodyHeight = abs(shoulderY - hipY)
        let screenSpan = max(shoulderY, hipY) - min(shoulderY, hipY)
        
        // The Y difference should be small relative to screen size
        // In a plank, shoulders and hips are roughly level
        let isHorizontal = yDifference < horizontalToleranceRatio
        
        // Check 2: Body should be low (not standing)
        // In Vision coordinates, Y increases downward (0 = top, 1 = bottom)
        // Plank position means body is in the lower portion of the frame
        // But since camera faces user from front, we just need to see them horizontal
        let avgBodyY = (shoulderY + hipY) / 2.0
        
        // For front-facing camera, we mainly care about horizontal alignment
        // The person could be anywhere in frame as long as body is horizontal
        
        // Also check: ankles should be visible and roughly aligned with body
        let hasAnkles = pose.joint(.leftAnkle) != nil || pose.joint(.rightAnkle) != nil
        
        // Debug logging occasionally
        if Int.random(in: 0...30) == 0 {
            print("[Plank] Position check - yDiff: \(String(format: "%.3f", yDifference)), isHorizontal: \(isHorizontal), hasAnkles: \(hasAnkles)")
        }
        
        // For plank: body horizontal, ankles visible
        return isHorizontal && hasAnkles
    }
}

// MARK: - Supporting Types

enum PlankState: String {
    case holding       // In valid plank position, counting time
    case broken        // Was in plank but position lost
    case gettingInPosition  // Detected plank, waiting for hold confirmation
    case notInPosition // Not in plank position yet
    case unknown
}
