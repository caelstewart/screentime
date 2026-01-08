import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation
import os.log

/// Device Activity Monitor Extension
/// Listens for threshold events and applies shields + collapses bonus pool.
/// iOS instantiates this class when device activity thresholds are reached.
@objc(DeviceActivityMonitorExtension)
public class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    
    private let store = ManagedSettingsStore()
    private let osLog = OSLog(subsystem: "app.screentime-workout.DeviceActivityMonitorExtension", category: "Monitor")
    
    public override init() {
        super.init()
        os_log("🚀 DeviceActivityMonitorExtension INIT", log: osLog, type: .default)
        log("🚀 DeviceActivityMonitorExtension INITIALIZED")
    }
    
    // MARK: - Logging
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        os_log("%{public}@", log: osLog, type: .debug, message)
        print("[Monitor] \(message)")
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.screentime-workout") else {
            print("[Monitor] ❌ App Group container not found")
            return
        }
        let url = containerURL.appendingPathComponent("monitor_log.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    // MARK: - DeviceActivity callbacks
    public override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        os_log("🌅 intervalDidStart: %{public}@", log: osLog, type: .default, activity.rawValue)
        log("🌅 intervalDidStart \(activity.rawValue)")
        // Clear shields when interval starts (beginning of day)
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }
    
    public override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        os_log("🌙 intervalDidEnd: %{public}@", log: osLog, type: .fault, activity.rawValue)
        log("🌙 intervalDidEnd \(activity.rawValue)")
        
        // CHECK IF THIS IS THE BONUS SESSION ENDING
        if activity.rawValue == "bonusSession" {
            os_log("🚨 BONUS SESSION ENDED - RE-APPLYING SHIELDS!", log: osLog, type: .fault)
            log("🚨 BONUS SESSION ENDED - TIME TO RE-BLOCK!")
            
            // Re-apply all the shields that were saved when bonus started
            reapplyShieldsAfterBonus()
            
            // Clear the bonus pool in shared defaults
            collapseSharedBonusPool()
            
            // Notify main app
            notifyMainApp(event: "bonusExpired")
            
            log("✅ Shields re-applied after bonus expiry")
            os_log("✅ Shields re-applied after bonus expiry", log: osLog, type: .fault)
        }
    }
    
    /// Re-apply all shields when bonus time expires
    private func reapplyShieldsAfterBonus() {
        guard let defaults = sharedDefaults else {
            os_log("❌ Cannot access shared defaults for re-blocking", log: osLog, type: .error)
            log("❌ Cannot access shared defaults for re-blocking")
            return
        }
        
        // Load saved app tokens
        if let appData = defaults.data(forKey: "bonusSession_blockedApps") {
            do {
                let appTokens = try PropertyListDecoder().decode(Set<ApplicationToken>.self, from: appData)
                if !appTokens.isEmpty {
                    store.shield.applications = appTokens
                    os_log("✅ Re-blocked %d apps", log: osLog, type: .fault, appTokens.count)
                    log("✅ Re-blocked \(appTokens.count) apps")
                }
            } catch {
                os_log("❌ Failed to decode app tokens: %{public}@", log: osLog, type: .error, error.localizedDescription)
                log("❌ Failed to decode app tokens: \(error)")
            }
        }
        
        // Load saved category tokens
        if let catData = defaults.data(forKey: "bonusSession_blockedCategories") {
            do {
                let catTokens = try PropertyListDecoder().decode(Set<ActivityCategoryToken>.self, from: catData)
                if !catTokens.isEmpty {
                    store.shield.applicationCategories = .specific(catTokens)
                    os_log("✅ Re-blocked %d categories", log: osLog, type: .fault, catTokens.count)
                    log("✅ Re-blocked \(catTokens.count) categories")
                }
            } catch {
                os_log("❌ Failed to decode category tokens: %{public}@", log: osLog, type: .error, error.localizedDescription)
                log("❌ Failed to decode category tokens: \(error)")
            }
        }
    }
    
    public override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        os_log("🚨 THRESHOLD REACHED: %{public}@ activity: %{public}@", log: osLog, type: .fault, event.rawValue, activity.rawValue)
        log("🚨 threshold reached: \(event.rawValue) activity: \(activity.rawValue)")
        
        // CHECK IF THIS IS THE BONUS THRESHOLD BEING REACHED
        // This fires after N minutes of USAGE within the bonus window
        if event.rawValue == "bonusReached" || activity.rawValue.hasPrefix("Bonus_") {
            os_log("🎯 BONUS TIME USED UP - SLAMMING SHIELDS!", log: osLog, type: .fault)
            log("🎯 BONUS TIME USED UP - User spent their earned time!")
            
            // Re-apply all shields
            reapplyShieldsAfterBonus()
            
            // Collapse the bonus pool
            collapseSharedBonusPool()
            
            // Notify main app
            notifyMainApp(event: "bonusUsedUp")
            
            log("✅ Shields slammed after bonus usage threshold reached")
            os_log("✅ Shields slammed after bonus usage threshold reached", log: osLog, type: .fault)
            return
        }
        
        guard let defaults = sharedDefaults else {
            os_log("❌ sharedDefaults unavailable", log: osLog, type: .error)
            log("❌ sharedDefaults unavailable")
            return
        }
        
        var appliedSomething = false
        
        // Apps
        let appKey = "blockedTokens_\(event.rawValue)"
        os_log("Looking for app tokens at key: %{public}@", log: osLog, type: .default, appKey)
        if let data = defaults.data(forKey: appKey) {
            os_log("Found data for app tokens: %d bytes", log: osLog, type: .default, data.count)
            do {
                let tokens = try PropertyListDecoder().decode(Set<ApplicationToken>.self, from: data)
                os_log("Decoded %d app tokens", log: osLog, type: .default, tokens.count)
                store.shield.applications = tokens
                log("✅ Applied app shields: \(tokens.count) apps blocked")
                os_log("✅ Applied %d app shields", log: osLog, type: .fault, tokens.count)
                appliedSomething = true
            } catch {
                os_log("❌ Failed to decode app tokens: %{public}@", log: osLog, type: .error, error.localizedDescription)
                log("❌ Failed to decode app tokens: \(error)")
            }
        } else {
            log("⚠️ No app tokens for \(appKey)")
        }
        
        // Categories
        let catKey = "blockedCategories_\(event.rawValue)"
        os_log("Looking for category tokens at key: %{public}@", log: osLog, type: .default, catKey)
        if let data = defaults.data(forKey: catKey) {
            os_log("Found data for category tokens: %d bytes", log: osLog, type: .default, data.count)
            do {
                let tokens = try PropertyListDecoder().decode(Set<ActivityCategoryToken>.self, from: data)
                os_log("Decoded %d category tokens", log: osLog, type: .default, tokens.count)
                store.shield.applicationCategories = .specific(tokens)
                log("✅ Applied category shields: \(tokens.count) categories blocked")
                os_log("✅ Applied %d category shields", log: osLog, type: .fault, tokens.count)
                appliedSomething = true
            } catch {
                os_log("❌ Failed to decode category tokens: %{public}@", log: osLog, type: .error, error.localizedDescription)
                log("❌ Failed to decode category tokens: \(error)")
            }
        } else {
            log("⚠️ No category tokens for \(catKey)")
        }
        
        if appliedSomething {
            os_log("🛡️ SHIELDS APPLIED - APP SHOULD BE BLOCKED NOW", log: osLog, type: .fault)
        }
        
        collapseSharedBonusPool()
        notifyMainApp(event: event.rawValue)
        log("✅ threshold handling complete")
        os_log("✅ threshold handling complete", log: osLog, type: .default)
    }
    
    public override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        log("⚠️ approaching threshold: \(event.rawValue)")
    }
    
    // MARK: - Helpers
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.app.screentime-workout")
    }
    
    private func collapseSharedBonusPool() {
        guard let defaults = sharedDefaults else { return }
        let bonusKey = "screentime.sharedBonusMinutes"
        let expiryKey = "screentime.bonusExpiryDate"
        let current = defaults.integer(forKey: bonusKey)
        if current > 0 {
            log("💥 collapsing bonus pool \(current) → 0")
            defaults.set(0, forKey: bonusKey)
            defaults.removeObject(forKey: expiryKey)
            defaults.set(true, forKey: "screentime.bonusWasCollapsed")
            defaults.synchronize()
        }
    }
    
    private func notifyMainApp(event: String) {
        let name = "app.screentime-workout.limitReached" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
        log("📣 posted Darwin notification for event \(event)")
    }
}
