//
//  ActiveWorkoutView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import UIKit

struct ActiveWorkoutView: View {
    let exercise: Exercise
    let cameraManager: CameraManager
    let onComplete: (Int) -> Void
    
    @State private var poseDetector = PoseDetector()
    @State private var pushUpAnalyzer = PushUpAnalyzer()
    @State private var squatAnalyzer = SquatAnalyzer()
    @State private var plankAnalyzer = PlankAnalyzer()
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showCompleteButton = false
    @State private var frameCount = 0
    
    // Confetti state
    @State private var showConfetti = false
    @State private var confettiTrigger = 0
    
    private let minimumReps = 1
    
    // MARK: - Computed Properties for Current Analyzer
    
    private var currentRepCount: Int {
        switch exercise.type {
        case .pushUps: return pushUpAnalyzer.repCount
        case .squats: return squatAnalyzer.repCount
        case .plank: return plankAnalyzer.repCount
        }
    }
    
    private var currentFeedback: String {
        switch exercise.type {
        case .pushUps: return pushUpAnalyzer.feedback
        case .squats: return squatAnalyzer.feedback
        case .plank: return plankAnalyzer.feedback
        }
    }
    
    private var showCurrentPositioningFeedback: Bool {
        switch exercise.type {
        case .pushUps: return pushUpAnalyzer.showPositioningFeedback
        case .squats: return squatAnalyzer.showPositioningFeedback
        case .plank: return plankAnalyzer.showPositioningFeedback
        }
    }
    
    private var plankSecondsHeld: Int {
        plankAnalyzer.secondsHeld
    }
    
