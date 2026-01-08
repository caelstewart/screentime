import Foundation

/// Simple utility that pings the main thread on an interval and logs
/// whenever the main queue takes too long to respond. Helps surface
/// real UI freezes that are otherwise hard to capture in logs.
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()
    
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var label: String = "global"
    
    /// Minimum stall (in seconds) before we log a warning.
    private let stallThreshold: TimeInterval = 0.5
    /// How often to ping the main thread.
    private let interval: TimeInterval = 0.5
    
    private init() {}
    
    func start(label: String = "global") {
        guard !isRunning else { return }
        
        self.label = label
        isRunning = true
        
        let queue = DispatchQueue(label: "com.screentime-workout.mainthread-monitor", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pingSent = Date()
            DispatchQueue.main.async {
                let stall = Date().timeIntervalSince(pingSent)
                if stall > self.stallThreshold {
                    print(String(format: "[Perf][%@] ⚠️ Main thread stalled for %.3fs", self.label, stall))
                    let stack = Thread.callStackSymbols.joined(separator: "\n")
                    print("[Perf][\(self.label)] Stack snapshot after stall:\n\(stack)")
                }
            }
        }
        timer.resume()
        self.timer = timer
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }
}
