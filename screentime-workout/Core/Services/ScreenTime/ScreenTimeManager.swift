//
//  ScreenTimeManager.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftData
import Combine
import UIKit

/// Manages Screen Time features including app selection, time limits, and shielding
@Observable
final class ScreenTimeManager {
    // MARK: - Properties
    
    static let shared = ScreenTimeManager()
    
    private(set) var isAuthorized = false
    private(set) var authorizationError: Error?
    
    /// The user's selected apps/categories (for the picker UI)
    var selectedApps = FamilyActivitySelection() {
        didSet {
            saveSelection()
        }
    }
    
    /// Store for managing app shields
    private let store = ManagedSettingsStore()
    
    /// Center for scheduling device activity monitoring
    private let activityCenter = DeviceActivityCenter()
    
    /// Number of selected apps/categories
    var selectedAppCount: Int {
        selectedApps.applicationTokens.count + selectedApps.categoryTokens.count
    }
    
    /// Whether shields are currently active on any apps
    private(set) var shieldsActive = false
    
    /// Apps that have exceeded their limit and are currently blocked
    private(set) var blockedApps: Set<ApplicationToken> = []
    private(set) var blockedCategories: Set<ActivityCategoryToken> = []
    
    // MARK: - Persistence Keys
    
    private let selectionKey = "screentime.selectedApps"
    private let authCacheKey = "screentime.wasAuthorized"
    private let sharedBonusKey = "screentime.sharedBonusMinutes"
    
