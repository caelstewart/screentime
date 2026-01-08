//
//  CountdownView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import UIKit

struct CountdownView: View {
    let exercise: Exercise
    let onComplete: () -> Void
    let onSkip: () -> Void
    
    @State private var countdown: Int = 3
    @State private var showGetReady = false
    @State private var timer: Timer?
    
    // Haptic generator
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
            
            VStack(spacing: Theme.Spacing.xl) {
                Spacer()
                
                // Exercise info
                VStack(spacing: Theme.Spacing.sm) {
                    Text(exercise.displayName.lowercased())
                        .font(Theme.Typography.title())
                        .foregroundStyle(Theme.Colors.textPrimary)
                    
                    Text("\(exercise.minutesPerUnit) min × \(exercise.type.unitLabel)")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Spacer()
                
                // Countdown number
                ZStack {
                    if showGetReady {
                        Text("GO!")
                            .font(Theme.Typography.displayMedium())
                            .foregroundStyle(Theme.Colors.primary)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("\(countdown)")
                            .font(Theme.Typography.displayLarge())
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(height: 120)
                
                // Get ready label
                Text("get ready")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
                
                Spacer()
                Spacer()
                
                // Skip button
                Button(action: onSkip) {
                    Text("tap to skip")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textMuted)
                        .padding()
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .onAppear {
            print("[Countdown] View appeared")
            hapticGenerator.prepare()
            // Initial haptic for "3"
            hapticGenerator.impactOccurred(intensity: 0.6)
            startCountdown()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func startCountdown() {
        print("[Countdown] Starting countdown from 3")
        
        // Use Timer which is more reliable than asyncAfter
        // Timer runs on the run loop and won't get blocked by async operations
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                if countdown > 1 {
                    countdown -= 1
                    print("[Countdown] \(countdown)")
                    hapticGenerator.impactOccurred(intensity: 0.6)
                } else if !showGetReady {
                    showGetReady = true
                    print("[Countdown] GO!")
                    hapticGenerator.impactOccurred(intensity: 1.0)
                } else {
                    print("[Countdown] Complete!")
                    timer?.invalidate()
                    timer = nil
                    onComplete()
                }
            }
        }
    }
}

#Preview {
    CountdownView(
        exercise: .pushUps,
        onComplete: { print("Done!") },
        onSkip: { print("Skipped") }
    )
}