    var body: some View {
        ZStack {
            // Camera layer
            if cameraManager.isConfigured {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
                    .onAppear {
                        print("[ActiveWorkout] Camera preview appeared, isRunning: \(cameraManager.isRunning)")
                    }
            } else {
                Theme.Colors.background
                    .ignoresSafeArea()
                    .onAppear {
                        print("[ActiveWorkout] Camera NOT configured, showing black background")
                    }
            }
            
            // Skeleton Overlay
            PoseOverlayView(
                pose: poseDetector.detectedPose,
                lineColor: Theme.Colors.skeleton,
                jointColor: Theme.Colors.jointDot,
                lineWidth: 4,
                jointRadius: 6
            )
            .ignoresSafeArea()
            
            // Gradient Overlay
            Theme.Gradients.workoutOverlay
                .ignoresSafeArea()
            
            // Confetti Layer
            if showConfetti {
                ConfettiView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            
            // UI Layer
            VStack(spacing: 0) {
                // Title
                Text(exercise.displayName.lowercased())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.primary)
                    .padding(.top, 26)
                
                // Pills + Counter row (pills aligned to TOP of counter)
                HStack(alignment: .top) {
                    // Left: Timer
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text(formattedTime)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.top, 28)
                    
                    Spacer()
                    
                    // Center: Counter
                    VStack(spacing: 0) {
                        if exercise.type == .plank {
                            // For plank: show seconds held as main number
                            Text("\(plankSecondsHeld)")
                                .font(.system(size: 96, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.Gradients.counterText)
                                .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 10, x: 0, y: 0)
                                .contentTransition(.numericText())
                            
                            Text("SECONDS")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.Colors.primary.opacity(0.8))
                                .tracking(4)
                                .offset(y: -10)
                        } else {
                            // For push-ups and squats: show rep count
                            Text("\(currentRepCount)")
                                .font(.system(size: 96, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.Gradients.counterText)
                                .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 10, x: 0, y: 0)
                                .contentTransition(.numericText())
                            
                            Text("REPS")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.Colors.primary.opacity(0.8))
                                .tracking(4)
                                .offset(y: -10)
                        }
                    }
                    
                    Spacer()
                    
                    // Right: Earned Time
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.gen3")
                        Text("+\(earnedMinutes) min")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Colors.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.Colors.primary.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.Colors.primary.opacity(0.3), lineWidth: 1))
                    .padding(.top, 28)
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Bottom: Add X minutes button (always visible)
                VStack(spacing: 0) {
                    // Main action button
                    Button(action: {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred(intensity: 0.8)
                        completeWorkout()
                    }) {
                        HStack(spacing: 12) {
                            Text("+ Add \(earnedMinutes) minutes")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Theme.Gradients.primaryButton)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(
                                    LinearGradient(
                                        colors: [Theme.Colors.primary.opacity(0.8), Theme.Colors.primary.opacity(0.3)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 2
                                )
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .background(
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 150)
                    .offset(y: 20)
                )
            }
        }
        .onAppear {
            startWorkout()
        }
        .onDisappear {
            stopWorkout()
        }
        .onChange(of: currentRepCount) { oldValue, newValue in
            // Trigger confetti every 5 reps (or every 60 seconds for plank = 3 reps)
            let confettiInterval = exercise.type == .plank ? 3 : 5
            if newValue > 0 && newValue % confettiInterval == 0 && newValue > oldValue {
                triggerConfetti()
            }
        }
    }
    
    // MARK: - Time Formatting
    
    private var formattedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private var earnedMinutes: Int {
        exercise.calculateEarnedMinutes(units: currentRepCount)
    }
    
    // MARK: - Methods
    
    private func startWorkout() {
        print("[ActiveWorkout] Starting \(exercise.type.displayName) workout, camera configured: \(cameraManager.isConfigured)")
        
        // Reset the appropriate analyzer
        switch exercise.type {
        case .pushUps:
            pushUpAnalyzer.reset()
        case .squats:
            squatAnalyzer.reset()
        case .plank:
            plankAnalyzer.reset()
        }
        
        cameraManager.frameHandler = { buffer in
            frameCount += 1
            poseDetector.processFrame(buffer)
            
            DispatchQueue.main.async {
                let pose = poseDetector.detectedPose
                
                // Use the appropriate analyzer based on exercise type
                switch exercise.type {
                case .pushUps:
                    pushUpAnalyzer.analyze(pose: pose)
                case .squats:
                    squatAnalyzer.analyze(pose: pose)
                case .plank:
                    plankAnalyzer.analyze(pose: pose)
                }
            }
        }
        
        cameraManager.start()
        print("[ActiveWorkout] Camera start() called")
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedTime += 1
        }
    }
    
    private func stopWorkout() {
        timer?.invalidate()
        timer = nil
        cameraManager.frameHandler = nil
        cameraManager.stop()
    }
    
    private func completeWorkout() {
        stopWorkout()
        onComplete(currentRepCount)
    }
    
    private func triggerConfetti() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        withAnimation {
            showConfetti = true
            confettiTrigger += 1
        }
        
        // Hide confetti after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showConfetti = false
            }
        }
    }
}

// MARK: - Confetti View

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.white, Theme.Colors.primary],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: particle.width, height: particle.height)
                        .rotationEffect(.degrees(particle.rotation))
                        .position(particle.position)
                        .opacity(particle.opacity)
                }
            }
            .onAppear {
                createParticles(in: geometry.size)
            }
        }
    }
    
    private func createParticles(in size: CGSize) {
        for _ in 0..<25 {
            let startX = size.width / 2 + CGFloat.random(in: -80...80)
            let startY = size.height * 0.25
            
            var particle = ConfettiParticle(
                position: CGPoint(x: startX, y: startY),
                width: CGFloat.random(in: 3...6),      // Thin
                height: CGFloat.random(in: 16...28),   // Tall vertical rectangles
                rotation: Double.random(in: -30...30),
                opacity: 1.0
            )
            
            particles.append(particle)
            
            // Animate each particle
            let index = particles.count - 1
            let endX = startX + CGFloat.random(in: -120...120)
            let endY = size.height + 50
            let endRotation = particle.rotation + Double.random(in: -180...180)
            
            withAnimation(.easeOut(duration: Double.random(in: 1.2...2.0))) {
                particles[index].position = CGPoint(x: endX, y: endY)
                particles[index].rotation = endRotation
                particles[index].opacity = 0
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    let width: CGFloat
    let height: CGFloat
    var rotation: Double
    var opacity: Double
}
