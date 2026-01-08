import Foundation
import PostHog

/// Centralized analytics bootstrapper so we can defer heavy SDK work
/// until the user actually completes onboarding (or returns as an
/// existing user). This prevents analytics network calls and any
/// internal WKWebView usage from blocking the first-run experience.
final class AnalyticsManager {
    static let shared = AnalyticsManager()
    
    private var isConfigured = false
    private init() {}
    
    func startIfNeeded() {
        // Completely disable analytics in DEBUG builds - PostHog causes main thread stalls
        #if DEBUG
        guard !isConfigured else { return }
        isConfigured = true
        print("[Analytics] PostHog DISABLED for DEBUG build")
        return
        #else
        guard !isConfigured else { return }
        isConfigured = true
        
        DispatchQueue.global(qos: .utility).async {
            let apiKey = "phc_2nAwTZByOmyniSMOvQ7B16WlGGiKJ47rUT6cAC9RLvH"
            let host = "https://us.i.posthog.com"
            
            let config = PostHogConfig(apiKey: apiKey, host: host)
            config.sessionReplay = false
            
            DispatchQueue.main.async {
                PostHogSDK.shared.setup(config)
                print("[Analytics] PostHog configured")
            }
        }
        #endif
    }
}
