//
//  RepCounter.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI

struct RepCounter: View {
    let count: Int
    let target: Int?
    
    var body: some View {
        // This component is now simpler as the main counter is custom in ActiveWorkoutView
        // We can keep it for other uses or remove if unused. 
        // For now, I'll update it to match the new theme just in case.
        VStack(spacing: 0) {
            Text("\(count)")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            
            Text("REPS")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Colors.primary)
                .tracking(2)
        }
    }
}
