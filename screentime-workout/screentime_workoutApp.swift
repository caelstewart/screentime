//
//  screentime_workoutApp.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseFirestore
import FirebaseInAppMessaging
import FirebaseAnalytics
import GoogleSignIn
import SuperwallKit

// Simple launch timer for startup diagnostics
enum AppLaunchMetrics {
    static let start = Date()
}

// MARK: - Superwall Manager (Lazy Init to avoid blocking startup)

/// Manages Superwall initialization lazily to prevent WKWebView from blocking app startup
final class SuperwallManager {
    static let shared = SuperwallManager()
    
    /// Set to false to completely disable Superwall (useful for debugging network issues)
    static let isEnabled = true
    
    private var isConfigured = false
    private var isPreWarmed = false
    private let apiKey = "pk_MUcYgtBh-gh0bY0MfNGhN"
    
    private init() {}
    
    /// Configure Superwall lazily (only when first paywall is triggered)
    /// IMPORTANT: Must be called from main thread but we use async to not block
    private func configureIfNeeded() {
        guard Self.isEnabled, !isConfigured else { return }
        isConfigured = true
        
        // Superwall.configure() can trigger WKWebView initialization which is SLOW
        // We wrap it but can't make it fully async - Superwall requires main thread
        let start = Date()
        Superwall.configure(apiKey: apiKey)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "[Superwall] Configured (lazy init) in %.2fs", elapsed))
    }
    
    /// Pre-warm Superwall and WKWebView in the background
    /// Call this ONLY from settings tab or when paywall is actually needed
    /// DO NOT call during onboarding - it will freeze the UI
    /// This is FIRE AND FORGET - caller should NOT await this
    func preWarm() {
        guard Self.isEnabled, !isPreWarmed else { return }
        isPreWarmed = true
        print("[Superwall] Pre-warming started (background)...")
        
        // Use DispatchQueue instead of Task to ensure true background execution
        // WKWebView initialization can block main thread for 10+ seconds
        // We delay significantly to ensure UI is fully responsive first
        DispatchQueue.global(qos: .background).async { [self] in
            // LONG delay - let the entire onboarding flow be responsive first
            // WKWebView will block main thread when it finally loads
            Thread.sleep(forTimeInterval: 5.0)
            
            print("[Superwall] Starting main thread config after 5s delay...")
            
            // Configure on main thread (Superwall requires it)
            DispatchQueue.main.async {
                let start = Date()
                self.configureIfNeeded()
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "[Superwall] Main thread config took %.2fs", elapsed))
            }
            
            // Additional delay before preloading paywall
            // This is what actually triggers WKWebView process launches
            Thread.sleep(forTimeInterval: 2.0)
            
            // Preload paywall completely in background
            Task.detached(priority: .background) {
                do {
                    try await Superwall.shared.preloadPaywalls(forPlacements: ["campaign_trigger"])
                    print("[Superwall] Pre-warm complete - paywall preloaded")
                } catch {
                    print("[Superwall] Paywall preload failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Safe wrapper for Superwall.shared.register - won't crash or block if disabled
    func register(placement: String, completion: (() -> Void)? = nil) {
        guard Self.isEnabled else {
            print("[Superwall] Disabled - skipping paywall for '\(placement)'")
            completion?()
            return
        }
        
        // Configure lazily on first use (should already be done via preWarm)
        configureIfNeeded()
        
        Superwall.shared.register(placement: placement) {
            completion?()
        }
    }
}

// MARK: - App Delegate for Firebase

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Whether Firebase has been configured this session
    static var isFirebaseConfigured = false
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        print("[App] 🚀 didFinishLaunchingWithOptions START - \(Date())")
        
        // ALWAYS configure Firebase - Auth requires it to be configured before use.
        // The XPC reporter stalls are caused by GoogleAppMeasurement (Analytics),
        // which is already disabled via Info.plist flags.
        Self.configureFirebase()
        
        // Check if this is first run (onboarding not complete)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            // During onboarding, disable Firestore network to minimize any remaining XPC activity
            Firestore.firestore().disableNetwork { _ in
                print("[Firebase] Network disabled during onboarding")
            }
        }
        
        // Defer analytics until after onboarding to keep first-run silky smooth
        print("[Analytics] PostHog setup deferred until onboarding completes")
        
        // NOTE: Superwall is now lazily initialized on first paywall trigger
        // to avoid WKWebView blocking app startup with network issues
        print("[Superwall] Deferred initialization (will configure on first use)")
        
        // Pre-warm keyboard to avoid 2-3s delay on first text input
        // iOS loads keyboard extensions lazily - this forces early load
        KeyboardPrewarmer.shared.prewarm()
        
        print("[App] ✅ didFinishLaunchingWithOptions COMPLETE - \(Date())")
        return true
    }
    
    /// Configure Firebase (called once at launch)
    static func configureFirebase() {
        guard !isFirebaseConfigured else {
            print("[Firebase] Already configured, skipping")
            return
        }
        isFirebaseConfigured = true
        
        let firebaseStart = Date()
        FirebaseApp.configure()
        print(String(format: "[App] Firebase.configure() took %.3fs", Date().timeIntervalSince(firebaseStart)))
        
        // CRITICAL: Completely disable Firebase Analytics to stop XPC reporter stalls
        // The Info.plist flags prevent collection but the SDK still initializes
        // This programmatic disable stops any remaining reporter activity
        Analytics.setAnalyticsCollectionEnabled(false)
        
        // Disable Firebase In-App Messaging
        let inAppMessaging = InAppMessaging.inAppMessaging()
        inAppMessaging.messageDisplaySuppressed = true
        inAppMessaging.automaticDataCollectionEnabled = false
        
        // Configure Firestore for fast offline-first loading
        let firestore = Firestore.firestore()
        let settings = firestore.settings
        settings.cacheSettings = PersistentCacheSettings(sizeBytes: 100 * 1024 * 1024 as NSNumber) // 100MB cache
        firestore.settings = settings
        
        print("[Firebase] ✅ Configured successfully")
    }
    
    // Handle URL callback for Google Sign-In
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - Keyboard Pre-Warmer

