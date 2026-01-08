//
//  Theme.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI

// MARK: - App Theme

enum Theme {
    // MARK: - Colors
    
    enum Colors {
        // Backgrounds
        static let background = Color(hex: "05050A")
        static let backgroundSecondary = Color(hex: "0D1321")
        static let cardBackground = Color(hex: "111827")
        static let glassBackground = Color.black.opacity(0.4)
        
        // Primary accent - Neon Cyan (Restored)
        static let primary = Color(hex: "00F0FF")
        static let primaryDim = Color(hex: "00F0FF").opacity(0.3)
        
        // Secondary accent - Electric Purple
        static let secondary = Color(hex: "7C3AED")
        
        // Success/Reward colors
        static let success = Color(hex: "00FF94")
        static let reward = Color(hex: "FFD700")
        
        // Text
        static let textPrimary = Color.white
        static let textSecondary = Color(hex: "9CA3AF")
        static let textMuted = Color(hex: "6B7280")
        
        // Skeleton overlay - Restored to Cyan
        static let skeleton = Color(hex: "00F0FF") 
        static let jointDot = Color.white
        
        // Counter gradient (changes with rep count)
        static let counterLow = Color(hex: "3B82F6")      // Blue
        static let counterMid = Color(hex: "8B5CF6")      // Purple
        static let counterHigh = Color(hex: "FF3D00")     // Orange/Red
        
        // Card border glow
        static let cardBorder = Color(hex: "1E3A5F")
        static let cardGlow = Color(hex: "00D4FF").opacity(0.15)
    }
    
    // MARK: - Gradients
    
    enum Gradients {
        static let primaryButton = LinearGradient(
            colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")],
            startPoint: .leading,
            endPoint: .trailing
        )
        
        static let rewardButton = LinearGradient(
            colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")], // Changed to Blue
            startPoint: .leading,
            endPoint: .trailing
        )
        
        static let cardBorder = LinearGradient(
            colors: [Color(hex: "1E3A5F"), Color(hex: "1E3A5F").opacity(0.5)],
            startPoint: .top,
            endPoint: .bottom
        )
        
        static let backgroundGlow = RadialGradient(
            colors: [Color(hex: "0072FF").opacity(0.15), Color.clear],
            center: .top,
            startRadius: 0,
            endRadius: 600
        )
        
        static let workoutOverlay = LinearGradient(
            colors: [
                Color.black.opacity(0.6),
                Color.clear,
                Color.clear,
                Color.black.opacity(0.7)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        
        // New counter gradient
        static let counterText = LinearGradient(
            colors: [Color.white, Color(hex: "00F0FF")],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Typography
    
    enum Typography {
        // Large display numbers (rep counter)
        static func displayLarge() -> Font {
            .system(size: 80, weight: .heavy, design: .rounded)
        }
        
        // Medium display (countdown)
        static func displayMedium() -> Font {
            .system(size: 60, weight: .bold, design: .rounded)
        }
        
        // Screen time balance
        static func balance() -> Font {
            .system(size: 56, weight: .heavy, design: .rounded)
        }
        
        // Titles
        static func title() -> Font {
            .system(size: 32, weight: .bold, design: .rounded)
        }
        
        // Card titles
        static func cardTitle() -> Font {
            .system(size: 20, weight: .semibold, design: .rounded)
        }
        
        // Body text
        static func body() -> Font {
            .system(size: 17, weight: .regular, design: .rounded)
        }
        
        // Captions
        static func caption() -> Font {
            .system(size: 14, weight: .medium, design: .rounded)
        }
        
        // Small labels
        static func small() -> Font {
            .system(size: 12, weight: .medium, design: .rounded)
        }
    }
    
    // MARK: - Spacing
    
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    
    // MARK: - Corner Radius
    
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xl: CGFloat = 24
        static let full: CGFloat = 9999
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

    // MARK: - View Modifiers

    struct OnboardingBackground: View {
        var body: some View {
            // Match the Calculating view background exactly: starfield with 0.7 opacity
            StarfieldView()
                .opacity(0.7)
                .ignoresSafeArea()
        }
    }
    
    struct OnboardingStar: Identifiable {
        let id = UUID()
        let position: CGPoint
        let size: CGFloat
        var opacity: Double
        let twinkleDuration: Double
    }

struct GlassMorphism: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

extension View {
    func glass() -> some View {
        modifier(GlassMorphism())
    }
}
