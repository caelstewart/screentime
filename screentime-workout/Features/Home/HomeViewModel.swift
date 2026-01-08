//
//  HomeViewModel.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import SwiftData
import Combine

@Observable
final class HomeViewModel {
    // MARK: - Properties
    
    private(set) var balance: ScreenTimeBalance?
    private(set) var timeLimits: [AppTimeLimit] = []
    private(set) var totalPushUps: Int = 0
    private(set) var todayPushUps: Int = 0
    private(set) var thisWeekPushUps: Int = 0
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    /// Tracks last monitoring setup to avoid redundant restarts
    private var lastMonitoringLimitIds: Set<String> = []
    private var hasInitializedMonitoring = false
    
    var availableMinutes: Int {
        balance?.availableMinutes ?? 0
    }
    
    var isUnlocked: Bool {
        balance?.isUnlocked ?? false
    }
    
    var remainingUnlockMinutes: Int {
        balance?.remainingUnlockMinutes ?? 0
    }
    
    var currentStreak: Int {
        balance?.currentStreak ?? 0
    }
    
    /// Number of active time limits
    var activeLimitsCount: Int {
        timeLimits.filter { $0.isActive }.count
    }
    
    /// Number of apps currently blocked (exceeded limit)
    var blockedAppsCount: Int {
        ScreenTimeManager.shared.blockedApps.count + ScreenTimeManager.shared.blockedCategories.count
    }
    
    /// Whether any apps are currently blocked
    var hasBlockedApps: Bool {
        ScreenTimeManager.shared.shieldsActive
    }
    
    // MARK: - Methods
    
    func loadBalance(context: ModelContext) {
        let balanceDescriptor = FetchDescriptor<ScreenTimeBalance>()
        
        do {
            let balances = try context.fetch(balanceDescriptor)
            if let existing = balances.first {
                balance = existing
            } else {
                // Create initial balance
                let newBalance = ScreenTimeBalance()
                context.insert(newBalance)
                try context.save()
                balance = newBalance
            }
        } catch {
            print("[HomeVM] Failed to load balance: \(error)")
            balance = ScreenTimeBalance()
        }
        
        // Load time limits
        loadTimeLimits(context: context)
        
        // Load workout stats
        loadWorkoutStats(context: context)
        
        startUpdateTimer()
        
        // Start monitoring AFTER UI renders (defer to avoid blocking main thread)
        // This processes 21+ limits with UserDefaults writes - don't block UI
        let limitsToMonitor = timeLimits
        Task { @MainActor in
            // Small delay to let UI render first
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            startMonitoringIfNeeded(limits: limitsToMonitor, context: context)
        }
    }
    
    /// Start monitoring only if limits have changed or never started
    private func startMonitoringIfNeeded(limits: [AppTimeLimit], context: ModelContext) {
        guard !limits.isEmpty else { return }
        
        let currentIds = Set(limits.map { $0.id.uuidString })
        
        // Skip if already monitoring the same set of limits
        if hasInitializedMonitoring && currentIds == lastMonitoringLimitIds {
            return
        }
        
        lastMonitoringLimitIds = currentIds
        hasInitializedMonitoring = true
        ScreenTimeManager.shared.startMonitoring(limits: limits, context: context)
    }
    
    func loadTimeLimits(context: ModelContext) {
        let descriptor = FetchDescriptor<AppTimeLimit>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        do {
            timeLimits = try context.fetch(descriptor)
            print("[HomeVM] Loaded \(timeLimits.count) time limits from local")
            
            // Sync updates from Firebase (source of truth)
            syncTimeLimitsFromFirebase(context: context)
        } catch {
            print("[HomeVM] Failed to load time limits: \(error)")
        }
    }
    
