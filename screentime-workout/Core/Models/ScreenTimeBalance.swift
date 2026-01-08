//
//  ScreenTimeBalance.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Foundation
import SwiftData

@Model
final class ScreenTimeBalance {
    var availableMinutes: Int
    var unlockedUntil: Date?
    var totalEarnedAllTime: Int
    var totalWorkoutsCompleted: Int
    var currentStreak: Int
    var lastWorkoutDate: Date?
    
    init(
        availableMinutes: Int = 0,
        unlockedUntil: Date? = nil,
        totalEarnedAllTime: Int = 0,
        totalWorkoutsCompleted: Int = 0,
        currentStreak: Int = 0,
        lastWorkoutDate: Date? = nil
    ) {
        self.availableMinutes = availableMinutes
        self.unlockedUntil = unlockedUntil
        self.totalEarnedAllTime = totalEarnedAllTime
        self.totalWorkoutsCompleted = totalWorkoutsCompleted
        self.currentStreak = currentStreak
        self.lastWorkoutDate = lastWorkoutDate
    }
    
    var isUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return Date() < unlockedUntil
    }
    
    var remainingUnlockTime: TimeInterval {
        guard let unlockedUntil else { return 0 }
        return max(0, unlockedUntil.timeIntervalSinceNow)
    }
    
    var remainingUnlockMinutes: Int {
        Int(ceil(remainingUnlockTime / 60))
    }
    
    func addMinutes(_ minutes: Int) {
        availableMinutes += minutes
        totalEarnedAllTime += minutes
        totalWorkoutsCompleted += 1
        updateStreak()
    }
    
    func unlock() {
        guard availableMinutes > 0 else { return }
        
        let minutesToUnlock = availableMinutes
        unlockedUntil = Date().addingTimeInterval(TimeInterval(minutesToUnlock * 60))
        availableMinutes = 0
        
        // Remove all shields (legacy unlock behavior)
//        ScreenTimeManager.shared.removeAllShields()
    }
    
    private func updateStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        if let lastDate = lastWorkoutDate {
            let lastDay = calendar.startOfDay(for: lastDate)
            let daysDiff = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
            
            if daysDiff == 1 {
                // Consecutive day
                currentStreak += 1
            } else if daysDiff > 1 {
                // Streak broken
                currentStreak = 1
            }
            // daysDiff == 0 means same day, don't increment streak
        } else {
            currentStreak = 1
        }
        
        lastWorkoutDate = Date()
    }
}