    /// Shared UserDefaults for communication with the DeviceActivityMonitor extension
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.app.screentime-workout")
    }
    
    // MARK: - Shared Bonus Pool
    
    /// Global bonus minutes that apply to ALL limits (shared pool)
    /// When any limit threshold is reached, this resets to 0
    var sharedBonusMinutes: Int {
        get { sharedDefaults?.integer(forKey: sharedBonusKey) ?? 0 }
        set {
            sharedDefaults?.set(newValue, forKey: sharedBonusKey)
            sharedDefaults?.synchronize()
            print("[ScreenTime] Shared bonus pool updated: \(newValue) minutes")
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // First check cached value for immediate UI
        let cachedAuth = UserDefaults.standard.bool(forKey: authCacheKey)
        isAuthorized = cachedAuth
        print("[ScreenTime] Init - cached authorization: \(cachedAuth)")
        
        // Then verify actual authorization status
        checkAuthorization()
        loadSelection()
        
        // Observe app becoming active to recheck authorization
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAuthorization()
        }
        
        // Immediately verify App Group access so we can surface sandbox issues loudly
        verifyAppGroupAccess()
#if DEBUG
        logExtensionBundleStatus()
#endif
    }

    /// Attempts to read/write inside the shared App Group so we can detect sandbox issues.
    /// If this fails, the DeviceActivity extension will never be able to run.
    private func verifyAppGroupAccess() {
        let groupId = "group.app.screentime-workout"
        let fm = FileManager.default
        
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            print("[ScreenTime][AppGroup] ❌ containerURL() returned nil for \(groupId). Check Signing & Capabilities.")
            return
        }
        
        let libraryURL = containerURL.appendingPathComponent("Library", isDirectory: true)
        let appSupportURL = libraryURL.appendingPathComponent("Application Support", isDirectory: true)
        let testFileURL = appSupportURL.appendingPathComponent("app_group_probe.txt")
        
        do {
            try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            let payload = "App Group probe at \(Date())".data(using: .utf8) ?? Data()
            try payload.write(to: testFileURL, options: .atomic)
            print("[ScreenTime][AppGroup] ✅ Able to write to shared container at \(appSupportURL.path)")
        } catch {
            print("[ScreenTime][AppGroup] ❌ Failed to access shared container: \(error.localizedDescription)")
            print("[ScreenTime][AppGroup]    Path: \(appSupportURL.path)")
            print("[ScreenTime][AppGroup]    This must succeed for the extension to run.")
        }
    }
    
    // MARK: - Authorization
    
    @MainActor
    func requestAuthorization() async throws {
        print("[ScreenTime] Requesting authorization...")
        
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
            authorizationError = nil
            
            // Cache the result
            UserDefaults.standard.set(isAuthorized, forKey: authCacheKey)
            
            print("[ScreenTime] Authorization granted: \(isAuthorized)")
        } catch {
            authorizationError = error
            isAuthorized = false
            UserDefaults.standard.set(false, forKey: authCacheKey)
            print("[ScreenTime] Authorization failed: \(error)")
            throw error
        }
    }
    
    func checkAuthorization() {
        let actualStatus = AuthorizationCenter.shared.authorizationStatus
        let newIsAuthorized = (actualStatus == .approved)
        
        print("[ScreenTime] Checking authorization - status: \(actualStatus), approved: \(newIsAuthorized)")
        
        // Only update if different from cached value - ensure main thread
        if isAuthorized != newIsAuthorized {
            if Thread.isMainThread {
                isAuthorized = newIsAuthorized
                UserDefaults.standard.set(isAuthorized, forKey: authCacheKey)
                print("[ScreenTime] Authorization updated: \(isAuthorized)")
            } else {
                DispatchQueue.main.async { [self] in
                    isAuthorized = newIsAuthorized
                    UserDefaults.standard.set(isAuthorized, forKey: authCacheKey)
                    print("[ScreenTime] Authorization updated: \(isAuthorized)")
                }
            }
        }
    }
    
    // MARK: - Limit Token Validation
    
    /// Check if a limit has valid app/category tokens saved locally
    /// Returns true if the limit has at least one app or category token
    func limitHasValidTokens(limitId: UUID) -> Bool {
        let selectionKey = "limit_selection_\(limitId.uuidString)"
        guard let selectionData = UserDefaults.standard.data(forKey: selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: selectionData) else {
            return false
        }
        return !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty
    }
    
    /// Get all limit IDs that have valid tokens
    func getLimitIdsWithValidTokens(limits: [AppTimeLimit]) -> [UUID] {
        return limits.filter { limitHasValidTokens(limitId: $0.id) }.map { $0.id }
    }
    
    /// Clean up orphaned limits (limits without valid tokens)
    /// Returns the IDs of limits that were identified as orphaned
    func getOrphanedLimitIds(limits: [AppTimeLimit]) -> [UUID] {
        return limits.filter { !limitHasValidTokens(limitId: $0.id) }.map { $0.id }
    }
    
    // MARK: - Time Limit Monitoring
    
    /// Start monitoring usage for all active time limits
    /// This sets up DeviceActivity to track usage and notify when limits are reached
    func startMonitoring(limits: [AppTimeLimit], context: ModelContext) {
        print("[ScreenTime] ========== START MONITORING ==========")
        print("[ScreenTime] Total limits passed: \(limits.count)")
        print("[ScreenTime] Active limits: \(limits.filter { $0.isActive }.count)")
        print("[ScreenTime] Current bonus pool: \(sharedBonusMinutes) min")
        
        // 🚨 CRITICAL: If bonus is active, we rely on the 'Bonus_...' activity!
        // We MUST NOT start .dailyUsage monitoring, because it tracks cumulative daily usage.
        // If we start it now, it will see (Usage > Limit) and immediately block, defeating the bonus.
        if sharedBonusMinutes > 0 {
            print("[ScreenTime] ⚡️ Bonus active - skipping daily monitoring to allow 'Pushscroll' bonus logic")
            print("[ScreenTime] ℹ️ The unique Bonus activity is handling enforcement now.")
            return
        }
        
        guard isAuthorized else {
            print("[ScreenTime] ❌ Cannot start monitoring - not authorized")
            return
        }
        print("[ScreenTime] ✅ Authorization confirmed")
        
        // Stop any existing monitoring
        print("[ScreenTime] Stopping any existing monitoring...")
        activityCenter.stopMonitoring()
        print("[ScreenTime] ✅ Existing monitoring stopped")
        
        // IMPORTANT: Clear all existing shields before reapplying
        // ManagedSettingsStore persists shields across app launches, so we need to reset
        removeAllShields()
        print("[ScreenTime] ✅ Cleared existing shields before applying new limits")
        
        // Always use full day schedule (midnight to midnight)
        // The threshold (minutes of usage) determines when blocking happens
        // DeviceActivity tracks cumulative usage within the schedule window
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
        print("[ScreenTime] 📅 Schedule: 00:00:00 to 23:59:59, repeats: true")
        print("[ScreenTime] 📅 Bonus pool: \(sharedBonusMinutes) min (added to all thresholds)")
#if DEBUG
        dumpMonitorLogs(reason: "Before scheduling dailyUsage")
#endif
        
        // Create events for each time limit
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        var scheduledLimitsCount = 0
        var dailyLimitsCount = 0
        
        for limit in limits where limit.isActive {
            let eventNameString = "limit_\(limit.id.uuidString)"
            print("[ScreenTime] --- Processing limit: '\(limit.displayName)' ---")
            print("[ScreenTime]   ID: \(limit.id.uuidString)")
            print("[ScreenTime]   Type: \(limit.limitType)")
            print("[ScreenTime]   Base minutes: \(limit.dailyLimitMinutes)")
            print("[ScreenTime]   Event name: \(eventNameString)")
            
            // Try to load the full saved selection (may contain multiple apps/categories)
            var appTokens: Set<ApplicationToken> = []
            var categoryTokens: Set<ActivityCategoryToken> = []
            
            let selectionKey = "limit_selection_\(limit.id.uuidString)"
            if let selectionData = UserDefaults.standard.data(forKey: selectionKey),
               let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: selectionData) {
                // Use the full saved selection
                appTokens = selection.applicationTokens
                categoryTokens = selection.categoryTokens
                print("[ScreenTime]   ✅ Loaded selection from UserDefaults (key: \(selectionKey))")
                print("[ScreenTime]   App tokens: \(appTokens.count), Category tokens: \(categoryTokens.count)")
            } else {
                print("[ScreenTime]   ⚠️ No saved selection found, trying model fallback...")
                // Fall back to single token stored in the model
                if let appToken = limit.getApplicationToken() {
                    appTokens = [appToken]
                    print("[ScreenTime]   Got app token from model")
                }
                if let categoryToken = limit.getCategoryToken() {
                    categoryTokens = [categoryToken]
                    print("[ScreenTime]   Got category token from model")
                }
            }
            
            guard !appTokens.isEmpty || !categoryTokens.isEmpty else {
                print("[ScreenTime]   ❌ SKIPPING - No tokens found for this limit!")
                continue
            }
            
                // Save tokens for extension reference
                saveTokensForExtension(
                    eventName: eventNameString,
                    appTokens: appTokens.isEmpty ? nil : Array(appTokens),
                    categoryTokens: categoryTokens.isEmpty ? nil : Array(categoryTokens)
                )
            
            // Handle based on limit type
            switch limit.limitType {
            case .scheduled:
                // For scheduled limits, apply/remove shields based on current time
                handleScheduledLimit(limit, appTokens: appTokens, categoryTokens: categoryTokens)
                scheduledLimitsCount += 1
                
            case .dailyLimit:
                let eventName = DeviceActivityEvent.Name(eventNameString)
                print("[ScreenTime]   Creating daily limit event...")
                
                // Calculate threshold: base limit + shared bonus pool
                let effectiveLimit = limit.dailyLimitMinutes + sharedBonusMinutes
                print("[ScreenTime]   Effective limit: \(effectiveLimit) min (base: \(limit.dailyLimitMinutes) + bonus: \(sharedBonusMinutes))")
                
                // If limit is 0 minutes, immediately block the apps
                if effectiveLimit == 0 {
                    print("[ScreenTime]   ⚡ Effective limit is 0 - applying IMMEDIATE shield")
                    if !appTokens.isEmpty {
                        shieldApps(appTokens)
                        print("[ScreenTime]   Immediately blocked \(appTokens.count) apps for '\(limit.displayName)' (0 min limit)")
                    }
                    if !categoryTokens.isEmpty {
                        shieldCategories(categoryTokens)
                        print("[ScreenTime]   Immediately blocked \(categoryTokens.count) categories for '\(limit.displayName)' (0 min limit)")
                    }
                continue // Skip adding to monitoring events
            }
            
                let threshold = DateComponents(minute: effectiveLimit)
                print("[ScreenTime]   Threshold DateComponents: minute=\(effectiveLimit)")
            
            // Create the event with all tokens
            if !appTokens.isEmpty && !categoryTokens.isEmpty {
                events[eventName] = DeviceActivityEvent(
                    applications: appTokens,
                    categories: categoryTokens,
                    threshold: threshold
                )
                    print("[ScreenTime]   ✅ Created event with \(appTokens.count) apps + \(categoryTokens.count) categories")
            } else if !appTokens.isEmpty {
                events[eventName] = DeviceActivityEvent(
                    applications: appTokens,
                    threshold: threshold
                )
                    print("[ScreenTime]   ✅ Created event with \(appTokens.count) apps only")
            } else if !categoryTokens.isEmpty {
                events[eventName] = DeviceActivityEvent(
                    categories: categoryTokens,
                    threshold: threshold
                )
                    print("[ScreenTime]   ✅ Created event with \(categoryTokens.count) categories only")
                }
                
                dailyLimitsCount += 1
                print("[ScreenTime]   📊 Event '\(eventNameString)' ready for monitoring")
            }
        }
        
        // Start daily limit monitoring if we have any
        print("[ScreenTime] ========== STARTING DEVICE ACTIVITY ==========")
        print("[ScreenTime] Total events to monitor: \(events.count)")
        for (eventName, event) in events {
            print("[ScreenTime]   Event: \(eventName.rawValue)")
            print("[ScreenTime]     Threshold: \(event.threshold)")
        }
        
        if !events.isEmpty {
            do {
                print("[ScreenTime] 🚀 Calling activityCenter.startMonitoring(.dailyUsage, ...)")
            try activityCenter.startMonitoring(
                .dailyUsage,
                during: schedule,
                events: events
            )
                print("[ScreenTime] ✅ activityCenter.startMonitoring() succeeded!")
                print("[ScreenTime] Activity name: 'dailyUsage'")
#if DEBUG
                dumpMonitorLogs(reason: "After starting dailyUsage monitoring")
#endif
        } catch {
                print("[ScreenTime] ❌ FAILED to start monitoring!")
                print("[ScreenTime] Error: \(error)")
                print("[ScreenTime] Error description: \(error.localizedDescription)")
            }
        } else {
            print("[ScreenTime] ⚠️ No events to monitor - skipping activityCenter.startMonitoring()")
        }
        
        print("[ScreenTime] ========== MONITORING SETUP COMPLETE ==========")
        print("[ScreenTime] Daily limits: \(dailyLimitsCount), Scheduled limits: \(scheduledLimitsCount)")
    }
    
    /// Handle a scheduled limit - apply or remove shields based on current time
    private func handleScheduledLimit(_ limit: AppTimeLimit, appTokens: Set<ApplicationToken>, categoryTokens: Set<ActivityCategoryToken>) {
        if limit.isWithinScheduledTime {
            // Within scheduled blocking time - apply shields
            if !appTokens.isEmpty {
                shieldApps(appTokens)
            }
            if !categoryTokens.isEmpty {
                shieldCategories(categoryTokens)
            }
            print("[ScreenTime] Scheduled block active for '\(limit.displayName)' (\(limit.scheduleTimeString))")
        } else {
            // Outside scheduled time - remove shields for this limit
            for token in appTokens {
                unshieldApp(token)
            }
            for token in categoryTokens {
                unshieldCategory(token)
            }
            print("[ScreenTime] Scheduled block inactive for '\(limit.displayName)' (next: \(limit.scheduleTimeString))")
        }
    }
    
    /// Stop all usage monitoring
    func stopMonitoring() {
        activityCenter.stopMonitoring()
        print("[ScreenTime] Stopped all monitoring")
    }
    
    // MARK: - Shield Management
    
    /// Apply shields to specific apps (blocks them)
    func shieldApps(_ tokens: Set<ApplicationToken>) {
        guard isAuthorized else { return }
        
        blockedApps.formUnion(tokens)
        store.shield.applications = blockedApps.isEmpty ? nil : blockedApps
        shieldsActive = !blockedApps.isEmpty || !blockedCategories.isEmpty
        
        print("[ScreenTime] Shielded \(tokens.count) apps, total blocked: \(blockedApps.count)")
    }
    
    /// Apply shields to specific categories
    func shieldCategories(_ tokens: Set<ActivityCategoryToken>) {
        guard isAuthorized else { return }
        
        blockedCategories.formUnion(tokens)
        if blockedCategories.isEmpty {
            store.shield.applicationCategories = nil
        } else {
            store.shield.applicationCategories = .specific(blockedCategories)
        }
        shieldsActive = !blockedApps.isEmpty || !blockedCategories.isEmpty
        
        print("[ScreenTime] Shielded \(tokens.count) categories, total blocked: \(blockedCategories.count)")
    }
    
    /// Remove shield from specific app (called when user earns time)
    func unshieldApp(_ token: ApplicationToken) {
        blockedApps.remove(token)
        store.shield.applications = blockedApps.isEmpty ? nil : blockedApps
        shieldsActive = !blockedApps.isEmpty || !blockedCategories.isEmpty
        
        print("[ScreenTime] Unshielded app, remaining blocked: \(blockedApps.count)")
    }
    
    /// Remove shield from specific category
    func unshieldCategory(_ token: ActivityCategoryToken) {
        blockedCategories.remove(token)
        if blockedCategories.isEmpty {
            store.shield.applicationCategories = nil
        } else {
            store.shield.applicationCategories = .specific(blockedCategories)
        }
        shieldsActive = !blockedApps.isEmpty || !blockedCategories.isEmpty
        
        print("[ScreenTime] Unshielded category, remaining blocked: \(blockedCategories.count)")
    }
    
    /// Remove ALL shields
    func removeAllShields() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        blockedApps.removeAll()
        blockedCategories.removeAll()
        shieldsActive = false
        
        print("[ScreenTime] All shields removed")
    }
    
    // MARK: - Bonus Time Management (Shared Pool)
    
    /// When bonus time should expire (time-based fallback since DeviceActivity can be unreliable)
    var bonusExpiryDate: Date? {
        get { sharedDefaults?.object(forKey: "screentime.bonusExpiryDate") as? Date }
        set { 
            sharedDefaults?.set(newValue, forKey: "screentime.bonusExpiryDate")
            sharedDefaults?.synchronize()
        }
    }
    
    /// The current bonus activity name (with UUID for fresh usage tracking)
    private var currentBonusActivityName: String? {
        get { sharedDefaults?.string(forKey: "screentime.currentBonusActivityName") }
        set {
            sharedDefaults?.set(newValue, forKey: "screentime.currentBonusActivityName")
            sharedDefaults?.synchronize()
        }
    }
    
    /// Add bonus time to the shared pool
    /// THE KEY TRICK: Use a 15-minute WINDOW with an N-minute THRESHOLD inside
    /// Usage is counted from when THIS specific activity started (not cumulative daily)
    func addBonusToPool(minutes: Int, limits: [AppTimeLimit], context: ModelContext) {
        print("[ScreenTime] ========== ADDING BONUS TO POOL ==========")
        print("[ScreenTime] Minutes to add: \(minutes)")
        print("[ScreenTime] Current bonus: \(sharedBonusMinutes)")
        
        // Add to the shared bonus pool
        sharedBonusMinutes += minutes
        print("[ScreenTime] New bonus total: \(sharedBonusMinutes)")
        
        // Calculate exact expiry time (for fallback)
        let now = Date()
        let expiryDate = now.addingTimeInterval(TimeInterval(sharedBonusMinutes * 60))
        bonusExpiryDate = expiryDate
        print("[ScreenTime] ⏰ Bonus expires at: \(expiryDate)")
        
        // Save all current blocked tokens for the extension to re-apply later
        saveAllBlockedTokensForExtension(limits: limits)
        
        // ========== THE 20-ACTIVITY LIMIT FIX ==========
        // iOS has a hard limit of 20 active monitors. Ghost monitors from crashes
        // can fill this up. Clear EVERYTHING first.
        let currentActivities = activityCenter.activities
        print("[ScreenTime] 📊 Currently monitored activities: \(currentActivities.count)")
        for activity in currentActivities {
            print("[ScreenTime]   - \(activity.rawValue)")
        }
        
        // NUCLEAR OPTION: Stop ALL monitoring to clear the deck
        if currentActivities.count > 5 {
            print("[ScreenTime] ⚠️ Too many activities! Clearing ALL to avoid 20-limit")
            activityCenter.stopMonitoring()
            print("[ScreenTime] 🧹 Cleared ALL activities")
        } else {
            // Just clean up bonus activities
            let bonusActivities = currentActivities.filter { $0.rawValue.hasPrefix("Bonus_") }
            if !bonusActivities.isEmpty {
                activityCenter.stopMonitoring(bonusActivities)
                print("[ScreenTime] 🧹 Cleaned up \(bonusActivities.count) old bonus activities")
            }
            
            if let existingName = currentBonusActivityName {
                activityCenter.stopMonitoring([DeviceActivityName(existingName)])
                print("[ScreenTime] Stopped previous bonus activity: \(existingName)")
            }
            activityCenter.stopMonitoring([.bonusSession])
            
            // CRITICAL: Stop daily usage monitoring to prevent conflict!
            // If we leave it running, it will see (Usage > 0) and block immediately.
            activityCenter.stopMonitoring([.dailyUsage])
            print("[ScreenTime] 🛑 Stopped .dailyUsage monitoring to allow bonus session")
        }
        
        // Remove shields (UNLOCK NOW)
        print("[ScreenTime] Removing current shields (UNLOCKING APPS)...")
        removeAllShields()
        
        // ========== THE PUSHSCROLL TRICK ==========
        // 1. Create a 15-minute WINDOW (minimum Apple allows)
        // 2. Put an N-minute THRESHOLD inside that window
        // 3. Use a UNIQUE activity name to force fresh usage count
        // 4. eventDidReachThreshold fires after N minutes of USAGE (not wall-clock time)
        
        let calendar = Calendar.current
        let windowMinutes = max(15, sharedBonusMinutes + 5) // Ensure window is longer than threshold
        let windowEnd = now.addingTimeInterval(TimeInterval(windowMinutes * 60))
        
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComponents = calendar.dateComponents([.hour, .minute, .second], from: windowEnd)
        
        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
        
        // Create the ACTUAL limit as a threshold within the window
        // This fires after N minutes of USAGE within this specific window
        let threshold = DateComponents(minute: sharedBonusMinutes)
        
        // Collect all tokens to monitor
        // NOTE: Selections are stored in UserDefaults.standard, not sharedDefaults
        var allAppTokens = Set<ApplicationToken>()
        var allCategoryTokens = Set<ActivityCategoryToken>()
        
        for limit in limits where limit.isActive {
            let selectionKey = "limit_selection_\(limit.id.uuidString)"
            if let data = UserDefaults.standard.data(forKey: selectionKey),
               let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
                allAppTokens.formUnion(selection.applicationTokens)
                allCategoryTokens.formUnion(selection.categoryTokens)
                print("[ScreenTime]   Found tokens for '\(limit.displayName)': \(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories")
            }
        }
        
        print("[ScreenTime] 📅 PUSHSCROLL TRICK:")
        print("[ScreenTime]   Window: \(windowMinutes) minutes (satisfies Apple's minimum)")
        print("[ScreenTime]   Threshold: \(sharedBonusMinutes) minutes of USAGE")
        print("[ScreenTime]   Apps to monitor: \(allAppTokens.count)")
        print("[ScreenTime]   Categories to monitor: \(allCategoryTokens.count)")
        
        // Create the event with the threshold
        let event: DeviceActivityEvent
        if !allAppTokens.isEmpty && !allCategoryTokens.isEmpty {
            event = DeviceActivityEvent(
                applications: allAppTokens,
                categories: allCategoryTokens,
                threshold: threshold
            )
        } else if !allAppTokens.isEmpty {
            event = DeviceActivityEvent(
                applications: allAppTokens,
                threshold: threshold
            )
        } else if !allCategoryTokens.isEmpty {
            event = DeviceActivityEvent(
                categories: allCategoryTokens,
                threshold: threshold
            )
        } else {
            print("[ScreenTime] ❌ No apps or categories to monitor!")
            print("[ScreenTime] ========== BONUS ADDED (fallback only) ==========")
            return
        }
        
        // Use a UNIQUE name to force fresh usage count
        let uniqueActivityName = DeviceActivityName.bonusActivity()
        currentBonusActivityName = uniqueActivityName.rawValue
        
        print("[ScreenTime]   Activity name: \(uniqueActivityName.rawValue)")
        print("[ScreenTime]   Schedule: \(startComponents.hour ?? 0):\(startComponents.minute ?? 0):\(startComponents.second ?? 0) → \(endComponents.hour ?? 0):\(endComponents.minute ?? 0):\(endComponents.second ?? 0)")
        
        do {
            try activityCenter.startMonitoring(
                uniqueActivityName,
                during: schedule,
                events: [.bonusReached: event]
            )
            print("[ScreenTime] ✅ Bonus monitoring started!")
            print("[ScreenTime] 🎯 eventDidReachThreshold will fire after \(sharedBonusMinutes) min of USAGE")
            print("[ScreenTime] ℹ️ Usage is fresh (starts at 0) because activity name is unique")
#if DEBUG
            dumpMonitorLogs(reason: "After starting bonus monitoring")
#endif
        } catch {
            print("[ScreenTime] ❌ Failed to start bonus monitoring: \(error)")
            print("[ScreenTime] Will use fallback: checkBonusExpiry when app returns")
        }
        
        print("[ScreenTime] ========== BONUS ADDED SUCCESSFULLY ==========")
    }
    
    /// Save all blocked tokens to UserDefaults so the extension can re-apply them
    private func saveAllBlockedTokensForExtension(limits: [AppTimeLimit]) {
        guard let defaults = sharedDefaults else {
            print("[ScreenTime] ❌ sharedDefaults unavailable for saving blocked tokens")
            return
        }
        
        var allAppTokens = Set<ApplicationToken>()
        var allCategoryTokens = Set<ActivityCategoryToken>()
        
        // NOTE: Selections are stored in UserDefaults.standard, not sharedDefaults
        for limit in limits where limit.isActive {
            let selectionKey = "limit_selection_\(limit.id.uuidString)"
            if let data = UserDefaults.standard.data(forKey: selectionKey),
               let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
                allAppTokens.formUnion(selection.applicationTokens)
                allCategoryTokens.formUnion(selection.categoryTokens)
            }
        }
        
        // Save combined tokens for the extension to use when bonus expires
        if let appData = try? PropertyListEncoder().encode(allAppTokens) {
            defaults.set(appData, forKey: "bonusSession_blockedApps")
        }
        if let catData = try? PropertyListEncoder().encode(allCategoryTokens) {
            defaults.set(catData, forKey: "bonusSession_blockedCategories")
        }
        defaults.synchronize()
        
        print("[ScreenTime] 💾 Saved \(allAppTokens.count) apps + \(allCategoryTokens.count) categories for extension to re-block")
    }
    
    /// Called when any limit threshold is reached - collapses all bonuses
    /// This should be called by the main app when notified by the extension
    func collapseBonusPool(limits: [AppTimeLimit], context: ModelContext) {
        guard sharedBonusMinutes > 0 else { return }
        
        print("[ScreenTime] Collapsing bonus pool (was \(sharedBonusMinutes) min) - a threshold was reached")
        
        // Reset the shared bonus to 0
        sharedBonusMinutes = 0
        
        // Restart monitoring with base thresholds only
        startMonitoring(limits: limits, context: context)
    }
    
    /// Check if bonus time has expired (time-based fallback)
    /// Call this when app becomes active to enforce time limits
    func checkBonusExpiry(limits: [AppTimeLimit], context: ModelContext) {
        print("[ScreenTime] 🔍 checkBonusExpiry called")
        print("[ScreenTime]   Current bonus: \(sharedBonusMinutes) min")
        print("[ScreenTime]   Expiry date: \(bonusExpiryDate?.description ?? "nil")")
        print("[ScreenTime]   Current time: \(Date())")
        
        guard sharedBonusMinutes > 0 else {
            print("[ScreenTime]   ⏭️ Skipping - no bonus to check")
            return
        }
        
        if let expiry = bonusExpiryDate {
            let isExpired = Date() >= expiry
            print("[ScreenTime]   Is expired? \(isExpired) (now >= expiry)")
            
            if isExpired {
                print("[ScreenTime] ⏰ Bonus time has expired! Collapsing pool and applying shields.")
                
                // Reset bonus
                sharedBonusMinutes = 0
                bonusExpiryDate = nil
                
                // Re-apply shields for any limits with 0 base time
                for limit in limits where limit.isActive && limit.dailyLimitMinutes == 0 {
                    if let selectionData = UserDefaults.standard.data(forKey: "limit_selection_\(limit.id.uuidString)"),
                       let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: selectionData) {
                        if !selection.applicationTokens.isEmpty {
                            shieldApps(selection.applicationTokens)
                        }
                        if !selection.categoryTokens.isEmpty {
                            shieldCategories(selection.categoryTokens)
                        }
                        print("[ScreenTime] Re-blocked '\(limit.displayName)' after bonus expired")
                    }
                }
                
                // Restart monitoring with base thresholds
                startMonitoring(limits: limits, context: context)
            } else {
                let remaining = expiry.timeIntervalSince(Date())
                print("[ScreenTime] ⏠️ Bonus time remaining: \(Int(remaining / 60)) min \(Int(remaining.truncatingRemainder(dividingBy: 60))) sec")
            }
        } else {
            print("[ScreenTime]   ⚠️ No expiry date set!")
        }
    }
    
    /// Check if bonus was consumed (called when app becomes active)
    /// Returns true if bonus was collapsed by the extension
    func checkBonusStatus() -> Bool {
        // The extension sets this flag when it collapses the bonus
        let wasCollapsed = sharedDefaults?.bool(forKey: "screentime.bonusWasCollapsed") ?? false
        if wasCollapsed {
            sharedDefaults?.set(false, forKey: "screentime.bonusWasCollapsed")
            sharedDefaults?.synchronize()
        }
        return wasCollapsed
    }
    
    // MARK: - Event Handling (Called from DeviceActivityMonitor extension)
    
    /// Called when a time limit threshold is reached
    /// Note: In production, this is called from the DeviceActivityMonitor extension
    func handleThresholdReached(eventName: String) {
        print("[ScreenTime] Threshold reached for event: \(eventName)")
        
        // The DeviceActivityMonitor extension will handle applying shields
        // This method is for logging/state updates in the main app
        NotificationCenter.default.post(
            name: .screenTimeLimitReached,
            object: nil,
            userInfo: ["eventName": eventName]
        )
    }
    
    // MARK: - Persistence
    
    /// Save tokens to shared UserDefaults so the DeviceActivityMonitor extension can read them
    /// This is called when setting up monitoring - the extension reads these when a threshold is reached
    private func saveTokensForExtension(eventName: String, appTokens: [ApplicationToken]?, categoryTokens: [ActivityCategoryToken]?) {
        print("[ScreenTime] 💾 Saving tokens for extension...")
        print("[ScreenTime]   Event name: \(eventName)")
        print("[ScreenTime]   App tokens to save: \(appTokens?.count ?? 0)")
        print("[ScreenTime]   Category tokens to save: \(categoryTokens?.count ?? 0)")
        
        guard let defaults = sharedDefaults else {
            print("[ScreenTime] ❌ CRITICAL: Shared UserDefaults not available!")
            print("[ScreenTime] App Group 'group.app.screentime-workout' may not be configured!")
            return
        }
        print("[ScreenTime]   ✅ Shared UserDefaults accessible")
        
        // Save app tokens
        if let appTokens = appTokens, !appTokens.isEmpty {
            do {
                let data = try PropertyListEncoder().encode(Set(appTokens))
                let key = "blockedTokens_\(eventName)"
                defaults.set(data, forKey: key)
                print("[ScreenTime]   ✅ Saved \(appTokens.count) app tokens (\(data.count) bytes) to key: \(key)")
            } catch {
                print("[ScreenTime]   ❌ Failed to save app tokens: \(error)")
            }
        } else {
            let key = "blockedTokens_\(eventName)"
            defaults.removeObject(forKey: key)
            print("[ScreenTime]   Removed app tokens (none to save)")
        }
        
        // Save category tokens
        if let categoryTokens = categoryTokens, !categoryTokens.isEmpty {
            do {
                let data = try PropertyListEncoder().encode(Set(categoryTokens))
                let key = "blockedCategories_\(eventName)"
                defaults.set(data, forKey: key)
                print("[ScreenTime]   ✅ Saved \(categoryTokens.count) category tokens (\(data.count) bytes) to key: \(key)")
            } catch {
                print("[ScreenTime]   ❌ Failed to save category tokens: \(error)")
            }
        } else {
            let key = "blockedCategories_\(eventName)"
            defaults.removeObject(forKey: key)
            print("[ScreenTime]   Removed category tokens (none to save)")
        }
        
        defaults.synchronize()
        print("[ScreenTime]   ✅ UserDefaults synchronized")
    }
    
    /// Clear all saved tokens from shared UserDefaults
    private func clearSavedTokens(for eventName: String) {
        sharedDefaults?.removeObject(forKey: "blockedTokens_\(eventName)")
        sharedDefaults?.removeObject(forKey: "blockedCategories_\(eventName)")
        sharedDefaults?.synchronize()
    }
    
    private func saveSelection() {
        do {
            let data = try PropertyListEncoder().encode(selectedApps)
            UserDefaults.standard.set(data, forKey: selectionKey)
        } catch {
            print("[ScreenTime] Failed to save selection: \(error)")
        }
    }
    
    private func loadSelection() {
        guard let data = UserDefaults.standard.data(forKey: selectionKey) else { return }
        
        do {
            selectedApps = try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
            print("[ScreenTime] Loaded selection: \(selectedAppCount) apps/categories")
        } catch {
            print("[ScreenTime] Failed to load selection: \(error)")
        }
    }
    
    // MARK: - Debug
    
    func debugPrintStatus() {
        print("""
        [ScreenTime] Status:
        - Authorized: \(isAuthorized)
        - Selected Apps: \(selectedApps.applicationTokens.count)
        - Selected Categories: \(selectedApps.categoryTokens.count)
        - Blocked Apps: \(blockedApps.count)
        - Blocked Categories: \(blockedCategories.count)
        - Shields Active: \(shieldsActive)
        """)
    }
}

