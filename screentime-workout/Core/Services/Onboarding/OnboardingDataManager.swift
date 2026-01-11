//
//  OnboardingDataManager.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2026-01-02.
//

import Foundation
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

/// Manages onboarding data persistence to UserDefaults and Firebase
@Observable
final class OnboardingDataManager {
    static let shared = OnboardingDataManager()
    
    private let defaults = UserDefaults.standard
    
    // Lazy database access - only initialize Firestore when actually needed
    // (after Firebase is configured, which happens when onboarding completes)
    private var _db: Firestore?
    private var db: Firestore {
        if _db == nil {
            _db = Firestore.firestore()
        }
        return _db!
    }
    
    // MARK: - UserDefaults Keys
    private enum Keys {
        static let onboardingStep = "onboarding_current_step"
        static let userName = "onboarding_user_name"
        static let selectedGoals = "onboarding_selected_goals"
        static let currentUsageHours = "onboarding_current_usage_hours"
        static let targetUsageHours = "onboarding_target_usage_hours"
        static let selectedApps = "onboarding_selected_apps"
        static let selectedReasons = "onboarding_selected_reasons"
        static let selectedFeelings = "onboarding_selected_feelings"
        static let selectedAge = "onboarding_selected_age"
        static let selectedPreviousSolutions = "onboarding_previous_solutions"
        static let selectedExercise = "onboarding_selected_exercise"
        static let exerciseFrequency = "onboarding_exercise_frequency"
        static let notificationsDenied = "onboarding_notifications_denied"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let onboardingRepsCompleted = "onboarding_reps_completed"
        static let lastSyncTimestamp = "onboarding_last_sync"
    }
    
    // MARK: - Onboarding Data Model
    struct OnboardingData: Codable {
        var currentStep: Int
        var userName: String
        var selectedGoals: [String]
        var currentUsageHours: Double
        var targetUsageHours: Double
        var selectedApps: [String]
        var selectedReasons: [String]
        var selectedFeelings: [String]
        var selectedAge: String
        var selectedPreviousSolutions: [String]
        var selectedExercise: String
        var exerciseFrequency: String
        var notificationsDenied: Bool
        var onboardingRepsCompleted: Int
        var lastUpdated: Date
        
        init() {
            self.currentStep = 0
            self.userName = ""
            self.selectedGoals = []
            self.currentUsageHours = 4
            self.targetUsageHours = 2
            self.selectedApps = []
            self.selectedReasons = []
            self.selectedFeelings = []
            self.selectedAge = ""
            self.selectedPreviousSolutions = []
            self.selectedExercise = ""
            self.exerciseFrequency = ""
            self.notificationsDenied = false
            self.onboardingRepsCompleted = 0
            self.lastUpdated = Date()
        }
    }
    
    private init() {}
    
    // MARK: - Save Individual Values (Local Only - No Sync)
    // These save to UserDefaults immediately but DON'T trigger Firebase sync
    // Use scheduleDebouncedSync() after a batch of saves for efficient syncing
    
    func saveCurrentStep(_ step: Int) {
        defaults.set(step, forKey: Keys.onboardingStep)
    }
    
    func saveUserName(_ name: String) {
        defaults.set(name, forKey: Keys.userName)
    }
    
    func saveSelectedGoals(_ goals: Set<String>) {
        defaults.set(Array(goals), forKey: Keys.selectedGoals)
    }
    
    func saveCurrentUsageHours(_ hours: Double) {
        defaults.set(hours, forKey: Keys.currentUsageHours)
    }
    
    func saveTargetUsageHours(_ hours: Double) {
        defaults.set(hours, forKey: Keys.targetUsageHours)
    }
    
    func saveSelectedApps(_ apps: Set<String>) {
        defaults.set(Array(apps), forKey: Keys.selectedApps)
    }
    
    func saveSelectedReasons(_ reasons: Set<String>) {
        defaults.set(Array(reasons), forKey: Keys.selectedReasons)
    }
    
    func saveSelectedFeelings(_ feelings: Set<String>) {
        defaults.set(Array(feelings), forKey: Keys.selectedFeelings)
    }
    
    func saveSelectedAge(_ age: String) {
        defaults.set(age, forKey: Keys.selectedAge)
    }
    
    func saveSelectedPreviousSolutions(_ solutions: Set<String>) {
        defaults.set(Array(solutions), forKey: Keys.selectedPreviousSolutions)
    }
    
    func saveSelectedExercise(_ exercise: String) {
        defaults.set(exercise, forKey: Keys.selectedExercise)
    }
    
    func saveExerciseFrequency(_ frequency: String) {
        defaults.set(frequency, forKey: Keys.exerciseFrequency)
    }
    
    func saveNotificationsDenied(_ denied: Bool) {
        defaults.set(denied, forKey: Keys.notificationsDenied)
    }
    
    func saveOnboardingRepsCompleted(_ reps: Int) {
        defaults.set(reps, forKey: Keys.onboardingRepsCompleted)
    }
    
