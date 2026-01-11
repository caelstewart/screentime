//
//  HomeView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()
    @State private var selectedExercise: Exercise?
    @State private var showingBlockedApps = false
    
    // Direct reference to ScreenTimeManager to observe blocked state changes
    private var screenTimeManager: ScreenTimeManager { ScreenTimeManager.shared }
    
    // Animation states
    @State private var animateBalance = false
    
    // Track if user just earned bonus this session (don't show info banner immediately)
    @State private var justEarnedBonusThisSession = false
    
    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
            
            // Subtle top glow
            GeometryReader { proxy in
                Circle()
                    .fill(Theme.Colors.primary.opacity(0.1))
                    .frame(width: proxy.size.width * 1.5)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.25, y: -proxy.size.width * 0.5)
            }
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header Section
                    headerSection
                        .padding(.horizontal, 20)
                    
                    // Main Balance Card (with unlock button inside)
                    balanceCardCompact
                        .padding(.horizontal, 16)
                        .scaleEffect(animateBalance ? 1 : 0.95)
                        .opacity(animateBalance ? 1 : 0)
                        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: animateBalance)
                    
                    
// #if DEBUG
//                     debugToolsCard
//                         .padding(.horizontal, 16)
// #endif
                    
                    // Info banner explaining Apple limitation
                    // Only show after user has left and returned (not immediately after earning)
                    if ScreenTimeManager.shared.sharedBonusMinutes > 0 && !justEarnedBonusThisSession {
                        applePrivacyInfoBanner
                            .padding(.horizontal, 16)
                    }
                    
                    // Workout Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("START WORKOUT")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .tracking(2)
                            .padding(.leading, 20)
                        
                        VStack(spacing: 12) {
                            ForEach(Exercise.allDefault) { exercise in
                                ExerciseRow(exercise: exercise) {
                                    selectedExercise = exercise
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding(.top, 10)
            }
        }
        .fullScreenCover(item: $selectedExercise) { exercise in
            WorkoutContainerView(
                exercise: exercise,
                onComplete: { reps in
                    viewModel.completeWorkout(exercise: exercise, reps: reps, context: modelContext)
                    // Don't show the info banner right after earning bonus
                    justEarnedBonusThisSession = true
                    selectedExercise = nil
                },
                onDismiss: {
                    selectedExercise = nil
                }
            )
        }
        .sheet(isPresented: $showingBlockedApps) {
            BlockedAppsSheet()
        }
        .onAppear {
            let start = Date()
            viewModel.loadBalance(context: modelContext)
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "[HomeView] loadBalance took %.3fs", elapsed))
            withAnimation {
                animateBalance = true
            }
            print("[HomeView] UI animation triggered")
            print("[HomeView][UI] 📊 Blocked state: apps=\(screenTimeManager.blockedApps.count), cats=\(screenTimeManager.blockedCategories.count), shieldsActive=\(screenTimeManager.shieldsActive)")
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("[HomeView] 📱 Scene phase changed: \(oldPhase) → \(newPhase)")
            print("[HomeView][UI] 📊 Blocked state: apps=\(screenTimeManager.blockedApps.count), cats=\(screenTimeManager.blockedCategories.count), shieldsActive=\(screenTimeManager.shieldsActive)")
            if newPhase == .active {
                let activeLimits = viewModel.timeLimits.filter { $0.isActive }
                print("[HomeView] App became ACTIVE - checking bonus expiry with \(activeLimits.count) active limits")
                // Check if bonus time has expired (time-based fallback)
                ScreenTimeManager.shared.checkBonusExpiry(
                    limits: activeLimits,
                    context: modelContext
                )
                // Check if bonus was collapsed while app was backgrounded
                viewModel.refresh(context: modelContext)
                // Log again after refresh
                print("[HomeView][UI] 📊 After refresh: apps=\(screenTimeManager.blockedApps.count), cats=\(screenTimeManager.blockedCategories.count), shieldsActive=\(screenTimeManager.shieldsActive)")
            } else if newPhase == .background || newPhase == .inactive {
                // Reset flag so info banner shows on next app open
                justEarnedBonusThisSession = false
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentDateString.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.primary)
                    .tracking(1)
                
                Text("Daily Progress")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                // Blocked apps indicator (if any) - tappable to show list
                // Uses screenTimeManager directly for proper observation
                if screenTimeManager.shieldsActive {
                    Button {
                        showingBlockedApps = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                            Text("\(screenTimeManager.blockedApps.count + screenTimeManager.blockedCategories.count)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                
                // Streak Badge
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "FF9500"), Color(hex: "FF3B30")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Text("\(viewModel.currentStreak)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "1C1C1E"))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }
    
    private var balanceCardCompact: some View {
        let bonusMinutes = ScreenTimeManager.shared.sharedBonusMinutes
        
        return ZStack {
            // Glass Background
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(hex: "111827").opacity(0.8))
                .background(.ultraThinMaterial)
            
            // Content
            VStack(spacing: 0) {
                // Top Row
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bonusMinutes > 0 ? Theme.Colors.success : Theme.Colors.primary)
                            .frame(width: 6, height: 6)
                        Text(bonusMinutes > 0 ? "BONUS ACTIVE" : "TODAY")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .tracking(2)
                    }
                    Spacer()
                    
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.primary.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                // Big Number - shows bonus minutes earned (shared pool)
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if bonusMinutes > 0 {
                            Text("+")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.Colors.success.opacity(0.8))
                        }
                        Text("\(bonusMinutes)")
                            .font(.system(size: 72, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: bonusMinutes > 0 ? [.white, Theme.Colors.success] : [.white, Theme.Colors.textMuted],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .contentTransition(.numericText())
                            .shadow(color: (bonusMinutes > 0 ? Theme.Colors.success : Theme.Colors.primary).opacity(0.2), radius: 10)
                        
                        Text("min")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(bonusMinutes > 0 ? Theme.Colors.success.opacity(0.8) : Theme.Colors.textMuted)
                    }
                    
                    Text(bonusMinutes > 0 ? "added to your limits" : "do a workout to earn bonus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.vertical, 8)
                
                // Push-ups stats row
                HStack(spacing: 24) {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.primary)
                        Text("\(viewModel.totalPushUps)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("total")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    
                    Text("•")
                        .foregroundStyle(Theme.Colors.textMuted)
                    
                    HStack(spacing: 4) {
                        Text("\(viewModel.todayPushUps)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("today")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    
                    Text("•")
                        .foregroundStyle(Theme.Colors.textMuted)
                    
                    HStack(spacing: 4) {
                        Text("\(viewModel.thisWeekPushUps)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("week")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                }
                .padding(.bottom, 16)
                
                // Action Button - different states
                // Uses screenTimeManager directly for proper observation
                let blockedCount = screenTimeManager.blockedApps.count + screenTimeManager.blockedCategories.count
                if screenTimeManager.shieldsActive {
                    // Apps are blocked - tappable to show list
                    Button {
                        showingBlockedApps = true
                    } label: {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("\(blockedCount) app\(blockedCount == 1 ? "" : "s") blocked")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                            
                            Text("Tap to see blocked apps • Complete a workout to earn time")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .padding([.horizontal, .bottom], 16)
                } else if viewModel.isUnlocked {
                    // Legacy unlocked state
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Apps Unlocked")
                    }
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Theme.Colors.success.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding([.horizontal, .bottom], 16)
                } else if viewModel.activeLimitsCount > 0 {
                    // Has limits set, no apps blocked yet
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("\(viewModel.activeLimitsCount) limit\(viewModel.activeLimitsCount == 1 ? "" : "s") active")
                    }
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Theme.Colors.success.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding([.horizontal, .bottom], 16)
                } else {
                    // No limits set
                    Button(action: {
                        // Could navigate to settings
                    }) {
                        HStack {
                            Text("Set App Limits")
                            Image(systemName: "hourglass")
                        }
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .padding([.horizontal, .bottom], 16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(
                    LinearGradient(
                        colors: [
                            (viewModel.isUnlocked ? Theme.Colors.success : Theme.Colors.primary).opacity(0.3),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .animation(.spring(response: 0.4), value: viewModel.isUnlocked)
    }
    
    private var currentDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: Date())
    }
    
    // MARK: - Info Banners
    
    private var applePrivacyInfoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.Colors.primary.opacity(0.8))
            
            Text("This number won't update until a limit is reached due to Apple privacy restrictions. Keep using your apps and it will reset to 0 when any limit runs out.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Colors.cardBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
#if DEBUG
    private var debugToolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEV TOOLS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Colors.textMuted)
                .tracking(2)
            
            Text("Use these buttons to force a Screen Time shield for your currently selected apps and to clear any shields after testing.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                viewModel.runShieldSmokeTest(context: modelContext)
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill")
                    Text("DEV: Trigger Shield Smoke Test")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Color.black)
                .background(Theme.Colors.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            
            Button {
                viewModel.clearDebugShields()
            } label: {
                HStack {
                    Image(systemName: "lock.open")
                    Text("DEV: Clear All Shields")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(Theme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Theme.Colors.cardBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Theme.Colors.primary.opacity(0.15), lineWidth: 1)
                )
        )
    }
#endif
    
}

struct ExerciseRow: View {
    let exercise: Exercise
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(Theme.Colors.cardBackground)
                    
                    Image(systemName: exercise.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.primary)
                }
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 1))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.displayName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("\(exercise.minutesPerUnit) min / \(exercise.type.unitLabel)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textMuted.opacity(0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// Custom button style for scale effect
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Blocked Apps Sheet

struct BlockedAppsSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    // Direct reference for proper SwiftUI observation
    private var screenTimeManager: ScreenTimeManager { ScreenTimeManager.shared }
    
    private var blockedApps: [ApplicationToken] {
        Array(screenTimeManager.blockedApps)
    }
    
    private var blockedCategories: [ActivityCategoryToken] {
        Array(screenTimeManager.blockedCategories)
    }
    
    private var totalBlocked: Int {
        blockedApps.count + blockedCategories.count
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                
                if totalBlocked == 0 {
                    // No blocked apps
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(Theme.Colors.success)
                        
                        Text("No Apps Blocked")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Text("All your apps are currently accessible.")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Header info
                            VStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.red)
                                
                                Text("\(totalBlocked) app\(totalBlocked == 1 ? "" : "s") blocked")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                
                                Text("Complete a workout to earn more screen time")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                            
                            // Blocked Apps List
                            if !blockedApps.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("BLOCKED APPS")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Theme.Colors.textMuted)
                                        .tracking(1.5)
                                        .padding(.horizontal, 4)
                                    
                                    ForEach(Array(blockedApps.enumerated()), id: \.offset) { _, token in
                                        HStack(spacing: 14) {
                                            Label(token)
                                                .labelStyle(.iconOnly)
                                                .scaleEffect(1.8)
                                                .frame(width: 48, height: 48)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                            
                                            Label(token)
                                                .labelStyle(.titleOnly)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(.white)
                                            
                                            Spacer()
                                            
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.red.opacity(0.7))
                                        }
                                        .padding(12)
                                        .background(Theme.Colors.cardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                }
                            }
                            
                            // Blocked Categories List
                            if !blockedCategories.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("BLOCKED CATEGORIES")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Theme.Colors.textMuted)
                                        .tracking(1.5)
                                        .padding(.horizontal, 4)
                                    
                                    ForEach(Array(blockedCategories.enumerated()), id: \.offset) { _, token in
                                        HStack(spacing: 14) {
                                            Label(token)
                                                .labelStyle(.iconOnly)
                                                .scaleEffect(1.8)
                                                .frame(width: 48, height: 48)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                            
                                            Label(token)
                                                .labelStyle(.titleOnly)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(.white)
                                            
                                            Spacer()
                                            
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.red.opacity(0.7))
                                        }
                                        .padding(12)
                                        .background(Theme.Colors.cardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                }
                            }
                            
                            Spacer(minLength: 40)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationTitle("Blocked Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.primary)
                }
            }
        }
    }
}