#if DEBUG
// MARK: - Debug helpers
extension ScreenTimeManager {
    func runShieldSmokeTest(limits: [AppTimeLimit], context: ModelContext) {
        print("[ScreenTime][Debug] === Shield Smoke Test ===")
        guard isAuthorized else {
            print("[ScreenTime][Debug] ❌ Not authorized for FamilyControls")
            return
        }
        
        guard let (selection, limit) = debugSelection(from: limits) else {
            print("[ScreenTime][Debug] ❌ No active limits with saved tokens. Create a limit first.")
            return
        }
        
        let appTokens = selection.applicationTokens
        let categoryTokens = selection.categoryTokens
        
        guard !appTokens.isEmpty || !categoryTokens.isEmpty else {
            print("[ScreenTime][Debug] ❌ Selection for smoke test has zero tokens")
            return
        }
        
        // Apply immediate shield so user can see it instantly
        removeAllShields()
        if !appTokens.isEmpty {
            shieldApps(appTokens)
        }
        if !categoryTokens.isEmpty {
            shieldCategories(categoryTokens)
        }
        print("[ScreenTime][Debug] ✅ Applied immediate shields using limit '\(limit.displayName)'")
        
        // Save tokens and start a dedicated monitor with 1 minute threshold
        let eventName = DeviceActivityEvent.Name.debugSmokeTestReached
        saveTokensForExtension(
            eventName: eventName.rawValue,
            appTokens: appTokens.isEmpty ? nil : Array(appTokens),
            categoryTokens: categoryTokens.isEmpty ? nil : Array(categoryTokens)
        )
        startDebugDeviceActivity(
            eventName: eventName,
            appTokens: appTokens,
            categoryTokens: categoryTokens
        )
        
        print("[ScreenTime][Debug] ▶️ Monitor '\(DeviceActivityName.debugSmokeTest.rawValue)' armed. Spend ~1 minute in the selected app to see if the extension logs fire.")
        dumpMonitorLogs(reason: "After arming debug smoke test", maxLines: 20)
    }
    