    func markOnboardingComplete() {
        defaults.set(true, forKey: Keys.hasCompletedOnboarding)
        // Force immediate sync when onboarding completes (important milestone)
        syncToFirebaseIfNeeded(force: true)
    }
    
    /// Call this after a batch of saves to schedule a debounced Firebase sync
    /// Much more efficient than syncing after every individual save
    /// NOTE: This now does NOTHING during onboarding - sync only happens at completion
    func scheduleDebouncedSync() {
        // SKIP syncing during onboarding - Firebase Analytics XPC reporter
        // causes massive main thread stalls when syncing with unstable network.
        // All data will be synced when markOnboardingComplete() is called.
        guard hasCompletedOnboarding() else {
            print("[OnboardingData] Skipping sync during onboarding (will sync at completion)")
            return
        }
        syncToFirebaseIfNeeded(force: false)
    }
    
    // MARK: - Load Values
    
    func loadCurrentStep() -> Int {
        return defaults.integer(forKey: Keys.onboardingStep)
    }
    
    func loadUserName() -> String {
        return defaults.string(forKey: Keys.userName) ?? ""
    }
    
    func loadSelectedGoals() -> Set<String> {
        let array = defaults.stringArray(forKey: Keys.selectedGoals) ?? []
        return Set(array)
    }
    
    func loadCurrentUsageHours() -> Double {
        let hours = defaults.double(forKey: Keys.currentUsageHours)
        return hours > 0 ? hours : 4.0
    }
    
    func loadTargetUsageHours() -> Double {
        let hours = defaults.double(forKey: Keys.targetUsageHours)
        return hours > 0 ? hours : 2.0
    }
    
    func loadSelectedApps() -> Set<String> {
        let array = defaults.stringArray(forKey: Keys.selectedApps) ?? []
        return Set(array)
    }
    
    func loadSelectedReasons() -> Set<String> {
        let array = defaults.stringArray(forKey: Keys.selectedReasons) ?? []
        return Set(array)
    }
    
    func loadSelectedFeelings() -> Set<String> {
        let array = defaults.stringArray(forKey: Keys.selectedFeelings) ?? []
        return Set(array)
    }
    
    func loadSelectedAge() -> String {
        return defaults.string(forKey: Keys.selectedAge) ?? ""
    }
    
    func loadSelectedPreviousSolutions() -> Set<String> {
        let array = defaults.stringArray(forKey: Keys.selectedPreviousSolutions) ?? []
        return Set(array)
    }
    
    func loadSelectedExercise() -> String {
        return defaults.string(forKey: Keys.selectedExercise) ?? ""
    }
    
    func loadExerciseFrequency() -> String {
        return defaults.string(forKey: Keys.exerciseFrequency) ?? ""
    }
    
    func loadNotificationsDenied() -> Bool {
        return defaults.bool(forKey: Keys.notificationsDenied)
    }
    
    func loadOnboardingRepsCompleted() -> Int {
        return defaults.integer(forKey: Keys.onboardingRepsCompleted)
    }
    
    func hasCompletedOnboarding() -> Bool {
        return defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }
    
    // MARK: - Load All Data
    
    func loadAllOnboardingData() -> OnboardingData {
        var data = OnboardingData()
        data.currentStep = loadCurrentStep()
        data.userName = loadUserName()
        data.selectedGoals = Array(loadSelectedGoals())
        data.currentUsageHours = loadCurrentUsageHours()
        data.targetUsageHours = loadTargetUsageHours()
        data.selectedApps = Array(loadSelectedApps())
        data.selectedReasons = Array(loadSelectedReasons())
        data.selectedFeelings = Array(loadSelectedFeelings())
        data.selectedAge = loadSelectedAge()
        data.selectedPreviousSolutions = Array(loadSelectedPreviousSolutions())
        data.selectedExercise = loadSelectedExercise()
        data.exerciseFrequency = loadExerciseFrequency()
        data.notificationsDenied = loadNotificationsDenied()
        data.onboardingRepsCompleted = loadOnboardingRepsCompleted()
        return data
    }
    
    // MARK: - Clear Data
    
    func clearOnboardingData() {
        defaults.removeObject(forKey: Keys.onboardingStep)
        defaults.removeObject(forKey: Keys.userName)
        defaults.removeObject(forKey: Keys.selectedGoals)
        defaults.removeObject(forKey: Keys.currentUsageHours)
        defaults.removeObject(forKey: Keys.targetUsageHours)
        defaults.removeObject(forKey: Keys.selectedApps)
        defaults.removeObject(forKey: Keys.selectedReasons)
        defaults.removeObject(forKey: Keys.selectedFeelings)
        defaults.removeObject(forKey: Keys.selectedAge)
        defaults.removeObject(forKey: Keys.selectedPreviousSolutions)
        defaults.removeObject(forKey: Keys.selectedExercise)
        defaults.removeObject(forKey: Keys.exerciseFrequency)
        defaults.removeObject(forKey: Keys.notificationsDenied)
        defaults.removeObject(forKey: Keys.onboardingRepsCompleted)
        // Note: We don't clear hasCompletedOnboarding here
    }
    
