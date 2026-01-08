//
//  WorkoutContainerView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI

enum WorkoutPhase: Equatable {
    case countdown
    case active
    case reward(reps: Int)
}

struct WorkoutContainerView: View {
    let exercise: Exercise
    let onComplete: (Int) -> Void
    let onDismiss: () -> Void
    
    @State private var phase: WorkoutPhase = .countdown
    @State private var cameraManager = CameraManager()
    
    var body: some View {
        ZStack {
            // Background always visible
            Theme.Colors.background
                .ignoresSafeArea()
            
            switch phase {
            case .countdown:
                CountdownView(
                    exercise: exercise,
                    onComplete: {
                        print("[WorkoutContainer] Countdown complete, starting active phase")
                        withAnimation(.easeInOut(duration: 0.3)) {
                            phase = .active
                        }
                    },
                    onSkip: {
                        print("[WorkoutContainer] Countdown skipped")
                        onDismiss()
                    }
                )
                .transition(.opacity)
                
            case .active:
                ActiveWorkoutView(
                    exercise: exercise,
                    cameraManager: cameraManager
                ) { reps in
                    print("[WorkoutContainer] Active phase complete with \(reps) reps")
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .reward(reps: reps)
                    }
                }
                .transition(.opacity)
                
            case .reward(let reps):
                RewardView(
                    exercise: exercise,
                    reps: reps,
                    onCollect: {
                        print("[WorkoutContainer] Reward collected")
                        onComplete(reps)
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            print("[WorkoutContainer] View appeared")
        }
        .task {
            // Pre-configure camera during countdown
            print("[WorkoutContainer] Pre-configuring camera...")
            await cameraManager.configure()
            print("[WorkoutContainer] Camera configured: \(cameraManager.isConfigured)")
        }
    }
}

#Preview {
    WorkoutContainerView(
        exercise: .pushUps,
        onComplete: { reps in print("Completed: \(reps)") },
        onDismiss: { print("Dismissed") }
    )
}
