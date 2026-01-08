//
//  LoginView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-30.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @State private var authManager = AuthenticationManager.shared
    @State private var showError = false
    @State private var animateBackground = false
    @State private var animateLogo = false
    
    var body: some View {
        ZStack {
            // Animated background
            backgroundView
            
            VStack(spacing: 0) {
                Spacer()
                
                // Logo and Title
                VStack(spacing: 20) {
                    // App Icon
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Theme.Colors.primary.opacity(0.3), Theme.Colors.primary.opacity(0)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 80
                                )
                            )
                            .frame(width: 160, height: 160)
                            .blur(radius: 20)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 32)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "1A1A2E"), Color(hex: "0F0F1A")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 100, height: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 32)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Theme.Colors.primary.opacity(0.5), Theme.Colors.primary.opacity(0.1)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2
                                        )
                                )
                            
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(Theme.Gradients.primaryButton)
                        }
                        .scaleEffect(animateLogo ? 1 : 0.8)
                        .opacity(animateLogo ? 1 : 0)
                    }
                    
                    VStack(spacing: 8) {
                        Text("ScreenBlock")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .opacity(animateLogo ? 1 : 0)
                    .offset(y: animateLogo ? 0 : 20)
                    
                    Text("Earn your screen time")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .opacity(animateLogo ? 1 : 0)
                }
                
                Spacer()
                Spacer()
                
                // Sign in buttons
                VStack(spacing: 14) {
                    // Apple Sign In
                    SignInWithAppleButton(.signIn) { request in
                        authManager.handleAppleSignInRequest(request)
                    } onCompletion: { result in
                        Task {
                            await authManager.handleAppleSignInCompletion(result)
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    
                    // Google Sign In
                    Button {
                        Task {
                            try? await authManager.signInWithGoogle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            // Google G logo
                            GoogleLogo()
                                .frame(width: 20, height: 20)
                            
                            Text("Continue with Google")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    // Skip login - uses anonymous authentication
                    Button {
                        Task {
                            do {
                                try await authManager.signInAnonymously()
                                print("[Login] Signed in anonymously - data will be preserved")
                            } catch {
                                print("[Login] Anonymous sign in failed: \(error)")
                            }
                        }
                    } label: {
                        Text("Continue without account")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .opacity(animateLogo ? 1 : 0)
                .offset(y: animateLogo ? 0 : 30)
                
                // Terms
                Text("By continuing, you agree to our Terms of Service and Privacy Policy")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .opacity(animateLogo ? 0.7 : 0)
            }
            
            // Loading overlay
            if authManager.isLoading {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primary))
                    .scaleEffect(1.5)
            }
        }
        .alert("Sign In Error", isPresented: .init(
            get: { authManager.errorMessage != nil },
            set: { if !$0 { authManager.clearError() } }
        )) {
            Button("OK") {
                authManager.clearError()
            }
        } message: {
            Text(authManager.errorMessage ?? "An error occurred")
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) {
                animateLogo = true
            }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                animateBackground = true
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
            
            // Animated gradient orbs
            Circle()
                .fill(Theme.Colors.primary.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(
                    x: animateBackground ? 100 : -100,
                    y: animateBackground ? -200 : -100
                )
            
            Circle()
                .fill(Theme.Colors.secondary.opacity(0.1))
                .frame(width: 250, height: 250)
                .blur(radius: 60)
                .offset(
                    x: animateBackground ? -80 : 80,
                    y: animateBackground ? 300 : 200
                )
        }
    }
}

// MARK: - Google Logo

struct GoogleLogo: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let radius = size / 2
                let innerRadius = radius * 0.55
                
                // Blue (right side)
                var bluePath = Path()
                bluePath.move(to: center)
                bluePath.addArc(center: center, radius: radius, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
                bluePath.closeSubpath()
                context.fill(bluePath, with: .color(Color(red: 66/255, green: 133/255, blue: 244/255)))
                
                // Green (bottom)
                var greenPath = Path()
                greenPath.move(to: center)
                greenPath.addArc(center: center, radius: radius, startAngle: .degrees(45), endAngle: .degrees(135), clockwise: false)
                greenPath.closeSubpath()
                context.fill(greenPath, with: .color(Color(red: 52/255, green: 168/255, blue: 83/255)))
                
                // Yellow (left bottom)
                var yellowPath = Path()
                yellowPath.move(to: center)
                yellowPath.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(225), clockwise: false)
                yellowPath.closeSubpath()
                context.fill(yellowPath, with: .color(Color(red: 251/255, green: 188/255, blue: 5/255)))
                
                // Red (top)
                var redPath = Path()
                redPath.move(to: center)
                redPath.addArc(center: center, radius: radius, startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)
                redPath.closeSubpath()
                context.fill(redPath, with: .color(Color(red: 234/255, green: 67/255, blue: 53/255)))
                
                // White center circle
                var whitePath = Path()
                whitePath.addArc(center: center, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.fill(whitePath, with: .color(.white))
                
                // Blue horizontal bar (the G opening)
                let barHeight = size * 0.16
                let barRect = CGRect(
                    x: center.x - size * 0.05,
                    y: center.y - barHeight / 2,
                    width: radius + size * 0.05,
                    height: barHeight
                )
                context.fill(Path(barRect), with: .color(Color(red: 66/255, green: 133/255, blue: 244/255)))
            }
        }
    }
}

#Preview {
    LoginView()
}