    // MARK: - Firebase Sync
    
    private func syncToFirebaseIfNeeded(force: Bool = false) {
        // Safe access - skip if Firebase not configured
        guard FirebaseApp.app() != nil else { return }
        guard let userId = Auth.auth().currentUser?.uid else {
            // No user = no sync needed, this is fine
            return
        }
        
        // Debounce sync - only sync every 3 seconds max (unless forced)
        let lastSync = defaults.double(forKey: Keys.lastSyncTimestamp)
        let now = Date().timeIntervalSince1970
        guard force || (now - lastSync > 3.0) else { return }
        
        defaults.set(now, forKey: Keys.lastSyncTimestamp)
        
        // Use DispatchQueue for true background execution
        // Task.detached still has some coordination overhead
        DispatchQueue.global(qos: .utility).async { [self] in
            Task {
                await syncToFirebase(userId: userId)
            }
        }
    }
    
    /// Syncs onboarding data to Firebase - runs off main thread to avoid blocking UI
    func syncToFirebase(userId: String) async {
        // Read data on current thread (UserDefaults is thread-safe for reads)
        let data = loadAllOnboardingData()
        let completed = hasCompletedOnboarding()
        
        let documentData: [String: Any] = [
            "currentStep": data.currentStep,
            "userName": data.userName,
            "selectedGoals": data.selectedGoals,
            "currentUsageHours": data.currentUsageHours,
            "targetUsageHours": data.targetUsageHours,
            "selectedApps": data.selectedApps,
            "selectedReasons": data.selectedReasons,
            "selectedFeelings": data.selectedFeelings,
            "selectedAge": data.selectedAge,
            "selectedPreviousSolutions": data.selectedPreviousSolutions,
            "selectedExercise": data.selectedExercise,
            "exerciseFrequency": data.exerciseFrequency,
            "notificationsDenied": data.notificationsDenied,
            "onboardingRepsCompleted": data.onboardingRepsCompleted,
            "hasCompletedOnboarding": completed,
            "lastUpdated": FieldValue.serverTimestamp()
        ]
        
        do {
            try await db.collection("users").document(userId).setData(documentData, merge: true)
            print("[OnboardingData] Synced to Firebase successfully")
        } catch {
            print("[OnboardingData] Firebase sync error: \(error.localizedDescription)")
        }
    }
    
    /// Restores onboarding data from Firebase - can run off main thread
    func restoreFromFirebase(userId: String) async -> Bool {
        do {
            let document = try await db.collection("users").document(userId).getDocument()
            
            guard let data = document.data() else {
                print("[OnboardingData] No data found in Firebase")
                return false
            }
            
            // Restore to UserDefaults (thread-safe for writes)
            if let step = data["currentStep"] as? Int {
                defaults.set(step, forKey: Keys.onboardingStep)
            }
            if let name = data["userName"] as? String {
                defaults.set(name, forKey: Keys.userName)
            }
            if let goals = data["selectedGoals"] as? [String] {
                defaults.set(goals, forKey: Keys.selectedGoals)
            }
            if let hours = data["currentUsageHours"] as? Double {
                defaults.set(hours, forKey: Keys.currentUsageHours)
            }
            if let hours = data["targetUsageHours"] as? Double {
                defaults.set(hours, forKey: Keys.targetUsageHours)
            }
            if let apps = data["selectedApps"] as? [String] {
                defaults.set(apps, forKey: Keys.selectedApps)
            }
            if let reasons = data["selectedReasons"] as? [String] {
                defaults.set(reasons, forKey: Keys.selectedReasons)
            }
            if let feelings = data["selectedFeelings"] as? [String] {
                defaults.set(feelings, forKey: Keys.selectedFeelings)
            }
            if let age = data["selectedAge"] as? String {
                defaults.set(age, forKey: Keys.selectedAge)
            }
            if let solutions = data["selectedPreviousSolutions"] as? [String] {
                defaults.set(solutions, forKey: Keys.selectedPreviousSolutions)
            }
            if let exercise = data["selectedExercise"] as? String {
                defaults.set(exercise, forKey: Keys.selectedExercise)
            }
            if let frequency = data["exerciseFrequency"] as? String {
                defaults.set(frequency, forKey: Keys.exerciseFrequency)
            }
            if let denied = data["notificationsDenied"] as? Bool {
                defaults.set(denied, forKey: Keys.notificationsDenied)
            }
            if let reps = data["onboardingRepsCompleted"] as? Int {
                defaults.set(reps, forKey: Keys.onboardingRepsCompleted)
            }
            if let completed = data["hasCompletedOnboarding"] as? Bool {
                defaults.set(completed, forKey: Keys.hasCompletedOnboarding)
            }
            
            print("[OnboardingData] Restored from Firebase successfully")
            return true
        } catch {
            print("[OnboardingData] Firebase restore error: \(error.localizedDescription)")
            return false
        }
    }
}


