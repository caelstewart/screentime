//
//  WorkoutSession.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id: UUID
    var exerciseType: String  // Store as string for SwiftData compatibility
    var reps: Int
    var duration: TimeInterval
    var minutesEarned: Int
    var completedAt: Date
    
    init(
        id: UUID = UUID(),
        exerciseType: ExerciseType,
        reps: Int,
        duration: TimeInterval,
        minutesEarned: Int,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.exerciseType = exerciseType.rawValue
        self.reps = reps
        self.duration = duration
        self.minutesEarned = minutesEarned
        self.completedAt = completedAt
    }
    
    var exercise: ExerciseType {
        ExerciseType(rawValue: exerciseType) ?? .pushUps
    }
}