    func logExtensionBundleStatus() {
        let bundlePath = Bundle.main.bundlePath
        let pluginsPath = (bundlePath as NSString).appendingPathComponent("PlugIns")
        let fm = FileManager.default
        
        if fm.fileExists(atPath: pluginsPath) {
            print("[ScreenTime][Bundle] PlugIns folder exists at: \(pluginsPath)")
            if let contents = try? fm.contentsOfDirectory(atPath: pluginsPath) {
                if contents.isEmpty {
                    print("[ScreenTime][Bundle] PlugIns folder is empty")
                } else {
                    print("[ScreenTime][Bundle] PlugIns contents:")
                    contents.forEach { print("[ScreenTime][Bundle]   - \($0)") }
                }
            } else {
                print("[ScreenTime][Bundle] ⚠️ Unable to list PlugIns folder contents")
            }
        } else {
            print("[ScreenTime][Bundle] ❌ PlugIns folder not found (expected DeviceActivityMonitorExtension.appex)")
        }
    }
    
    func dumpMonitorLogs(reason: String, maxLines: Int = 40) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.screentime-workout") else {
            print("[ScreenTime][MonitorLog] ❌ Cannot access App Group container to read logs")
            return
        }
        
        let logURL = containerURL.appendingPathComponent("monitor_log.txt")
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
            print("[ScreenTime][MonitorLog] ℹ️ No monitor_log.txt yet (reason: \(reason))")
            return
        }
        
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(maxLines)
        print("[ScreenTime][MonitorLog] --- \(reason) (showing \(tail.count) of \(lines.count) lines) ---")
        tail.forEach { print("[ScreenTime][MonitorLog] \($0)") }
        print("[ScreenTime][MonitorLog] --- end monitor log ---")
    }
    
    private func debugSelection(from limits: [AppTimeLimit]) -> (FamilyActivitySelection, AppTimeLimit)? {
        guard let limit = limits.first(where: { $0.isActive }) else { return nil }
        
        let selectionKey = "limit_selection_\(limit.id.uuidString)"
        if let data = UserDefaults.standard.data(forKey: selectionKey),
           let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            return (selection, limit)
        }
        
        var fallback = FamilyActivitySelection()
        if let appToken = limit.getApplicationToken() {
            fallback.applicationTokens.insert(appToken)
        }
        if let categoryToken = limit.getCategoryToken() {
            fallback.categoryTokens.insert(categoryToken)
        }
        
        if fallback.applicationTokens.isEmpty && fallback.categoryTokens.isEmpty {
            return nil
        }
        return (fallback, limit)
    }
    
    private func startDebugDeviceActivity(eventName: DeviceActivityEvent.Name,
                                          appTokens: Set<ApplicationToken>,
                                          categoryTokens: Set<ActivityCategoryToken>) {
        let now = Date()
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComponents = calendar.dateComponents([.hour, .minute, .second], from: now.addingTimeInterval(15 * 60))
        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
        let threshold = DateComponents(minute: 1)
        
        var event: DeviceActivityEvent
        if !appTokens.isEmpty && !categoryTokens.isEmpty {
            event = DeviceActivityEvent(applications: appTokens, categories: categoryTokens, threshold: threshold)
        } else if !appTokens.isEmpty {
            event = DeviceActivityEvent(applications: appTokens, threshold: threshold)
        } else {
            event = DeviceActivityEvent(categories: categoryTokens, threshold: threshold)
        }
        
        activityCenter.stopMonitoring([.debugSmokeTest])
        do {
            try activityCenter.startMonitoring(
                .debugSmokeTest,
                during: schedule,
                events: [eventName: event]
            )
            print("[ScreenTime][Debug] ⏱️ Debug monitor scheduled (threshold = 1 minute of usage)")
        } catch {
            print("[ScreenTime][Debug] ❌ Failed to start debug monitor: \(error.localizedDescription)")
        }
    }
}
#endif

// MARK: - Device Activity Names

extension DeviceActivityName {
    static let dailyUsage = DeviceActivityName("dailyUsage")
    static let bonusSession = DeviceActivityName("bonusSession")
    static let debugSmokeTest = DeviceActivityName("debugSmokeTest")
    
    /// Create a unique bonus activity name (forces fresh usage count)
    static func bonusActivity() -> DeviceActivityName {
        DeviceActivityName("Bonus_\(UUID().uuidString)")
    }
}

// MARK: - Device Activity Event Names

extension DeviceActivityEvent.Name {
    static let bonusReached = DeviceActivityEvent.Name("bonusReached")
    static let debugSmokeTestReached = DeviceActivityEvent.Name("debugSmokeTestReached")
}

// MARK: - Notifications

extension Notification.Name {
    static let screenTimeLimitReached = Notification.Name("screenTimeLimitReached")
}

