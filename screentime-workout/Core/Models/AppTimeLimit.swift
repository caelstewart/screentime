//
//  AppTimeLimit.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-30.
//

import Foundation
import SwiftData
import FamilyControls
import ManagedSettings

/// Type of time limit
enum LimitType: String, Codable, CaseIterable {
    case dailyLimit = "daily_limit"      // Block after X minutes of usage per day
    case scheduled = "scheduled"          // Block during specific time windows
    
    var displayName: String {
        switch self {
        case .dailyLimit: return "Daily Limit"
        case .scheduled: return "Scheduled"
        }
    }
    
    var description: String {
        switch self {
        case .dailyLimit: return "Block apps after a certain amount of daily usage"
        case .scheduled: return "Block apps during specific times"
        }
    }
}

/// Represents a daily time limit for an app or category
@Model
final class AppTimeLimit {
    /// Unique identifier
    var id: UUID
    
    /// Display name for the app/category (for UI purposes)
    var displayName: String
    
    /// Type of limit: daily usage limit or scheduled time window
    /// Default to "daily_limit" for migration of existing records
    var limitTypeRaw: String = LimitType.dailyLimit.rawValue
    
    /// Daily time limit in minutes (for dailyLimit type)
    var dailyLimitMinutes: Int
    
    /// Bonus minutes earned through workouts (resets daily)
    var bonusMinutesEarned: Int
    
    /// Date when bonus minutes were last reset
    var bonusResetDate: Date
    
    /// Whether this limit is currently active
    var isActive: Bool
    
    /// The encoded application token (stored as Data since tokens aren't directly Codable in SwiftData)
    var applicationTokenData: Data?
    
    /// The encoded category token
    var categoryTokenData: Data?
    
    /// When this limit was created
    var createdAt: Date
    
    // MARK: - Schedule Fields (for scheduled type)
    // All have default values to allow migration of existing records
    
    /// Start hour (0-23) for scheduled blocking
    var scheduleStartHour: Int = 22
    
    /// Start minute (0-59) for scheduled blocking
    var scheduleStartMinute: Int = 0
    
    /// End hour (0-23) for scheduled blocking
    var scheduleEndHour: Int = 6
    
    /// End minute (0-59) for scheduled blocking
    var scheduleEndMinute: Int = 0
    
    /// Days of week when schedule is active (1=Sunday, 2=Monday, ... 7=Saturday)
    /// Stored as comma-separated string for SwiftData compatibility
    var scheduleDaysRaw: String = "1,2,3,4,5,6,7"
    
    // MARK: - Computed Properties
    
    var limitType: LimitType {
        get { LimitType(rawValue: limitTypeRaw) ?? .dailyLimit }
        set { limitTypeRaw = newValue.rawValue }
    }
    
    var scheduleDays: Set<Int> {
        get {
            guard !scheduleDaysRaw.isEmpty else { return [] }
            return Set(scheduleDaysRaw.split(separator: ",").compactMap { Int($0) })
        }
        set {
            scheduleDaysRaw = newValue.sorted().map { String($0) }.joined(separator: ",")
        }
    }
    
    /// Formatted schedule time string for display
    var scheduleTimeString: String {
        let startTime = formatTime(hour: scheduleStartHour, minute: scheduleStartMinute)
        let endTime = formatTime(hour: scheduleEndHour, minute: scheduleEndMinute)
        return "\(startTime) - \(endTime)"
    }
    
    /// Formatted schedule days string for display
    var scheduleDaysString: String {
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let activeDays = scheduleDays.sorted().compactMap { dayNames[safe: $0] }
        
        if activeDays.count == 7 {
            return "Every day"
        } else if activeDays == ["Mon", "Tue", "Wed", "Thu", "Fri"] {
            return "Weekdays"
        } else if activeDays == ["Sat", "Sun"] {
            return "Weekends"
        } else {
            return activeDays.joined(separator: ", ")
        }
    }
    
    private func formatTime(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }
    
