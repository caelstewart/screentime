//
//  RewardView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import UIKit

struct RewardView: View {
    let exercise: Exercise
    let reps: Int
    let onCollect: () -> Void
    
    @State private var showContent = false
    @State private var pulseState = false
    
    private var earnedMinutes: Int {
        exercise.calculateEarnedMinutes(units: reps)
    }
    
    var body: some View {
        ZStack {
            // Background - Deep space with gold glow
            Theme.Colors.background
                .ignoresSafeArea()
            
            // Ambient Glow
            RadialGradient(
                colors: [
                    Theme.Colors.reward.opacity(0.15),
                    Theme.Colors.background
                ],
                center: .center,
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()
            .scaleEffect(pulseState ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulseState)
            
            // Particles (Simplified confetti)
            ForEach(0..<15) { i in
                Circle()
                    .fill(Theme.Colors.reward.opacity(Double.random(in: 0.1...0.4)))
                    .frame(width: CGFloat.random(in: 4...12))
                    .offset(
                        x: CGFloat.random(in: -150...150),
                        y: CGFloat.random(in: -300...300)
                    )
                    .scaleEffect(showContent ? 1 : 0)
                    .animation(
                        .spring(duration: Double.random(in: 1...2))
                        .delay(Double.random(in: 0...0.5)),
                        value: showContent
                    )
            }
            
            VStack(spacing: 0) {
                Spacer()
                
                // Trophy Section
                ZStack {
                    // Glow behind trophy
                    Circle()
                        .fill(Theme.Colors.reward.opacity(0.2))
                        .frame(width: 160, height: 160)
                        .blur(radius: 40)
                    
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "FFF7AD"), Theme.Colors.reward], // Gold gradient
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Theme.Colors.reward.opacity(0.5), radius: 20, y: 10)
                        .scaleEffect(showContent ? 1 : 0.5)
                        .rotationEffect(.degrees(showContent ? 0 : -20))
                }
                .padding(.bottom, 40)
                
                // Heading
                Text("Crushed it!")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .scaleEffect(showContent ? 1 : 0.9)
                    .opacity(showContent ? 1 : 0)
                
                Text("You completed \(reps) \(exercise.displayName.lowercased())")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.bottom, 40)
                    .opacity(showContent ? 1 : 0)
                
                // Reward Card
                VStack(spacing: 16) {
                    Text("REWARD UNLOCKED")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.reward)
                        .tracking(3)
                        .opacity(0.8)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("+\(earnedMinutes)")
                            .font(.system(size: 80, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, Theme.Colors.reward],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Theme.Colors.reward.opacity(0.3), radius: 15, y: 5)
                        
                        Text("min")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Colors.reward.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 32))
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(
                            LinearGradient(
                                colors: [Theme.Colors.reward.opacity(0.5), Theme.Colors.reward.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .padding(.horizontal, 24)
                .offset(y: showContent ? 0 : 50)
                .opacity(showContent ? 1 : 0)
                
                Spacer()
                
                // Button
                Button(action: {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred(intensity: 0.8)
                    onCollect()
                }) {
                    HStack {
                        Text("Collect Time")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Theme.Colors.reward) // Solid gold/yellow for high contrast
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: Theme.Colors.reward.opacity(0.4), radius: 20, x: 0, y: 10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .offset(y: showContent ? 0 : 50)
                .opacity(showContent ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                showContent = true
            }
            pulseState = true
        }
    }
}