    /// Sync time limits from Firebase to local SwiftData
    /// NOTE: Only syncs limits that have valid local tokens (app selections)
    /// Limits without tokens are cleaned up to prevent "zombie" limits
    private func syncTimeLimitsFromFirebase(context: ModelContext) {
        let firebaseLimits = UserDataManager.shared.timeLimits
        
        guard !firebaseLimits.isEmpty else {
            print("[HomeVM] No Firebase limits to sync")
            return
        }
        
        print("[HomeVM] Syncing \(firebaseLimits.count) limits from Firebase")
        
        var updatedCount = 0
        var orphanedIds: [String] = []
        
        // Update local limits with Firebase data
        // DO NOT create new limits from Firebase - they won't have tokens!
        for firebaseLimit in firebaseLimits {
            let limitUUID = UUID(uuidString: firebaseLimit.id) ?? UUID()
            
            // Find matching local limit
            if let localLimit = timeLimits.first(where: { $0.id.uuidString == firebaseLimit.id }) {
                // Check if this limit has valid tokens
                if ScreenTimeManager.shared.limitHasValidTokens(limitId: localLimit.id) {
                    // Update existing limit that has tokens
                    var needsUpdate = false
                    
                    if localLimit.dailyLimitMinutes != firebaseLimit.dailyLimitMinutes { needsUpdate = true }
                    if localLimit.displayName != firebaseLimit.displayName { needsUpdate = true }
                    if localLimit.limitTypeRaw != firebaseLimit.limitType { needsUpdate = true }
                    
                    if needsUpdate {
                        localLimit.dailyLimitMinutes = firebaseLimit.dailyLimitMinutes
                        localLimit.displayName = firebaseLimit.displayName
                        localLimit.bonusMinutesEarned = firebaseLimit.bonusMinutesEarned
                        localLimit.isActive = firebaseLimit.isActive
                        localLimit.limitTypeRaw = firebaseLimit.limitType
                        
                        // Update schedule fields
                        if let startHour = firebaseLimit.scheduleStartHour { localLimit.scheduleStartHour = startHour }
                        if let startMinute = firebaseLimit.scheduleStartMinute { localLimit.scheduleStartMinute = startMinute }
                        if let endHour = firebaseLimit.scheduleEndHour { localLimit.scheduleEndHour = endHour }
                        if let endMinute = firebaseLimit.scheduleEndMinute { localLimit.scheduleEndMinute = endMinute }
                        if let days = firebaseLimit.scheduleDays { localLimit.scheduleDays = Set(days) }
                        
                        updatedCount += 1
                    }
                } else {
                    // Local limit exists but has no tokens - mark for cleanup
                    print("[HomeVM] ⚠️ Local limit '\(localLimit.displayName)' has no tokens - marking for cleanup")
                    orphanedIds.append(firebaseLimit.id)
                }
            } else {
                // Firebase limit doesn't exist locally
                // Check if there might be tokens (from a previous install that wasn't properly cleaned)
                if ScreenTimeManager.shared.limitHasValidTokens(limitId: limitUUID) {
                    // Rare case: tokens exist but limit was deleted locally - restore it
                    let limitType = LimitType(rawValue: firebaseLimit.limitType) ?? .dailyLimit
                    let newLimit = AppTimeLimit(
                        id: limitUUID,
                        displayName: firebaseLimit.displayName,
                        limitType: limitType,
                        dailyLimitMinutes: firebaseLimit.dailyLimitMinutes,
                        bonusMinutesEarned: firebaseLimit.bonusMinutesEarned,
                        isActive: firebaseLimit.isActive,
                        scheduleStartHour: firebaseLimit.scheduleStartHour ?? 22,
                        scheduleStartMinute: firebaseLimit.scheduleStartMinute ?? 0,
                        scheduleEndHour: firebaseLimit.scheduleEndHour ?? 6,
                        scheduleEndMinute: firebaseLimit.scheduleEndMinute ?? 0,
                        scheduleDays: Set(firebaseLimit.scheduleDays ?? [1, 2, 3, 4, 5, 6, 7])
                    )
                    context.insert(newLimit)
                    print("[HomeVM] ✅ Restored limit from Firebase (has local tokens): \(firebaseLimit.displayName)")
                } else {
                    // No local tokens - this is an orphaned Firebase limit, mark for cleanup
                    print("[HomeVM] ⚠️ Firebase limit '\(firebaseLimit.displayName)' has no local tokens - marking for cleanup")
                    orphanedIds.append(firebaseLimit.id)
                }
            }
        }
        
        // Save changes
        do {
            try context.save()
        } catch {
            print("[HomeVM] Failed to save synced limits: \(error)")
        }
        
        // Clean up orphaned limits (both local and Firebase)
        if !orphanedIds.isEmpty {
            print("[HomeVM] 🧹 Cleaning up \(orphanedIds.count) orphaned limits...")
            cleanupOrphanedLimits(ids: orphanedIds, context: context)
        }
        
        // Reload the list
        let descriptor = FetchDescriptor<AppTimeLimit>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let updated = try? context.fetch(descriptor) {
            timeLimits = updated
            
            // Start monitoring with valid limits only
            let limitsToMonitor = updated.filter { ScreenTimeManager.shared.limitHasValidTokens(limitId: $0.id) }
            if !limitsToMonitor.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    startMonitoringIfNeeded(limits: limitsToMonitor, context: context)
                }
            }
        }
        
        if updatedCount > 0 {
            print("[HomeVM] Firebase sync: updated \(updatedCount) limits")
        }
    }
    
    /// Clean up orphaned limits (limits without valid app tokens)
    private func cleanupOrphanedLimits(ids: [String], context: ModelContext) {
        // Delete from local SwiftData
        for id in ids {
            if let uuid = UUID(uuidString: id),
               let localLimit = timeLimits.first(where: { $0.id == uuid }) {
                // Remove any saved selection data
                UserDefaults.standard.removeObject(forKey: "limit_selection_\(id)")
                context.delete(localLimit)
                print("[HomeVM] 🗑️ Deleted orphaned local limit: \(localLimit.displayName)")
            }
        }
        
        do {
            try context.save()
        } catch {
            print("[HomeVM] Failed to save after cleanup: \(error)")
        }
        
        // Delete from Firebase (async, don't block)
        Task {
            await UserDataManager.shared.deleteTimeLimitsBatch(ids: ids)
        }
    }
    
    func loadWorkoutStats(context: ModelContext) {
        let descriptor = FetchDescriptor<WorkoutSession>()
        
        do {
            let sessions = try context.fetch(descriptor)
            
            // Filter for push-ups only
            let pushUpSessions = sessions.filter { $0.exerciseType == ExerciseType.pushUps.rawValue }
            
            // Total all-time
            totalPushUps = pushUpSessions.reduce(0) { $0 + $1.reps }
            
            // Today
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            todayPushUps = pushUpSessions
                .filter { calendar.isDate($0.completedAt, inSameDayAs: today) }
                .reduce(0) { $0 + $1.reps }
            
            // This week
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            thisWeekPushUps = pushUpSessions
                .filter { $0.completedAt >= weekAgo }
                .reduce(0) { $0 + $1.reps }
            
        } catch {
            print("[HomeVM] Failed to load workout stats: \(error)")
        }
    }
    
    func completeWorkout(exercise: Exercise, reps: Int, context: ModelContext) {
        let minutesEarned = exercise.calculateEarnedMinutes(units: reps)
        
        // Update legacy balance (for backwards compatibility)
        balance?.addMinutes(minutesEarned)
        
        // Create workout session record
        let session = WorkoutSession(
            exerciseType: exercise.type,
            reps: reps,
            duration: 0,
            minutesEarned: minutesEarned
        )
        context.insert(session)
        
        do {
            try context.save()
        } catch {
            print("[HomeVM] Failed to save workout: \(error)")
        }
        
        // Sync to Firebase
        Task {
            await UserDataManager.shared.saveWorkout(session)
            if let balance = balance {
                await UserDataManager.shared.saveScreenTimeBalance(balance)
            }
        }
        
        // Add bonus time to the SHARED POOL
        // This extends ALL limit thresholds, but when ANY threshold is reached,
        // the bonus is consumed for all apps (fair usage-based system)
        if !timeLimits.isEmpty {
            ScreenTimeManager.shared.addBonusToPool(
                minutes: minutesEarned,
                limits: timeLimits.filter { $0.isActive },
                context: context
            )
            print("[HomeVM] Added \(minutesEarned) bonus minutes to shared pool")
        }
        
        // Refresh stats
        loadWorkoutStats(context: context)
        loadTimeLimits(context: context)
    }
    
    func unlockApps() {
        // Legacy unlock - unblock all apps temporarily
        balance?.unlock()
        ScreenTimeManager.shared.removeAllShields()
        startUpdateTimer()
    }
    
    /// Refresh data (call when view appears)
    func refresh(context: ModelContext) {
        loadTimeLimits(context: context)
        loadWorkoutStats(context: context)
        
        // Check if bonus was collapsed by the extension while app was in background
        // If so, we need to restart monitoring with base thresholds
        if ScreenTimeManager.shared.checkBonusStatus() {
            print("[HomeVM] Bonus was collapsed - refreshing monitoring with base thresholds")
            ScreenTimeManager.shared.collapseBonusPool(
                limits: timeLimits.filter { $0.isActive },
                context: context
            )
        }
        
        // Restart monitoring only if limits changed (deferred to not block UI)
        let limitsToMonitor = timeLimits
        Task { @MainActor in
            startMonitoringIfNeeded(limits: limitsToMonitor, context: context)
        }
    }
    
    // MARK: - Private Methods
    
    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // Trigger UI update for remaining time
            self?.balance = self?.balance
        }
    }
    
    deinit {
        updateTimer?.invalidate()
    }
}

#if DEBUG
extension HomeViewModel {
    func runShieldSmokeTest(context: ModelContext) {
        if timeLimits.isEmpty {
            loadTimeLimits(context: context)
        }
        ScreenTimeManager.shared.runShieldSmokeTest(
            limits: timeLimits.filter { $0.isActive },
            context: context
        )
    }
    
    func clearDebugShields() {
        ScreenTimeManager.shared.removeAllShields()
    }
}
#endif