    init(
        id: UUID = UUID(),
        displayName: String,
        limitType: LimitType = .dailyLimit,
        dailyLimitMinutes: Int = 30,
        bonusMinutesEarned: Int = 0,
        isActive: Bool = true,
        scheduleStartHour: Int = 22,
        scheduleStartMinute: Int = 0,
        scheduleEndHour: Int = 6,
        scheduleEndMinute: Int = 0,
        scheduleDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7] // All days by default
    ) {
        self.id = id
        self.displayName = displayName
        self.limitTypeRaw = limitType.rawValue
        self.dailyLimitMinutes = dailyLimitMinutes
        self.bonusMinutesEarned = bonusMinutesEarned
        self.bonusResetDate = Calendar.current.startOfDay(for: Date())
        self.isActive = isActive
        self.createdAt = Date()
        self.scheduleStartHour = scheduleStartHour
        self.scheduleStartMinute = scheduleStartMinute
        self.scheduleEndHour = scheduleEndHour
        self.scheduleEndMinute = scheduleEndMinute
        self.scheduleDaysRaw = scheduleDays.sorted().map { String($0) }.joined(separator: ",")
    }
    
    /// Total allowed minutes (base limit + earned bonus)
    var totalAllowedMinutes: Int {
        // Reset bonus if it's a new day
        let today = Calendar.current.startOfDay(for: Date())
        if bonusResetDate < today {
            return dailyLimitMinutes
        }
        return dailyLimitMinutes + bonusMinutesEarned
    }
    
    /// Add bonus minutes from a workout
    func addBonusMinutes(_ minutes: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        
        // Reset if new day
        if bonusResetDate < today {
            bonusMinutesEarned = 0
            bonusResetDate = today
        }
        
        bonusMinutesEarned += minutes
    }
    
    /// Reset bonus minutes (called at start of new day)
    func resetBonusIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if bonusResetDate < today {
            bonusMinutesEarned = 0
            bonusResetDate = today
        }
    }
}

// MARK: - Token Encoding/Decoding

extension AppTimeLimit {
    /// Set the application token
    func setApplicationToken(_ token: ApplicationToken) {
        do {
            applicationTokenData = try PropertyListEncoder().encode(token)
        } catch {
            print("[AppTimeLimit] Failed to encode application token: \(error)")
        }
    }
    
    /// Get the application token
    func getApplicationToken() -> ApplicationToken? {
        guard let data = applicationTokenData else { return nil }
        do {
            return try PropertyListDecoder().decode(ApplicationToken.self, from: data)
        } catch {
            print("[AppTimeLimit] Failed to decode application token: \(error)")
            return nil
        }
    }
    
    /// Set the category token
    func setCategoryToken(_ token: ActivityCategoryToken) {
        do {
            categoryTokenData = try PropertyListEncoder().encode(token)
        } catch {
            print("[AppTimeLimit] Failed to encode category token: \(error)")
        }
    }
    
    /// Get the category token
    func getCategoryToken() -> ActivityCategoryToken? {
        guard let data = categoryTokenData else { return nil }
        do {
            return try PropertyListDecoder().decode(ActivityCategoryToken.self, from: data)
        } catch {
            print("[AppTimeLimit] Failed to decode category token: \(error)")
            return nil
        }
    }
    
    /// Check if this is an app limit (vs category)
    var isAppLimit: Bool {
        applicationTokenData != nil
    }
    
    /// Check if this is a category limit
    var isCategoryLimit: Bool {
        categoryTokenData != nil
    }
    
    /// Check if currently within scheduled blocking time
    var isWithinScheduledTime: Bool {
        guard limitType == .scheduled else { return false }
        
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday
        
        // Check if today is an active day
        guard scheduleDays.contains(weekday) else { return false }
        
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTimeMinutes = currentHour * 60 + currentMinute
        
        let startTimeMinutes = scheduleStartHour * 60 + scheduleStartMinute
        let endTimeMinutes = scheduleEndHour * 60 + scheduleEndMinute
        
        // Handle overnight schedules (e.g., 22:00 - 06:00)
        if startTimeMinutes > endTimeMinutes {
            // Overnight: active if AFTER start OR BEFORE end
            return currentTimeMinutes >= startTimeMinutes || currentTimeMinutes < endTimeMinutes
        } else {
            // Same day: active if BETWEEN start and end
            return currentTimeMinutes >= startTimeMinutes && currentTimeMinutes < endTimeMinutes
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
