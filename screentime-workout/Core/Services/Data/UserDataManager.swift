//
//  UserDataManager.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2026-01-02.
//
//  Firebase Firestore is the PRIMARY database.
//  Data is cached locally by Firestore for offline support.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth
import SwiftData

/// Manages all user data persistence to Firebase Firestore (PRIMARY DATABASE)
/// Firestore handles offline caching automatically
@Observable
final class UserDataManager {
    static let shared = UserDataManager()
    
    private let db = Firestore.firestore()
    private let listenerQueue = DispatchQueue(label: "com.screentime-workout.firestore-listeners", qos: .utility)
    private var listenerRegistrations: [ListenerRegistration] = []
    private var lastTimeLimitsLogCount: Int?
    private var lastWorkoutsLogCount: Int?
    private var lastSettingsLogTime: Date?
    private var lastBalanceLogTime: Date?
    private let logThrottleInterval: TimeInterval = 2.0  // Minimum 2 seconds between logs
    
    // MARK: - Cached Data (Updated by Firestore listeners in real-time)
    private(set) var workoutSessions: [WorkoutSessionData] = []
    private(set) var timeLimits: [TimeLimitData] = []
    private(set) var userSettings: UserSettingsData = UserSettingsData()
    private(set) var screenTimeBalance: ScreenTimeBalanceData = ScreenTimeBalanceData()
    