/// Pre-warms the iOS keyboard to avoid the 2-3 second delay on first appearance
/// iOS loads keyboard extensions lazily - this forces early initialization
final class KeyboardPrewarmer {
    static let shared = KeyboardPrewarmer()
    private var hasPrewarmed = false
    
    private init() {}
    
    /// Call this early in app launch to pre-initialize the keyboard
    func prewarm() {
        guard !hasPrewarmed else { return }
        hasPrewarmed = true
        
        // Run on main thread after a tiny delay to not block launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.triggerKeyboardLoad()
        }
    }
    
    private func triggerKeyboardLoad() {
        // Create a hidden text field and briefly make it first responder
        // This forces iOS to load the keyboard extension
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        
        let hiddenField = UITextField(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        hiddenField.autocorrectionType = .no
        hiddenField.spellCheckingType = .no
        window.addSubview(hiddenField)
        
        // Become first responder to trigger keyboard load
        hiddenField.becomeFirstResponder()
        
        // Immediately resign and remove - keyboard is now cached
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            hiddenField.resignFirstResponder()
            hiddenField.removeFromSuperview()
            print("[Keyboard] Pre-warmed successfully")
        }
    }
}

// MARK: - Main App

@main
struct screentime_workoutApp: App {
    // Register app delegate for Firebase setup
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    var sharedModelContainer: ModelContainer = {
        let modelStart = Date()
        print("[App] Creating model container...")
        let schema = Schema([
            WorkoutSession.self,
            ScreenTimeBalance.self,
            AppTimeLimit.self,
        ])
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            let elapsed = Date().timeIntervalSince(modelStart)
            print(String(format: "[App] Model container created successfully in %.2fs", elapsed))
            return container
        } catch {
            print("[App] Model container error: \(error)")
            
            // Migration failed - try to delete the corrupted store and start fresh
            // Data will be restored from Firebase (source of truth)
            print("[App] Attempting to delete corrupted store and recreate...")
            
            // Get the default store URL
            let storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
            
            do {
                // Delete the main store file and related files
                let fileManager = FileManager.default
                let storePath = storeURL.path
                
                // Delete .store, .store-shm, .store-wal files
                let filesToDelete = [
                    storePath,
                    storePath + "-shm",
                    storePath + "-wal"
                ]
                
                for file in filesToDelete {
                    if fileManager.fileExists(atPath: file) {
                        try fileManager.removeItem(atPath: file)
                        print("[App] Deleted: \(file)")
                    }
                }
                
                // Try creating container again with fresh store
                let freshContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
                let elapsed = Date().timeIntervalSince(modelStart)
                print(String(format: "[App] Model container recreated successfully after deleting corrupted store in %.2fs", elapsed))
                print("[App] ⚠️ Local data was reset - will restore from Firebase")
                return freshContainer
            } catch {
                print("[App] Failed to recreate store: \(error)")
            }
            
            // Last resort: in-memory only (data won't persist but app will work)
            print("[App] ⚠️ Using in-memory store as last resort")
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let freshContainer = try! ModelContainer(for: schema, configurations: [fallbackConfig])
            let elapsed = Date().timeIntervalSince(modelStart)
            print(String(format: "[App] In-memory store created in %.2fs", elapsed))
            return freshContainer
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle Google Sign-In URL callback
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onAppear {
                    print("[App] ContentView appeared")
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
