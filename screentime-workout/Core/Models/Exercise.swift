//
//  Exercise.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Foundation

enum ExerciseType: String, Codable, CaseIterable {
    case pushUps = "push_ups"
    case squats = "squats"
    case plank = "plank"
    
    var displayName: String {
        switch self {
        case .pushUps: return "Push-ups"
        case .squats: return "Squats"
        case .plank: return "Plank"
        }
    }
    
    var icon: String {
        switch self {
        case .pushUps: return "figure.strengthtraining.traditional"
        case .squats: return "figure.stand"
        case .plank: return "figure.core.training"
        }
    }
    
    var isTimeBased: Bool {
        switch self {
        case .plank: return true
        default: return false
        }
    }
    
    var unitLabel: String {
        isTimeBased ? "sec" : "rep"
    }
}

struct Exercise: Identifiable, Codable {
    let id: UUID
    let type: ExerciseType
    let minutesPerUnit: Int  // Minutes earned per rep (or per 10 seconds for plank)
    
    init(id: UUID = UUID(), type: ExerciseType, minutesPerUnit: Int = 2) {
        self.id = id
        self.type = type
        self.minutesPerUnit = minutesPerUnit
    }
    
    var displayName: String { type.displayName }
    var icon: String { type.icon }
    
    func calculateEarnedMinutes(units: Int) -> Int {
        units * minutesPerUnit
    }
    
    // Default exercises
    static let pushUps = Exercise(type: .pushUps, minutesPerUnit: 2)
    static let squats = Exercise(type: .squats, minutesPerUnit: 2)
    static let plank = Exercise(type: .plank, minutesPerUnit: 1) // 1 min per 10 seconds held
    
    static let allDefault: [Exercise] = [.pushUps, .squats, .plank]
}