    // Loading states
    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    
    private init() {
        // Listen for auth state changes
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            if let user = user {
                print("[UserData] Auth state changed - user: \(user.uid), anonymous: \(user.isAnonymous)")
                // Defer listener setup to let UI render first
                // Firebase listener setup can block main thread during network issues
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    print("[UserData] Starting Firebase listeners (deferred)")
                    self?.startListening(userId: user.uid)
                }
            } else {
                print("[UserData] Auth state changed - no user")
                self?.stopListening()
            }
        }
    }
    
    // MARK: - User ID Helper
    
    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }
    
    var isAnonymous: Bool {
        Auth.auth().currentUser?.isAnonymous ?? false
    }
    
    // MARK: - Data Models for Firebase
    
    struct WorkoutSessionData: Codable, Identifiable {
        var id: String
        var exerciseType: String
        var reps: Int
        var duration: Int
        var minutesEarned: Int
        var completedAt: Date
        var syncedAt: Date?
        
        init(from session: WorkoutSession) {
            self.id = session.id.uuidString
            self.exerciseType = session.exerciseType
            self.reps = session.reps
            self.duration = Int(session.duration)
            self.minutesEarned = session.minutesEarned
            self.completedAt = session.completedAt
            self.syncedAt = Date()
        }
        
        init(id: String, exerciseType: String, reps: Int, duration: Int, minutesEarned: Int, completedAt: Date) {
            self.id = id
            self.exerciseType = exerciseType
            self.reps = reps
            self.duration = duration
            self.minutesEarned = minutesEarned
            self.completedAt = completedAt
            self.syncedAt = Date()
        }
    }
    
    struct TimeLimitData: Codable, Identifiable {
        var id: String
        var displayName: String
        var limitType: String  // "daily_limit" or "scheduled"
        var dailyLimitMinutes: Int
        var bonusMinutesEarned: Int
        var isActive: Bool
        var createdAt: Date
        var syncedAt: Date?
        
        // Schedule fields
        var scheduleStartHour: Int?
        var scheduleStartMinute: Int?
        var scheduleEndHour: Int?
        var scheduleEndMinute: Int?
        var scheduleDays: [Int]?  // Array of weekday integers (1=Sunday, 7=Saturday)
        
        init(from limit: AppTimeLimit) {
            self.id = limit.id.uuidString
            self.displayName = limit.displayName
            self.limitType = limit.limitTypeRaw
            self.dailyLimitMinutes = limit.dailyLimitMinutes
            self.bonusMinutesEarned = limit.bonusMinutesEarned
            self.isActive = limit.isActive
            self.createdAt = limit.createdAt
            self.syncedAt = Date()
            
            // Schedule fields
            self.scheduleStartHour = limit.scheduleStartHour
            self.scheduleStartMinute = limit.scheduleStartMinute
            self.scheduleEndHour = limit.scheduleEndHour
            self.scheduleEndMinute = limit.scheduleEndMinute
            self.scheduleDays = Array(limit.scheduleDays)
        }
        
        init(id: String, displayName: String, limitType: String = "daily_limit", dailyLimitMinutes: Int, bonusMinutesEarned: Int, isActive: Bool, createdAt: Date,
             scheduleStartHour: Int? = nil, scheduleStartMinute: Int? = nil, scheduleEndHour: Int? = nil, scheduleEndMinute: Int? = nil, scheduleDays: [Int]? = nil) {
            self.id = id
            self.displayName = displayName
            self.limitType = limitType
            self.dailyLimitMinutes = dailyLimitMinutes
            self.bonusMinutesEarned = bonusMinutesEarned
            self.isActive = isActive
            self.createdAt = createdAt
            self.syncedAt = Date()
            self.scheduleStartHour = scheduleStartHour
            self.scheduleStartMinute = scheduleStartMinute
            self.scheduleEndHour = scheduleEndHour
            self.scheduleEndMinute = scheduleEndMinute
            self.scheduleDays = scheduleDays
        }
    }
    
    struct UserSettingsData: Codable {
        var userName: String = ""
        var selectedGoals: [String] = []
        var currentUsageHours: Double = 4
        var targetUsageHours: Double = 2
        var selectedExercise: String = ""
        var exerciseFrequency: String = ""
        var notificationsEnabled: Bool = true
        var selectedAge: String = ""
        var hasCompletedOnboarding: Bool = false
        var onboardingStep: Int = 0
        var lastUpdated: Date = Date()
    }
    
    struct ScreenTimeBalanceData: Codable {
        var availableMinutes: Int = 0
        var totalEarnedAllTime: Int = 0
        var totalWorkoutsCompleted: Int = 0
        var currentStreak: Int = 0
        var isUnlocked: Bool = false
        var unlockedUntil: Date?
        var lastWorkoutDate: Date?
        var lastUpdated: Date = Date()
    }
    
    // MARK: - Pause/Resume for Performance
    
    /// Call this when entering onboarding or other performance-critical flows
    /// Firestore listeners fire on main thread and can cause UI stalls during network issues
    private var pausedUserId: String?
    
    func pauseListeners() {
        guard !listenerRegistrations.isEmpty else { return }
        pausedUserId = currentUserId
        print("[UserData] ⏸️ Pausing Firestore listeners for performance")
        stopListening()
    }
    
    func resumeListeners() {
        guard let userId = pausedUserId ?? currentUserId else { return }
        pausedUserId = nil
        print("[UserData] ▶️ Resuming Firestore listeners")
        startListening(userId: userId)
    }
    
    // MARK: - Start/Stop Listening
    
    private func startListening(userId: String) {
        stopListening() // Clear any existing listeners
        
        // Listen to workout sessions
        let workoutsRef = db.collection("users").document(userId).collection("workouts")
        let workoutsListener = workoutsRef
            .order(by: "completedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
            if let error = error {
                print("[UserData] Workouts listener error: \(error.localizedDescription)")
                return
            }
            
            guard let documents = snapshot?.documents else { return }
            
                self?.listenerQueue.async {
                    let sessions = documents.compactMap { doc in
                        try? doc.data(as: WorkoutSessionData.self)
                    }
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.workoutSessions = sessions
                        
                        // Only log if count changed (avoid spam from sync operations)
                        let newCount = sessions.count
                        if self.lastWorkoutsLogCount != newCount {
                            self.lastWorkoutsLogCount = newCount
                            print("[UserData] Loaded \(newCount) workouts from Firebase")
                        }
                    }
            }
        }
        listenerRegistrations.append(workoutsListener)
        
        // Listen to time limits
        let limitsRef = db.collection("users").document(userId).collection("timeLimits")
        let limitsListener = limitsRef.addSnapshotListener { [weak self] snapshot, error in
            if let error = error {
                print("[UserData] Time limits listener error: \(error.localizedDescription)")
                return
            }
            
            guard let documents = snapshot?.documents else { return }
            
            self?.listenerQueue.async {
                let limits = documents.compactMap { doc in
                    try? doc.data(as: TimeLimitData.self)
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.timeLimits = limits
                    
                    let newCount = limits.count
                    if self.lastTimeLimitsLogCount != newCount {
                        self.lastTimeLimitsLogCount = newCount
                        print("[UserData] Loaded \(newCount) time limits from Firebase")
                    }
                }
            }
        }
        listenerRegistrations.append(limitsListener)
        
        // Listen to user settings
        let settingsRef = db.collection("users").document(userId)
        let settingsListener = settingsRef.addSnapshotListener { [weak self] snapshot, error in
            if let error = error {
                print("[UserData] Settings listener error: \(error.localizedDescription)")
                return
            }
            
            if let data = snapshot?.data() {
                self?.listenerQueue.async {
                    let settings = UserSettingsData(
                        userName: data["userName"] as? String ?? "",
                        selectedGoals: data["selectedGoals"] as? [String] ?? [],
                        currentUsageHours: data["currentUsageHours"] as? Double ?? 4,
                        targetUsageHours: data["targetUsageHours"] as? Double ?? 2,
                        selectedExercise: data["selectedExercise"] as? String ?? "",
                        exerciseFrequency: data["exerciseFrequency"] as? String ?? "",
                        notificationsEnabled: data["notificationsEnabled"] as? Bool ?? true,
                        selectedAge: data["selectedAge"] as? String ?? "",
                        hasCompletedOnboarding: data["hasCompletedOnboarding"] as? Bool ?? false,
                        onboardingStep: data["onboardingStep"] as? Int ?? 0,
                        lastUpdated: (data["lastUpdated"] as? Timestamp)?.dateValue() ?? Date()
                    )
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.userSettings = settings
                        
                        // Throttle logging
                        let now = Date()
                        if self.lastSettingsLogTime == nil || now.timeIntervalSince(self.lastSettingsLogTime ?? .distantPast) > self.logThrottleInterval {
                            self.lastSettingsLogTime = now
                            print("[UserData] Loaded user settings from Firebase")
                        }
                    }
                }
            }
        }
        listenerRegistrations.append(settingsListener)
        
        // Listen to screen time balance
        let balanceRef = db.collection("users").document(userId).collection("balance").document("current")
        let balanceListener = balanceRef.addSnapshotListener { [weak self] snapshot, error in
            if let error = error {
                print("[UserData] Balance listener error: \(error.localizedDescription)")
                return
            }
            
            if let data = snapshot?.data() {
                self?.listenerQueue.async {
                    let balance = ScreenTimeBalanceData(
                        availableMinutes: data["availableMinutes"] as? Int ?? 0,
                        totalEarnedAllTime: data["totalEarnedAllTime"] as? Int ?? 0,
                        totalWorkoutsCompleted: data["totalWorkoutsCompleted"] as? Int ?? 0,
                        currentStreak: data["currentStreak"] as? Int ?? 0,
                        isUnlocked: data["isUnlocked"] as? Bool ?? false,
                        unlockedUntil: (data["unlockedUntil"] as? Timestamp)?.dateValue(),
                        lastWorkoutDate: (data["lastWorkoutDate"] as? Timestamp)?.dateValue(),
                        lastUpdated: (data["lastUpdated"] as? Timestamp)?.dateValue() ?? Date()
                    )
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.screenTimeBalance = balance
                        
                        // Throttle logging
                        let now = Date()
                        if self.lastBalanceLogTime == nil || now.timeIntervalSince(self.lastBalanceLogTime ?? .distantPast) > self.logThrottleInterval {
                            self.lastBalanceLogTime = now
                            print("[UserData] Loaded screen time balance from Firebase")
                        }
                    }
                }
            }
        }
        listenerRegistrations.append(balanceListener)
    }
    
    private func stopListening() {
        listenerRegistrations.forEach { $0.remove() }
        listenerRegistrations.removeAll()
    }
    
    // MARK: - Save Workout Session
    
    func saveWorkout(_ session: WorkoutSession) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot save workout")
            return
        }
        
        let data = WorkoutSessionData(from: session)
        
        do {
            try await db.collection("users").document(userId)
                .collection("workouts").document(data.id)
                .setData(from: data)
            print("[UserData] Saved workout to Firebase: \(data.id)")
        } catch {
            print("[UserData] Failed to save workout: \(error.localizedDescription)")
        }
    }
    
    func deleteWorkout(id: String) async {
        guard let userId = currentUserId else { return }
        
        do {
            try await db.collection("users").document(userId)
                .collection("workouts").document(id)
                .delete()
            print("[UserData] Deleted workout from Firebase: \(id)")
        } catch {
            print("[UserData] Failed to delete workout: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Save Time Limit
    
    /// Save time limit from SwiftData model (for backwards compatibility)
    func saveTimeLimit(_ limit: AppTimeLimit) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot save time limit")
            return
        }
        
        let data = TimeLimitData(from: limit)
        
        do {
            try await db.collection("users").document(userId)
                .collection("timeLimits").document(data.id)
                .setData(from: data)
            print("[UserData] Saved time limit to Firebase: \(data.id)")
        } catch {
            print("[UserData] Failed to save time limit: \(error.localizedDescription)")
        }
    }
    
    /// Save time limit directly to Firebase (PRIMARY METHOD)
    func saveTimeLimitDirect(
        id: String,
        displayName: String,
        limitType: String = "daily_limit",
        dailyLimitMinutes: Int,
        bonusMinutesEarned: Int = 0,
        isActive: Bool = true,
        scheduleStartHour: Int? = nil,
        scheduleStartMinute: Int? = nil,
        scheduleEndHour: Int? = nil,
        scheduleEndMinute: Int? = nil,
        scheduleDays: [Int]? = nil
    ) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot save time limit")
            return
        }
        
        print("[UserData] → Saving time limit direct: \(displayName) = \(dailyLimitMinutes) min, type: \(limitType) (active: \(isActive))")
        
        var data: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "limitType": limitType,
            "dailyLimitMinutes": dailyLimitMinutes,
            "bonusMinutesEarned": bonusMinutesEarned,
            "isActive": isActive,
            "createdAt": FieldValue.serverTimestamp(),
            "syncedAt": FieldValue.serverTimestamp()
        ]
        
        // Add schedule fields if present
        if let startHour = scheduleStartHour { data["scheduleStartHour"] = startHour }
        if let startMinute = scheduleStartMinute { data["scheduleStartMinute"] = startMinute }
        if let endHour = scheduleEndHour { data["scheduleEndHour"] = endHour }
        if let endMinute = scheduleEndMinute { data["scheduleEndMinute"] = endMinute }
        if let days = scheduleDays { data["scheduleDays"] = days }
        
        do {
            try await db.collection("users").document(userId)
                .collection("timeLimits").document(id)
                .setData(data, merge: true)
            print("[UserData] Saved time limit to Firebase: \(id) - \(displayName)")
        } catch {
            print("[UserData] Failed to save time limit: \(error.localizedDescription)")
        }
    }
    
    /// Update just the minutes for a time limit
    func updateTimeLimitMinutes(id: String, dailyLimitMinutes: Int) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot update time limit")
            return
        }
        
        do {
            try await db.collection("users").document(userId)
                .collection("timeLimits").document(id)
                .updateData([
                    "dailyLimitMinutes": dailyLimitMinutes,
                    "syncedAt": FieldValue.serverTimestamp()
                ])
            print("[UserData] Updated time limit minutes: \(id) = \(dailyLimitMinutes) min")
        } catch {
            print("[UserData] Failed to update time limit: \(error.localizedDescription)")
        }
    }
    
    /// Update time limit name and minutes
    func updateTimeLimit(id: String, displayName: String, dailyLimitMinutes: Int) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot update time limit")
            return
        }
        
        do {
            try await db.collection("users").document(userId)
                .collection("timeLimits").document(id)
                .updateData([
                    "displayName": displayName,
                    "dailyLimitMinutes": dailyLimitMinutes,
                    "syncedAt": FieldValue.serverTimestamp()
                ])
            print("[UserData] Updated time limit: \(id) - \(displayName) = \(dailyLimitMinutes) min")
        } catch {
            print("[UserData] Failed to update time limit: \(error.localizedDescription)")
        }
    }
    
    func deleteTimeLimit(id: String) async {
        guard let userId = currentUserId else { return }
        
        do {
            try await db.collection("users").document(userId)
                .collection("timeLimits").document(id)
                .delete()
            print("[UserData] Deleted time limit from Firebase: \(id)")
        } catch {
            print("[UserData] Failed to delete time limit: \(error.localizedDescription)")
        }
    }
    
    /// Delete multiple time limits from Firebase (batch operation)
    func deleteTimeLimitsBatch(ids: [String]) async {
        guard let userId = currentUserId else { return }
        guard !ids.isEmpty else { return }
        
        print("[UserData] Deleting \(ids.count) time limits from Firebase...")
        
        let batch = db.batch()
        
        for id in ids {
            let docRef = db.collection("users").document(userId)
                .collection("timeLimits").document(id)
            batch.deleteDocument(docRef)
        }
        
        do {
            try await batch.commit()
            print("[UserData] ✅ Successfully deleted \(ids.count) time limits from Firebase")
            
            // Update local cache
            timeLimits.removeAll { ids.contains($0.id) }
        } catch {
            print("[UserData] ❌ Failed to delete time limits batch: \(error.localizedDescription)")
        }
    }
    
    /// Delete ALL time limits for the current user from Firebase
    func deleteAllTimeLimits() async {
        guard let userId = currentUserId else { return }
        
        print("[UserData] Deleting ALL time limits from Firebase...")
        
        do {
            let snapshot = try await db.collection("users").document(userId)
                .collection("timeLimits").getDocuments()
            
            let batch = db.batch()
            for doc in snapshot.documents {
                batch.deleteDocument(doc.reference)
            }
            
            try await batch.commit()
            print("[UserData] ✅ Deleted all \(snapshot.documents.count) time limits from Firebase")
            
            // Clear local cache
            timeLimits.removeAll()
        } catch {
            print("[UserData] ❌ Failed to delete all time limits: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Save User Settings
    
    func saveUserSettings(_ settings: UserSettingsData) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot save settings")
            return
        }
        
        var updatedSettings = settings
        updatedSettings.lastUpdated = Date()
        
        let data: [String: Any] = [
            "userName": updatedSettings.userName,
            "selectedGoals": updatedSettings.selectedGoals,
            "currentUsageHours": updatedSettings.currentUsageHours,
            "targetUsageHours": updatedSettings.targetUsageHours,
            "selectedExercise": updatedSettings.selectedExercise,
            "exerciseFrequency": updatedSettings.exerciseFrequency,
            "notificationsEnabled": updatedSettings.notificationsEnabled,
            "selectedAge": updatedSettings.selectedAge,
            "hasCompletedOnboarding": updatedSettings.hasCompletedOnboarding,
            "onboardingStep": updatedSettings.onboardingStep,
            "lastUpdated": FieldValue.serverTimestamp()
        ]
        
        do {
            try await db.collection("users").document(userId).setData(data, merge: true)
            print("[UserData] Saved user settings to Firebase")
        } catch {
            print("[UserData] Failed to save settings: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Save Screen Time Balance
    
    func saveScreenTimeBalance(_ balance: ScreenTimeBalance) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot save balance")
            return
        }
        
        var data: [String: Any] = [
            "availableMinutes": balance.availableMinutes,
            "totalEarnedAllTime": balance.totalEarnedAllTime,
            "totalWorkoutsCompleted": balance.totalWorkoutsCompleted,
            "currentStreak": balance.currentStreak,
            "isUnlocked": balance.isUnlocked,
            "lastUpdated": FieldValue.serverTimestamp()
        ]
        
        if let unlockedUntil = balance.unlockedUntil {
            data["unlockedUntil"] = Timestamp(date: unlockedUntil)
        }
        
        if let lastWorkoutDate = balance.lastWorkoutDate {
            data["lastWorkoutDate"] = Timestamp(date: lastWorkoutDate)
        }
        
        do {
            try await db.collection("users").document(userId)
                .collection("balance").document("current")
                .setData(data, merge: true)
            print("[UserData] Saved screen time balance to Firebase")
        } catch {
            print("[UserData] Failed to save balance: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Sync Local Data to Firebase
    
    /// Syncs all local SwiftData to Firebase (call after login or periodically)
    @MainActor
    func syncLocalDataToFirebase(context: ModelContext) async {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot sync")
            return
        }
        
        if isSyncing {
            print("[UserData] Sync already in progress, skipping.")
            return
        }
        
        isSyncing = true
        let syncStart = Date()
        defer {
            isSyncing = false
            lastSyncDate = Date()
        }
        
        print("[UserData] ⏱️ Sync start for user: \(userId)")
        
        // Sync workout sessions
        do {
            let descriptor = FetchDescriptor<WorkoutSession>()
            let sessions = try context.fetch(descriptor)
            
            for session in sessions {
                await saveWorkout(session)
            }
            print("[UserData] Synced \(sessions.count) workout sessions")
        } catch {
            print("[UserData] Failed to fetch workout sessions: \(error)")
        }
        
        // Sync time limits
        do {
            let descriptor = FetchDescriptor<AppTimeLimit>()
            let limits = try context.fetch(descriptor)
            
            if !limits.isEmpty {
                try await saveTimeLimitsBatch(limits, userId: userId)
                print("[UserData] Synced \(limits.count) time limits (batched)")
            } else {
                print("[UserData] No time limits to sync")
            }
        } catch {
            print("[UserData] Failed to fetch time limits: \(error)")
        }
        
        // Sync screen time balance
        do {
            let descriptor = FetchDescriptor<ScreenTimeBalance>()
            let balances = try context.fetch(descriptor)
            
            if let balance = balances.first {
                await saveScreenTimeBalance(balance)
            }
            print("[UserData] Synced screen time balance")
        } catch {
            print("[UserData] Failed to fetch balance: \(error)")
        }
        
        // Sync user settings from UserDefaults
        let onboardingManager = OnboardingDataManager.shared
        let settings = UserSettingsData(
            userName: onboardingManager.loadUserName(),
            selectedGoals: Array(onboardingManager.loadSelectedGoals()),
            currentUsageHours: onboardingManager.loadCurrentUsageHours(),
            targetUsageHours: onboardingManager.loadTargetUsageHours(),
            selectedExercise: onboardingManager.loadSelectedExercise(),
            exerciseFrequency: onboardingManager.loadExerciseFrequency(),
            notificationsEnabled: !onboardingManager.loadNotificationsDenied(),
            selectedAge: onboardingManager.loadSelectedAge(),
            hasCompletedOnboarding: onboardingManager.hasCompletedOnboarding(),
            onboardingStep: onboardingManager.loadCurrentStep(),
            lastUpdated: Date()
        )
        await saveUserSettings(settings)
        
        let elapsed = Date().timeIntervalSince(syncStart)
        print(String(format: "[UserData] ✅ Sync completed in %.2fs", elapsed))
    }
    
    // MARK: - Restore from Firebase to Local
    
    /// Restores Firebase data to local SwiftData (call when user logs in on new device)
    func restoreFromFirebase(context: ModelContext) async -> Bool {
        guard let userId = currentUserId else {
            print("[UserData] No user ID, cannot restore")
            return false
        }
        
        isSyncing = true
        defer { 
            isSyncing = false
            lastSyncDate = Date()
        }
        
        let start = Date()
        print("[UserData] ⏱️ Restore start for user: \(userId)")
        
        do {
            // Restore workout sessions
            let workoutsSnapshot = try await db.collection("users").document(userId)
                .collection("workouts")
                .getDocuments()
            
            for doc in workoutsSnapshot.documents {
                if let data = try? doc.data(as: WorkoutSessionData.self),
                   let dataUUID = UUID(uuidString: data.id) {
                    // Check if session already exists locally
                    // Note: SwiftData predicates can't use .uuidString on UUID, so compare UUIDs directly
                    let existingDescriptor = FetchDescriptor<WorkoutSession>(
                        predicate: #Predicate { $0.id == dataUUID }
                    )
                    let existing = try? context.fetch(existingDescriptor)
                    
                    if existing?.isEmpty ?? true {
                        let exerciseType = ExerciseType(rawValue: data.exerciseType) ?? .pushUps
                        let session = WorkoutSession(
                            exerciseType: exerciseType,
                            reps: data.reps,
                            duration: TimeInterval(data.duration),
                            minutesEarned: data.minutesEarned
                        )
                        context.insert(session)
                    }
                }
            }
            print("[UserData] Restored \(workoutsSnapshot.documents.count) workouts")
            
            // Restore time limits
            let limitsSnapshot = try await db.collection("users").document(userId)
                .collection("timeLimits")
                .getDocuments()
            
            for doc in limitsSnapshot.documents {
                if let data = try? doc.data(as: TimeLimitData.self),
                   let dataUUID = UUID(uuidString: data.id) {
                    // Check if limit already exists locally
                    // Note: SwiftData predicates can't use .uuidString on UUID, so compare UUIDs directly
                    let existingDescriptor = FetchDescriptor<AppTimeLimit>(
                        predicate: #Predicate { $0.id == dataUUID }
                    )
                    let existing = try? context.fetch(existingDescriptor)
                    
                    if existing?.isEmpty ?? true {
                        let limitType = LimitType(rawValue: data.limitType) ?? .dailyLimit
                        let limit = AppTimeLimit(
                            displayName: data.displayName,
                            limitType: limitType,
                            dailyLimitMinutes: data.dailyLimitMinutes,
                            bonusMinutesEarned: data.bonusMinutesEarned,
                            isActive: data.isActive,
                            scheduleStartHour: data.scheduleStartHour ?? 22,
                            scheduleStartMinute: data.scheduleStartMinute ?? 0,
                            scheduleEndHour: data.scheduleEndHour ?? 6,
                            scheduleEndMinute: data.scheduleEndMinute ?? 0,
                            scheduleDays: Set(data.scheduleDays ?? [1, 2, 3, 4, 5, 6, 7])
                        )
                        context.insert(limit)
                    }
                }
            }
            print("[UserData] Restored \(limitsSnapshot.documents.count) time limits")
            
            // Restore user settings to UserDefaults
            let settingsDoc = try await db.collection("users").document(userId).getDocument()
            if let data = settingsDoc.data() {
                let onboardingManager = OnboardingDataManager.shared
                
                if let name = data["userName"] as? String, !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: "onboarding_user_name")
                }
                if let goals = data["selectedGoals"] as? [String] {
                    UserDefaults.standard.set(goals, forKey: "onboarding_selected_goals")
                }
                if let hours = data["currentUsageHours"] as? Double {
                    UserDefaults.standard.set(hours, forKey: "onboarding_current_usage_hours")
                }
                if let hours = data["targetUsageHours"] as? Double {
                    UserDefaults.standard.set(hours, forKey: "onboarding_target_usage_hours")
                }
                if let exercise = data["selectedExercise"] as? String {
                    UserDefaults.standard.set(exercise, forKey: "onboarding_selected_exercise")
                }
                if let frequency = data["exerciseFrequency"] as? String {
                    UserDefaults.standard.set(frequency, forKey: "onboarding_exercise_frequency")
                }
                if let age = data["selectedAge"] as? String {
                    UserDefaults.standard.set(age, forKey: "onboarding_selected_age")
                }
                if let completed = data["hasCompletedOnboarding"] as? Bool {
                    UserDefaults.standard.set(completed, forKey: "hasCompletedOnboarding")
                }
                if let step = data["onboardingStep"] as? Int {
                    UserDefaults.standard.set(step, forKey: "onboarding_current_step")
                }
                
                print("[UserData] Restored user settings")
            }
            
            try context.save()
            print("[UserData] Restore completed successfully")
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "[UserData] ✅ Restore completed in %.2fs", elapsed))
        return true
            
        } catch {
            print("[UserData] Restore failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Merge Anonymous Data to Real Account
    
    /// Call this after linking anonymous account to real account
    /// Copies all data from anonymous account to the new linked account
    func mergeAnonymousData(fromAnonymousId: String, toRealId: String) async {
        print("[UserData] Merging data from anonymous: \(fromAnonymousId) to real: \(toRealId)")
        
        do {
            // Copy workouts
            let workoutsSnapshot = try await db.collection("users").document(fromAnonymousId)
                .collection("workouts")
                .getDocuments()
            
            for doc in workoutsSnapshot.documents {
                let data = doc.data()
                try await db.collection("users").document(toRealId)
                    .collection("workouts").document(doc.documentID)
                    .setData(data)
            }
            print("[UserData] Merged \(workoutsSnapshot.documents.count) workouts")
            
            // Copy time limits
            let limitsSnapshot = try await db.collection("users").document(fromAnonymousId)
                .collection("timeLimits")
                .getDocuments()
            
            for doc in limitsSnapshot.documents {
                let data = doc.data()
                try await db.collection("users").document(toRealId)
                    .collection("timeLimits").document(doc.documentID)
                    .setData(data)
            }
            print("[UserData] Merged \(limitsSnapshot.documents.count) time limits")
            
            // Copy balance
            let balanceDoc = try await db.collection("users").document(fromAnonymousId)
                .collection("balance").document("current")
                .getDocument()
            
            if let data = balanceDoc.data() {
                try await db.collection("users").document(toRealId)
                    .collection("balance").document("current")
                    .setData(data)
                print("[UserData] Merged balance")
            }
            
            // Copy user settings (merge, don't overwrite)
            let settingsDoc = try await db.collection("users").document(fromAnonymousId).getDocument()
            if let data = settingsDoc.data() {
                try await db.collection("users").document(toRealId).setData(data, merge: true)
                print("[UserData] Merged user settings")
            }
            
            print("[UserData] Merge completed successfully")
            
        } catch {
            print("[UserData] Merge failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func saveTimeLimitsBatch(_ limits: [AppTimeLimit], userId: String) async throws {
        let batch = db.batch()
        
        for limit in limits {
            let doc = db.collection("users").document(userId)
                .collection("timeLimits").document(limit.id.uuidString)
            
            var data: [String: Any] = [
                "id": limit.id.uuidString,
                "displayName": limit.displayName,
                "limitType": limit.limitTypeRaw,
                "dailyLimitMinutes": limit.dailyLimitMinutes,
                "bonusMinutesEarned": limit.bonusMinutesEarned,
                "isActive": limit.isActive,
                "createdAt": Timestamp(date: limit.createdAt),
                "syncedAt": FieldValue.serverTimestamp(),
                "scheduleStartHour": limit.scheduleStartHour,
                "scheduleStartMinute": limit.scheduleStartMinute,
                "scheduleEndHour": limit.scheduleEndHour,
                "scheduleEndMinute": limit.scheduleEndMinute,
                "scheduleDays": Array(limit.scheduleDays)
            ]
            
            batch.setData(data, forDocument: doc, merge: true)
        }
        
        try await batch.commit()
    }
}

