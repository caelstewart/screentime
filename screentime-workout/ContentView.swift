//
//  ContentView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import SwiftData
import AVFoundation
import AVKit
import UIKit
import FamilyControls
import DeviceActivity
import AuthenticationServices
import SuperwallKit
import StoreKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager = AuthenticationManager.shared
    @State private var screenTimeManager = ScreenTimeManager.shared
    @State private var userDataManager = UserDataManager.shared
    @State private var showingAppSelection = false
    @State private var selectedAppCount = 0
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var isRestoringFromFirebase = false
    @State private var restoreStart: Date?
    @State private var hasAttemptedRestore = false
    
    private let onboardingDataManager = OnboardingDataManager.shared
    
    var body: some View {
        Group {
            if isRestoringFromFirebase {
                // Show loading while restoring from Firebase
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primary))
                            .scaleEffect(1.5)
                        Text("Restoring your progress...")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } else if authManager.isAuthenticated {
                // User is authenticated (either real account or anonymous)
                if hasCompletedOnboarding {
                    MainTabView(
                        showingAppSelection: $showingAppSelection,
                        selectedAppCount: $selectedAppCount
                    )
                    .id("main-\(authManager.user?.uid ?? "none")") // Force recreate on user change
                } else {
                    let _ = print("[ContentView] 🎯 Showing OnboardingFlowView - \(Date())")
                    OnboardingFlowView(isPreview: false) {
                        // Mark onboarding complete and sync to Firebase
                        onboardingDataManager.markOnboardingComplete()
                        hasCompletedOnboarding = true
                        AnalyticsManager.shared.startIfNeeded()
                        
                        // Sync all local data to Firebase
                        Task {
                            await userDataManager.syncLocalDataToFirebase(context: modelContext)
                        }
                    }
                }
            } else {
                // Not authenticated - show login view
                LoginView()
            }
        }
        .onAppear {
            let elapsed = Date().timeIntervalSince(AppLaunchMetrics.start)
            print(String(format: "[UI] ContentView appeared at %.2fs after launch", elapsed))
            if hasCompletedOnboarding {
                AnalyticsManager.shared.startIfNeeded()
            }
        }
        .onChange(of: hasCompletedOnboarding) { _, newValue in
            if newValue {
                AnalyticsManager.shared.startIfNeeded()
            }
        }
        // Show UI immediately; overlay a lightweight restore indicator without blocking
        .overlay {
            if isRestoringFromFirebase {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primary))
                            .scaleEffect(1.5)
                        Text("Restoring your progress...")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .allowsHitTesting(false) // Do not block interactions
                .transition(.opacity)
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            // Update state when UserDefaults changes
            hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated, let userId = authManager.user?.uid, !hasAttemptedRestore {
                hasAttemptedRestore = true
                
                // Only restore from Firebase if this is a real (non-anonymous) account
                // and onboarding isn't complete locally (new device scenario)
                if !authManager.isAnonymous && !hasCompletedOnboarding {
                    Task {
                        restoreStart = Date()
                        isRestoringFromFirebase = true
                        let restored = await userDataManager.restoreFromFirebase(context: modelContext)
                        if restored {
                            hasCompletedOnboarding = onboardingDataManager.hasCompletedOnboarding()
                        }
                        isRestoringFromFirebase = false
                        if let start = restoreStart {
                            let elapsed = Date().timeIntervalSince(start)
                            print(String(format: "[UI] Restore overlay dismissed in %.2fs", elapsed))
                        }
                    }
                }
                // NOTE: Removed unnecessary sync for returning users.
                // Firebase listeners automatically sync FROM Firebase.
                // We only sync TO Firebase after onboarding or account upgrade.
            }
        }
        .onChange(of: authManager.isAnonymous) { wasAnonymous, isAnonymous in
            // When user upgrades from anonymous to real account
            if wasAnonymous && !isAnonymous {
                Task {
                    let start = Date()
                    print("[UI] ⏱️ Sync (upgrade from anon) start")
                    await userDataManager.syncLocalDataToFirebase(context: modelContext)
                    let elapsed = Date().timeIntervalSince(start)
                    print(String(format: "[UI] ✅ Sync (upgrade from anon) completed in %.2fs", elapsed))
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("[ContentView] 📱 Scene phase: \(oldPhase) → \(newPhase)")
            if newPhase == .active && hasCompletedOnboarding {
                print("[ContentView] App became ACTIVE - checking bonus expiry")
                // Fetch limits from SwiftData and check bonus expiry
                let descriptor = FetchDescriptor<AppTimeLimit>()
                if let limits = try? modelContext.fetch(descriptor) {
                    let activeLimits = limits.filter { $0.isActive }
                    print("[ContentView] Fetched \(activeLimits.count) active limits for expiry check")
                    screenTimeManager.checkBonusExpiry(limits: activeLimits, context: modelContext)
                } else {
                    print("[ContentView] ⚠️ Failed to fetch limits for expiry check")
                }
            }
        }
    }
}

// MARK: - Main Tab View

enum Tab: Int {
    case home = 0
    case limits = 1
    case progress = 2
    case settings = 3
}

struct MainTabView: View {
    @Binding var showingAppSelection: Bool
    @Binding var selectedAppCount: Int
    @State private var selectedTab: Tab = .home
    
    init(showingAppSelection: Binding<Bool>, selectedAppCount: Binding<Int>) {
        self._showingAppSelection = showingAppSelection
        self._selectedAppCount = selectedAppCount
        
        // Configure tab bar with dark navy background matching theme
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = UIColor(Color(hex: "050509"))
        appearance.shadowColor = .clear // no separator line
        appearance.shadowImage = UIImage()
        appearance.backgroundImage = UIImage()
        
        // Style the items
        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor.gray
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.gray]
        itemAppearance.selected.iconColor = UIColor(Theme.Colors.primary)
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.Colors.primary)]
        
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.home)
            
            TimeLimitsTabView()
                .tabItem {
                    Label("Limits", systemImage: "hourglass")
                }
                .tag(Tab.limits)
            
            ProgressDashboardView()
                .tabItem {
                    Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(Tab.progress)
            
            SettingsView(
                showingAppSelection: $showingAppSelection,
                selectedAppCount: $selectedAppCount
            )
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .tint(Theme.Colors.primary)
        .onChange(of: selectedTab) { oldTab, newTab in
            print("[Tab] Switched from \(oldTab) to \(newTab)")
        }
    }
}

// MARK: - Time Limits Tab View (Full Page)

struct TimeLimitsTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppTimeLimit.createdAt, order: .reverse) private var timeLimits: [AppTimeLimit]
    @State private var screenTimeManager = ScreenTimeManager.shared
    @State private var showingCreateLimit = false
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        // Header
                        HStack {
                            Text("App Time Limits")
                                .font(Theme.Typography.title())
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                        }
                        .padding(.top, Theme.Spacing.lg)
                        
                        // Info header
                        infoHeader
                        
                        // Authorization check
                        if !screenTimeManager.isAuthorized {
                            authorizationCard
                        } else {
                            // Create new limit button
                            createLimitButton
                            
                            // Existing limits
                            if !timeLimits.isEmpty {
                                existingLimitsSection
                            } else {
                                emptyState
                            }
                        }
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }
            }
            .navigationDestination(for: AppTimeLimit.self) { limit in
                EditTimeLimitView(limit: limit) {
                    // Persist locally
                    do {
                        try modelContext.save()
                        print("[TimeLimitsTab] ✅ Saved to SwiftData: \(limit.displayName) = \(limit.dailyLimitMinutes) min, active: \(limit.isActive)")
                    } catch {
                        print("[TimeLimitsTab] ❌ SwiftData save failed: \(error)")
                    }
                    
                    // Persist to Firebase (primary)
                    Task {
                        await UserDataManager.shared.saveTimeLimitDirect(
                            id: limit.id.uuidString,
                            displayName: limit.displayName,
                            limitType: limit.limitTypeRaw,
                            dailyLimitMinutes: limit.dailyLimitMinutes,
                            bonusMinutesEarned: limit.bonusMinutesEarned,
                            isActive: limit.isActive,
                            scheduleStartHour: limit.scheduleStartHour,
                            scheduleStartMinute: limit.scheduleStartMinute,
                            scheduleEndHour: limit.scheduleEndHour,
                            scheduleEndMinute: limit.scheduleEndMinute,
                            scheduleDays: Array(limit.scheduleDays)
                        )
                        print("[TimeLimitsTab] ✅ Saved to Firebase: \(limit.displayName)")
                    }
                    
                    // Restart monitoring
                    screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
                } onDelete: {
                    deleteLimit(limit)
                }
            }
            .sheet(isPresented: $showingCreateLimit) {
                CreateTimeLimitSheet { newLimit in
                    modelContext.insert(newLimit)
                    try? modelContext.save()
                    screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
                    
                    // Also save to Firebase
                    Task {
                        await UserDataManager.shared.saveTimeLimitDirect(
                            id: newLimit.id.uuidString,
                            displayName: newLimit.displayName,
                            limitType: newLimit.limitTypeRaw,
                            dailyLimitMinutes: newLimit.dailyLimitMinutes,
                            bonusMinutesEarned: newLimit.bonusMinutesEarned,
                            isActive: newLimit.isActive,
                            scheduleStartHour: newLimit.scheduleStartHour,
                            scheduleStartMinute: newLimit.scheduleStartMinute,
                            scheduleEndHour: newLimit.scheduleEndHour,
                            scheduleEndMinute: newLimit.scheduleEndMinute,
                            scheduleDays: Array(newLimit.scheduleDays)
                        )
                        print("[TimeLimitsTab] ✅ Created limit saved to Firebase: \(newLimit.displayName)")
                    }
                }
            }
            .onAppear {
                print("[TimeLimitsTab] Tab appeared")
                let start = Date()
                // Sync any limits from Firebase that might not be in local DB
                syncLimitsFromFirebase()
                print(String(format: "[TimeLimitsTab] onAppear completed in %.3fs", Date().timeIntervalSince(start)))
            }
        }
    }
    
    /// Sync limits from Firebase to local SwiftData (restore missing data)
    private func syncLimitsFromFirebase() {
        let firebaseLimits = UserDataManager.shared.timeLimits
        
        guard !firebaseLimits.isEmpty else { return }
        
        var createdCount = 0
        let localIds = Set(timeLimits.map { $0.id.uuidString })
        
        for firebaseLimit in firebaseLimits {
            if !localIds.contains(firebaseLimit.id) {
                // Create missing limit from Firebase
                let limitType = LimitType(rawValue: firebaseLimit.limitType) ?? .dailyLimit
                let newLimit = AppTimeLimit(
                    id: UUID(uuidString: firebaseLimit.id) ?? UUID(),
                    displayName: firebaseLimit.displayName,
                    limitType: limitType,
                    dailyLimitMinutes: firebaseLimit.dailyLimitMinutes,
                    bonusMinutesEarned: firebaseLimit.bonusMinutesEarned,
                    isActive: firebaseLimit.isActive,
                    scheduleStartHour: firebaseLimit.scheduleStartHour ?? 22,
                    scheduleStartMinute: firebaseLimit.scheduleStartMinute ?? 0,
                    scheduleEndHour: firebaseLimit.scheduleEndHour ?? 6,
                    scheduleEndMinute: firebaseLimit.scheduleEndMinute ?? 0,
                    scheduleDays: Set(firebaseLimit.scheduleDays ?? [1, 2, 3, 4, 5, 6, 7])
                )
                modelContext.insert(newLimit)
                createdCount += 1
            }
        }
        
        if createdCount > 0 {
            try? modelContext.save()
            print("[TimeLimitsTab] Restored \(createdCount) limits from Firebase")
            screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
        }
    }
    
    // MARK: - Subviews
    
    private var infoHeader: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.primary)
            
            Text("Set daily time limits for apps. Once you hit your limit, the apps will be blocked until you earn more time through workouts.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                )
        )
    }
    
    private var authorizationCard: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "hourglass.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Colors.primary)
            
            Text("Screen Time Access Required")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            
            Text("Grant access to set time limits for apps")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
            
            Button {
                Task {
                    try? await screenTimeManager.requestAuthorization()
                }
            } label: {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("Grant Access")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.Colors.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .fill(Theme.Colors.cardBackground)
        )
    }
    
    private var createLimitButton: some View {
        Button {
            showingCreateLimit = true
        } label: {
            HStack {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.primary.opacity(0.1))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.Colors.primary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create New Limit")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    
                    Text("Block apps & categories")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .fill(Theme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.large)
                            .stroke(Theme.Colors.primary.opacity(0.3), lineWidth: 1)
                    )
            )
            .shadow(color: Theme.Colors.primary.opacity(0.05), radius: 10, x: 0, y: 5)
        }
    }
    
    private var existingLimitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACTIVE LIMITS")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Colors.textMuted)
                .tracking(1)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            
            ForEach(timeLimits) { limit in
                NavigationLink(value: limit) {
                    TimeLimitRowContent(limit: limit)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        deleteLimit(limit)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "hourglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Colors.textMuted)
            
            Text("No Limits Set")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            
            Text("Create a limit to start managing your app usage")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, Theme.Spacing.xxl)
    }
    
    // MARK: - Actions
    
    private func deleteLimit(_ limit: AppTimeLimit) {
        if let appToken = limit.getApplicationToken() {
            screenTimeManager.unshieldApp(appToken)
        } else if let categoryToken = limit.getCategoryToken() {
            screenTimeManager.unshieldCategory(categoryToken)
        }
        
        UserDefaults.standard.removeObject(forKey: "limit_selection_\(limit.id.uuidString)")
        
        modelContext.delete(limit)
        try? modelContext.save()
        screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
    }
}

// MARK: - Onboarding Authorization View

struct OnboardingAuthView: View {
    let onAuthorize: () -> Void
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: Theme.Spacing.xl) {
                Spacer()
                
                // App icon/illustration
                ZStack {
                    Circle()
                        .fill(Theme.Colors.primary.opacity(0.1))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.Colors.primary)
                }
                
                // Title
                VStack(spacing: Theme.Spacing.sm) {
                    Text("ScreenBlock")
                        .font(Theme.Typography.title())
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                
                // Description
                Text("Earn screen time by completing workouts. Stay fit while staying connected.")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
                
                Spacer()
                
                // Permission explanation
                VStack(spacing: Theme.Spacing.md) {
                    PermissionRow(
                        icon: "camera.fill",
                        title: "Camera Access",
                        description: "To track your exercises with pose detection"
                    )
                    
                    PermissionRow(
                        icon: "hourglass",
                        title: "Screen Time Access",
                        description: "To manage app blocking and rewards"
                    )
                }
                .padding(Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                        .fill(Theme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.large)
                                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                        )
                )
                .padding(.horizontal, Theme.Spacing.md)
                
                Spacer()
                
                // Authorize button
                if isLoading {
                    ProgressView()
                        .tint(Theme.Colors.primary)
                        .padding(.bottom, Theme.Spacing.xxl)
                } else {
                    GradientButton("Get Started", icon: "arrow.right") {
                        isLoading = true
                        onAuthorize()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xxl)
                }
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Theme.Colors.primary.opacity(0.15))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.cardTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                
                Text(description)
                    .font(Theme.Typography.small())
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            
            Spacer()
        }
    }
}

// MARK: - Settings Row Helper

struct SettingsRow: View {
    let icon: String
    let title: String
    var showChevron: Bool = true
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 28)
            
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.Colors.textPrimary)
            
            Spacer()
            
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Binding var showingAppSelection: Bool
    @Binding var selectedAppCount: Int
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppTimeLimit.createdAt, order: .reverse) private var timeLimits: [AppTimeLimit]
    @State private var authManager = AuthenticationManager.shared
    @State private var screenTimeManager = ScreenTimeManager.shared
    @State private var showSignOutAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showLoginPreview = false
    @State private var showOnboardingPreview = false
    @State private var isRestoringPurchases = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    /// Restart monitoring after bonus change to apply new thresholds
    private func restartMonitoringAfterBonusChange() {
        let descriptor = FetchDescriptor<AppTimeLimit>()
        guard let limits = try? modelContext.fetch(descriptor) else {
            print("[Debug] Failed to fetch limits for restart")
            return
        }
        let activeLimits = limits.filter { $0.isActive }
        print("[Debug] Restarting monitoring for \(activeLimits.count) limits with new bonus: \(screenTimeManager.sharedBonusMinutes)")
        screenTimeManager.startMonitoring(limits: activeLimits, context: modelContext)
    }
    
    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    // Header
                    HStack {
                        Text("Settings")
                            .font(Theme.Typography.title())
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Spacer()
                    }
                    .padding(.top, Theme.Spacing.lg)
                    
                    // Account Section
                    if authManager.isAuthenticated {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Account")
                                .font(Theme.Typography.cardTitle())
                                .foregroundStyle(Theme.Colors.textPrimary)
                            
                            if authManager.isAnonymous {
                                // Anonymous user - show upgrade options
                                VStack(spacing: Theme.Spacing.md) {
                                    HStack(spacing: Theme.Spacing.md) {
                                        ZStack {
                                            Circle()
                                                .fill(Theme.Colors.primary.opacity(0.2))
                                                .frame(width: 50, height: 50)
                                            
                                            Image(systemName: "person.fill.questionmark")
                                                .font(.system(size: 20))
                                                .foregroundStyle(Theme.Colors.primary)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Guest Account")
                                                .font(Theme.Typography.body())
                                                .foregroundStyle(Theme.Colors.textPrimary)
                                            
                                            Text("Sign in to backup your data")
                                                .font(Theme.Typography.small())
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                        }
                                        
                                        Spacer()
                                    }
                                    
                                    // Sign in buttons
                                    VStack(spacing: 10) {
                                        SignInWithAppleButton(.signIn) { request in
                                            authManager.handleAppleSignInRequest(request)
                                        } onCompletion: { result in
                                            Task {
                                                await authManager.handleAppleSignInCompletion(result)
                                            }
                                        }
                                        .signInWithAppleButtonStyle(.white)
                                        .frame(height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        
                                        Button {
                                            Task {
                                                try? await authManager.signInWithGoogle()
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                GoogleLogo()
                                                    .frame(width: 18, height: 18)
                                                Text("Sign in with Google")
                                                    .font(.system(size: 15, weight: .medium))
                                            }
                                            .foregroundStyle(.black)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 44)
                                            .background(.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }
                                    }
                                }
                                .padding(Theme.Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                                        .fill(Theme.Colors.cardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.large)
                                                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                                        )
                                )
                            } else {
                                // Real account - show profile
                                HStack(spacing: Theme.Spacing.md) {
                                    // Profile image or initial
                                    ZStack {
                                        Circle()
                                            .fill(Theme.Colors.primary.opacity(0.2))
                                            .frame(width: 50, height: 50)
                                        
                                        if let photoURL = authManager.photoURL {
                                            AsyncImage(url: photoURL) { image in
                                                image
                                                    .resizable()
                                                    .scaledToFill()
                                            } placeholder: {
                                                Text(String(authManager.displayName.prefix(1)).uppercased())
                                                    .font(.system(size: 20, weight: .bold))
                                                    .foregroundStyle(Theme.Colors.primary)
                                            }
                                            .frame(width: 50, height: 50)
                                            .clipShape(Circle())
                                        } else {
                                            Text(String(authManager.displayName.prefix(1)).uppercased())
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(Theme.Colors.primary)
                                        }
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(authManager.displayName)
                                            .font(Theme.Typography.body())
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                        
                                        Text(authManager.email)
                                            .font(Theme.Typography.small())
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                    
                                    Spacer()
                                    
                                    // Sync status indicator
                                    if UserDataManager.shared.isSyncing {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "checkmark.icloud.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(Theme.Colors.success)
                                    }
                                }
                                .padding(Theme.Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                                        .fill(Theme.Colors.cardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.large)
                                                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                    
                    // Screen Time Status
                    screenTimeStatusSection
                    
                    // Sign Out & Delete Account (only for non-anonymous users)
                    if authManager.isAuthenticated && !authManager.isAnonymous {
                        VStack(spacing: Theme.Spacing.sm) {
                            Button {
                                showSignOutAlert = true
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 14))
                                    Text("Sign Out")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(Theme.Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                                        .fill(Theme.Colors.cardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.large)
                                                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                                        )
                                )
                            }
                            
                            Button {
                                showDeleteAccountAlert = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14))
                                    Text("Delete Account")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(Theme.Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                                        .fill(.red.opacity(0.1))
                                )
                            }
                        }
                        .padding(.top, Theme.Spacing.md)
                    }
                    
                    // MARK: - Subscription Section
                    subscriptionSection
                    
                    // MARK: - Support Section
                    supportSection
                    
                    // MARK: - Legal Section
                    legalSection
                    
                    // MARK: - App Info Section
                    appInfoSection
                    
                    // Debug Section (only in debug builds)
                    #if DEBUG
                    VStack(spacing: Theme.Spacing.sm) {
                        Text("DEBUG")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Colors.textMuted)
                            .tracking(2)
                        
                        // Shield Management
                        Button {
                            screenTimeManager.removeAllShields()
                        } label: {
                            HStack {
                                Image(systemName: "shield.slash")
                                Text("Clear All Shields (Unblock Apps)")
                            }
                            .font(Theme.Typography.small())
                            .foregroundStyle(.red)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            // Delete ALL limits (local + Firebase)
                            Task {
                                print("[Debug] 🗑️ Deleting ALL time limits...")
                                
                                // Delete from Firebase first
                                await UserDataManager.shared.deleteAllTimeLimits()
                                
                                // Delete all from SwiftData
                                let descriptor = FetchDescriptor<AppTimeLimit>()
                                if let allLimits = try? modelContext.fetch(descriptor) {
                                    for limit in allLimits {
                                        // Remove saved selection
                                        UserDefaults.standard.removeObject(forKey: "limit_selection_\(limit.id.uuidString)")
                                        modelContext.delete(limit)
                                    }
                                    try? modelContext.save()
                                    print("[Debug] ✅ Deleted \(allLimits.count) local limits")
                                }
                                
                                // Stop monitoring
                                screenTimeManager.stopMonitoring()
                                screenTimeManager.removeAllShields()
                                
                                print("[Debug] ✅ All limits deleted!")
                            }
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("DELETE ALL LIMITS")
                            }
                            .font(Theme.Typography.small())
                            .foregroundStyle(.white)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            showOnboardingPreview = true
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Preview Onboarding")
                            }
                            .font(Theme.Typography.small())
                            .foregroundStyle(Theme.Colors.primary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Theme.Colors.primary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            showLoginPreview = true
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key")
                                Text("Preview Login Page")
                            }
                            .font(Theme.Typography.small())
                            .foregroundStyle(Theme.Colors.primary.opacity(0.7))
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Theme.Colors.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                            UserDefaults.standard.set(false, forKey: "skippedLogin")
                        } label: {
                            Text("Reset Onboarding")
                                .font(Theme.Typography.small())
                                .foregroundStyle(Theme.Colors.textMuted)
                        }
                        
                        Button {
                            SuperwallManager.shared.register(placement: "campaign_trigger")
                        } label: {
                            HStack {
                                Image(systemName: "creditcard")
                                Text("Test Paywall")
                            }
                            .font(Theme.Typography.small())
                            .foregroundStyle(.orange)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        // Screen Time Debug
                        Text("SCREEN TIME DEBUG")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Colors.textMuted)
                            .padding(.top, 12)
                        
                        HStack(spacing: 8) {
                            Button {
                                // Set bonus to 1 minute of USAGE (Pushscroll trick: 15m window, 1m threshold)
                                Task { @MainActor in
                                    let limits = timeLimits.filter { $0.isActive }
                                    ScreenTimeManager.shared.sharedBonusMinutes = 0
                                    ScreenTimeManager.shared.addBonusToPool(minutes: 1, limits: limits, context: modelContext)
                                }
                            } label: {
                                Text("+1m usage")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(.green.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            
                            Button {
                                // Set bonus to 5 minutes of USAGE
                                Task { @MainActor in
                                    let limits = timeLimits.filter { $0.isActive }
                                    ScreenTimeManager.shared.sharedBonusMinutes = 0
                                    ScreenTimeManager.shared.addBonusToPool(minutes: 5, limits: limits, context: modelContext)
                                }
                            } label: {
                                Text("+5m usage")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(.green.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            
                            Button {
                                // Reset bonus to 0 and restart monitoring
                                ScreenTimeManager.shared.sharedBonusMinutes = 0
                                restartMonitoringAfterBonusChange()
                            } label: {
                                Text("Reset")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(.red.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        
                        Button {
                            // View monitor logs
                            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.screentime-workout") {
                                print("[Debug] App Group container: \(containerURL.path)")
                                let logURL = containerURL.appendingPathComponent("monitor_log.txt")
                                if let logs = try? String(contentsOf: logURL, encoding: .utf8) {
                                    print("=== MONITOR LOGS ===")
                                    print(logs)
                                    print("=== END LOGS ===")
                                } else {
                                    print("[Debug] No monitor logs found at: \(logURL.path)")
                                }
                            } else {
                                print("[Debug] ❌ Cannot access App Group container!")
                            }
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("Print Monitor Logs")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.cyan.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            // Inspect shared UserDefaults
                            print("=== SHARED USERDEFAULTS INSPECTION ===")
                            if let defaults = UserDefaults(suiteName: "group.app.screentime-workout") {
                                print("[Debug] ✅ Shared UserDefaults accessible")
                                
                                // Print bonus info
                                let bonus = defaults.integer(forKey: "screentime.sharedBonusMinutes")
                                let expiry = defaults.object(forKey: "screentime.bonusExpiryDate") as? Date
                                print("[Debug] Bonus minutes: \(bonus)")
                                print("[Debug] Bonus expiry: \(expiry?.description ?? "nil")")
                                
                                // Look for saved tokens
                                let allKeys = defaults.dictionaryRepresentation().keys
                                let tokenKeys = allKeys.filter { $0.contains("blockedTokens") || $0.contains("blockedCategories") }
                                print("[Debug] Token keys found: \(tokenKeys.count)")
                                for key in tokenKeys {
                                    if let data = defaults.data(forKey: key) {
                                        print("[Debug]   \(key): \(data.count) bytes")
                                    }
                                }
                            } else {
                                print("[Debug] ❌ Cannot access shared UserDefaults!")
                            }
                            print("=== END INSPECTION ===")
                        } label: {
                            HStack {
                                Image(systemName: "gear.badge.questionmark")
                                Text("Inspect App Group Data")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            // Check bundle structure
                            print("=== BUNDLE STRUCTURE CHECK ===")
                            let mainBundle = Bundle.main
                            print("[Debug] Main bundle path: \(mainBundle.bundlePath)")
                            
                            // Check PlugIns folder
                            let pluginsPath = mainBundle.bundlePath + "/PlugIns"
                            print("[Debug] PlugIns path: \(pluginsPath)")
                            
                            if FileManager.default.fileExists(atPath: pluginsPath) {
                                print("[Debug] ✅ PlugIns folder EXISTS")
                                if let contents = try? FileManager.default.contentsOfDirectory(atPath: pluginsPath) {
                                    print("[Debug] PlugIns contents:")
                                    for item in contents {
                                        print("[Debug]   - \(item)")
                                        if item.contains("DeviceActivityMonitor") {
                                            print("[Debug]   ✅ DeviceActivityMonitor extension FOUND!")
                                        }
                                    }
                                }
                            } else {
                                print("[Debug] ❌ PlugIns folder NOT FOUND!")
                            }
                            print("=== END BUNDLE CHECK ===")
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.gearshape")
                                Text("Check Extension Bundle")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.yellow.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            // Write test log to verify App Group file access
                            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.screentime-workout") {
                                let logURL = containerURL.appendingPathComponent("monitor_log.txt")
                                let testLine = "[MAIN APP TEST] \(Date())\n"
                                
                                if FileManager.default.fileExists(atPath: logURL.path) {
                                    if let handle = try? FileHandle(forWritingTo: logURL) {
                                        handle.seekToEndOfFile()
                                        handle.write(testLine.data(using: .utf8) ?? Data())
                                        handle.closeFile()
                                        print("[Debug] ✅ Wrote test line to monitor_log.txt")
                                    }
                                } else {
                                    try? testLine.write(to: logURL, atomically: true, encoding: .utf8)
                                    print("[Debug] ✅ Created monitor_log.txt with test line")
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "pencil.line")
                                Text("Write Test Log")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.mint)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.mint.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Text("⚠️ DeviceActivity monitors CUMULATIVE daily usage. If you've already used IG for 5+ min today, a 1-min threshold won't fire because it's already passed.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        
                        HStack(spacing: 8) {
                            Button {
                                // Clear monitor logs
                                if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.screentime-workout") {
                                    let logURL = containerURL.appendingPathComponent("monitor_log.txt")
                                    try? FileManager.default.removeItem(at: logURL)
                                    print("[Debug] Monitor logs cleared")
                                }
                            } label: {
                                Text("Clear Logs")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.Colors.textMuted)
                            }
                            
                            Button {
                                // NUCLEAR: Clear ALL device activity monitors (fixes 20-limit)
                                let center = DeviceActivityCenter()
                                let activities = center.activities
                                print("[Debug] 🧹 Clearing \(activities.count) activities:")
                                for activity in activities {
                                    print("[Debug]   - \(activity.rawValue)")
                                }
                                center.stopMonitoring()
                                print("[Debug] ✅ All activities cleared!")
                            } label: {
                                Text("Clear Activities (\(DeviceActivityCenter().activities.count))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        
                        VStack(spacing: 4) {
                            Text("Current bonus: \(ScreenTimeManager.shared.sharedBonusMinutes) min")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.textMuted)
                            
                            if let expiry = ScreenTimeManager.shared.bonusExpiryDate {
                                let remaining = max(0, expiry.timeIntervalSince(Date()))
                                let mins = Int(remaining / 60)
                                let secs = Int(remaining.truncatingRemainder(dividingBy: 60))
                                Text("Expires in: \(mins)m \(secs)s")
                                    .font(.system(size: 11))
                                    .foregroundStyle(remaining > 0 ? Theme.Colors.success : .red)
                            }
                        }
                    }
                    .padding(.top, Theme.Spacing.xl)
                    #endif
                    
                    Spacer(minLength: 100)
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .onAppear {
            print("[SettingsView] Tab appeared")
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                authManager.signOut()
                UserDefaults.standard.set(false, forKey: "skippedLogin")
            }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Delete Account", isPresented: $showDeleteAccountAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await authManager.deleteAccount()
                        UserDefaults.standard.set(false, forKey: "skippedLogin")
                        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    } catch {
                        // Error is shown via authManager.errorMessage
                    }
                }
            }
        } message: {
            Text("This will permanently delete your account and all associated data. This action cannot be undone.")
        }
        .alert("Restore Purchases", isPresented: $showRestoreAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(restoreMessage)
        }
        .fullScreenCover(isPresented: $showLoginPreview) {
            ZStack(alignment: .topTrailing) {
                LoginView()
                
                // Close button
                Button {
                    showLoginPreview = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(20)
                }
            }
        }
        .fullScreenCover(isPresented: $showOnboardingPreview) {
            OnboardingFlowView(isPreview: true) {
                showOnboardingPreview = false
            }
        }
    }
    
    // MARK: - Subscription Section
    
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Subscription")
                .font(Theme.Typography.cardTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            
            VStack(spacing: 0) {
                // Restore Purchases
                Button {
                    Task {
                        isRestoringPurchases = true
                        do {
                            // Use StoreKit 2 to sync purchases with App Store
                            try await AppStore.sync()
                            restoreMessage = "Purchases restored successfully!"
                        } catch {
                            restoreMessage = "No purchases to restore"
                        }
                        isRestoringPurchases = false
                        showRestoreAlert = true
                    }
                } label: {
                    HStack {
                        SettingsRow(icon: "arrow.clockwise", title: "Restore Purchases", showChevron: false)
                        if isRestoringPurchases {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 16)
                        }
                    }
                }
                
                Divider()
                    .background(Theme.Colors.cardBorder)
                
                // Manage Subscription
                Button {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "creditcard", title: "Manage Subscription", showChevron: true)
                }
            }
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
        }
        .padding(.top, Theme.Spacing.lg)
    }
    
    // MARK: - Support Section
    
    private var supportSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Support")
                .font(Theme.Typography.cardTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            
            VStack(spacing: 0) {
                // Contact Support
                Button {
                    if let url = URL(string: "mailto:support@screenblock.app?subject=ScreenBlock%20Support") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "envelope", title: "Contact Support", showChevron: true)
                }
                
                Divider()
                    .background(Theme.Colors.cardBorder)
                
                // Rate App
                Button {
                    // Replace with your actual App Store ID when available
                    if let url = URL(string: "https://apps.apple.com/app/idYOUR_APP_ID?action=write-review") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "star", title: "Rate ScreenBlock", showChevron: true)
                }
                
                Divider()
                    .background(Theme.Colors.cardBorder)
                
                // Share App
                Button {
                    let url = URL(string: "https://apps.apple.com/app/idYOUR_APP_ID")!
                    let activityVC = UIActivityViewController(activityItems: [
                        "Check out ScreenBlock - earn screen time through workouts! 💪",
                        url
                    ], applicationActivities: nil)
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        rootVC.present(activityVC, animated: true)
                    }
                } label: {
                    SettingsRow(icon: "square.and.arrow.up", title: "Share ScreenBlock", showChevron: true)
                }
            }
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
        }
        .padding(.top, Theme.Spacing.lg)
    }
    
    // MARK: - Legal Section
    
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Legal")
                .font(Theme.Typography.cardTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            
            VStack(spacing: 0) {
                // Privacy Policy
                Button {
                    if let url = URL(string: "https://screenblock.app/privacy") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "hand.raised", title: "Privacy Policy", showChevron: true)
                }
                
                Divider()
                    .background(Theme.Colors.cardBorder)
                
                // Terms of Service
                Button {
                    if let url = URL(string: "https://screenblock.app/terms") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow(icon: "doc.text", title: "Terms of Service", showChevron: true)
                }
            }
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
        }
        .padding(.top, Theme.Spacing.lg)
    }
    
    // MARK: - App Info Section
    
    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("About")
                .font(Theme.Typography.cardTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            
            VStack(spacing: 0) {
                // Version
                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.primary)
                        .frame(width: 28)
                    
                    Text("Version")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    
                    Spacer()
                    
                    Text(appVersion)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
        }
        .padding(.top, Theme.Spacing.lg)
    }
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
    
    // MARK: - Screen Time Status Section
    
    private var screenTimeStatusSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Screen Time")
                .font(Theme.Typography.cardTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            
            HStack(spacing: Theme.Spacing.md) {
                // Status icon
                ZStack {
                    Circle()
                        .fill(screenTimeManager.isAuthorized ? Theme.Colors.success.opacity(0.15) : Theme.Colors.reward.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: screenTimeManager.isAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(screenTimeManager.isAuthorized ? Theme.Colors.success : Theme.Colors.reward)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(screenTimeManager.isAuthorized ? "Authorized" : "Not Authorized")
                        .font(Theme.Typography.body())
                        .foregroundStyle(Theme.Colors.textPrimary)
                    
                    Text(screenTimeManager.isAuthorized 
                         ? "App blocking is active" 
                         : "Tap to enable app blocking")
                        .font(Theme.Typography.small())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Spacer()
                
                if !screenTimeManager.isAuthorized {
                    Button {
                        Task {
                            try? await screenTimeManager.requestAuthorization()
                        }
                    } label: {
                        Text("Enable")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.Colors.primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .fill(Theme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.large)
                            .stroke(
                                screenTimeManager.isAuthorized ? Theme.Colors.success.opacity(0.3) : Theme.Colors.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
    }
}

// MARK: - Time Limit Row Content (for NavigationLink)

struct TimeLimitRowContent: View {
    let limit: AppTimeLimit
    
    private var savedSelection: FamilyActivitySelection? {
        guard let data = UserDefaults.standard.data(forKey: "limit_selection_\(limit.id.uuidString)") else {
            return nil
        }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }
    
    private var appCount: Int {
        if let selection = savedSelection {
            return selection.applicationTokens.count + selection.categoryTokens.count
        }
        return (limit.applicationTokenData != nil ? 1 : 0) + (limit.categoryTokenData != nil ? 1 : 0)
    }
    
    /// Format minutes into hours and minutes string
    private func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(mins)m"
        }
        return "\(minutes)m"
    }
    
    /// Calculate time until scheduled block starts or ends
    private var timeUntilScheduleChange: String? {
        guard limit.limitType == .scheduled else { return nil }
        
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTimeMinutes = currentHour * 60 + currentMinute
        
        let startTimeMinutes = limit.scheduleStartHour * 60 + limit.scheduleStartMinute
        let endTimeMinutes = limit.scheduleEndHour * 60 + limit.scheduleEndMinute
        
        if limit.isWithinScheduledTime {
            // Calculate time until block ends
            var minutesUntilEnd: Int
            if startTimeMinutes > endTimeMinutes {
                // Overnight schedule
                if currentTimeMinutes >= startTimeMinutes {
                    minutesUntilEnd = (24 * 60 - currentTimeMinutes) + endTimeMinutes
                } else {
                    minutesUntilEnd = endTimeMinutes - currentTimeMinutes
                }
            } else {
                minutesUntilEnd = endTimeMinutes - currentTimeMinutes
            }
            
            if minutesUntilEnd > 0 {
                return "Unblocks in \(formatDuration(minutesUntilEnd))"
            }
        } else {
            // Calculate time until block starts
            var minutesUntilStart: Int
            if currentTimeMinutes < startTimeMinutes {
                minutesUntilStart = startTimeMinutes - currentTimeMinutes
            } else {
                minutesUntilStart = (24 * 60 - currentTimeMinutes) + startTimeMinutes
            }
            
            if minutesUntilStart > 0 && minutesUntilStart < 24 * 60 {
                return "Blocks in \(formatDuration(minutesUntilStart))"
            }
        }
        
        return nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(limit.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                
                Spacer()
                
                // Active/Inactive indicator
                if !limit.isActive {
                    Text("Paused")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.Colors.textMuted)
                        .clipShape(Capsule())
                }
            }
            
            // Limit details based on type
            if limit.limitType == .scheduled {
                scheduledLimitContent
            } else {
                dailyLimitContent
            }
            
            // App icons
            if appCount > 0 {
                thumbnailView
            } else {
                Text("No apps selected")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.textMuted)
            }
        }
        .padding(16)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(limit.limitType == .scheduled && limit.isWithinScheduledTime 
                        ? Color.red.opacity(0.5) 
                        : Theme.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    // MARK: - Daily Limit Content
    
    private var dailyLimitContent: some View {
        HStack {
            Image(systemName: "hourglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.primary)
            
            Text("\(formatDuration(limit.dailyLimitMinutes)) daily limit")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            
            Spacer()
        }
    }
    
    // MARK: - Scheduled Limit Content
    
    private var scheduledLimitContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Schedule info
            HStack(spacing: 12) {
                // Time window
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.primary)
                    Text(limit.scheduleTimeString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                
                // Days
                Text(limit.scheduleDaysString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textMuted)
                
                Spacer()
            }
            
            // Status indicator with countdown
            HStack(spacing: 6) {
                Circle()
                    .fill(limit.isWithinScheduledTime ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                
                if limit.isWithinScheduledTime {
                    Text("Currently blocking")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                } else {
                    Text("Not active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
                
                if let countdown = timeUntilScheduleChange {
                    Text("•")
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(countdown)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Spacer()
            }
        }
    }
    
    private var thumbnailView: some View {
        let iconSize: CGFloat = 44
        let overlap: CGFloat = 32
        let badgeSize: CGFloat = 40
        
        return ZStack(alignment: .leading) {
            if let selection = savedSelection {
                let apps = Array(selection.applicationTokens)
                let categories = Array(selection.categoryTokens)
                let totalCount = apps.count + categories.count
                
                let showCounter = totalCount > 8
                let maxIcons = showCounter ? 7 : min(totalCount, 8)
                
                let displayApps = Array(apps.prefix(maxIcons))
                let displayCategories = Array(categories.prefix(max(0, maxIcons - displayApps.count)))
                let displayedCount = displayApps.count + displayCategories.count
                
                ForEach(Array(Array(displayApps).enumerated()), id: \.offset) { index, token in
                    Label(token)
                        .labelStyle(.iconOnly)
                        .scaleEffect(1.8)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .offset(x: CGFloat(index) * overlap)
                        .zIndex(Double(10 - index))
                }
                
                ForEach(Array(Array(displayCategories).enumerated()), id: \.offset) { index, token in
                    let position = displayApps.count + index
                    Label(token)
                        .labelStyle(.iconOnly)
                        .scaleEffect(1.8)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .offset(x: CGFloat(position) * overlap)
                        .zIndex(Double(10 - position))
                }
                
                if showCounter {
                    let remaining = totalCount - displayedCount
                    Text("+\(remaining)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: badgeSize, height: badgeSize)
                        .background(Theme.Colors.cardBorder)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .offset(x: CGFloat(displayedCount) * overlap)
                        .zIndex(0)
                }
            }
        }
        .frame(height: 44)
    }
}

// MARK: - Edit Time Limit View (Full Page)

struct EditTimeLimitView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var limit: AppTimeLimit
    let onSave: () -> Void
    let onDelete: () -> Void
    
    @State private var selectedMinutes: Int
    @State private var limitName: String
    @State private var selectedApps: FamilyActivitySelection
    @State private var showingAppPicker = false
    @State private var showingDeleteConfirmation = false
    
    private let presetMinutes = [15, 30, 45, 60, 90, 120]
    
    init(limit: AppTimeLimit, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.limit = limit
        self.onSave = onSave
        self.onDelete = onDelete
        self._selectedMinutes = State(initialValue: limit.dailyLimitMinutes)
        self._limitName = State(initialValue: limit.displayName)
        
        let initialSelection: FamilyActivitySelection
        if let data = UserDefaults.standard.data(forKey: "limit_selection_\(limit.id.uuidString)"),
           let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            initialSelection = decoded
        } else {
            initialSelection = FamilyActivitySelection()
        }
        self._selectedApps = State(initialValue: initialSelection)
    }
    
    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
                .onTapGesture {
                    hideKeyboard()
                }
            
            ScrollView {
                editContent
            }
            .contentShape(Rectangle())
            .onTapGesture {
                hideKeyboard()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Edit Limit")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    limit.dailyLimitMinutes = selectedMinutes
                    limit.displayName = limitName
                    saveSelection()
                    onSave()
                    dismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Theme.Colors.primary)
            }
        }
        .familyActivityPicker(
            isPresented: $showingAppPicker,
            selection: $selectedApps
        )
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    private var editContent: some View {
        VStack(spacing: 12) {
            nameSection
            minutesSection
            presetsSection
            sliderSection
            toggleSection
            appsEditorSection
            deleteSection
            Spacer(minLength: 24)
        }
    }
    
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("NAME")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Colors.textMuted)
                .tracking(1.5)
            
            TextField("Limit name", text: $limitName)
                .font(.system(size: 17))
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.lg)
    }

    private var minutesSection: some View {
        VStack(spacing: 8) {
            Text("\(selectedMinutes)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.primary)
            
            Text("minutes per day")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private var presetsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(presetMinutes, id: \.self) { minutes in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedMinutes = minutes
                    }
                } label: {
                    Text(formatMinutes(minutes))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selectedMinutes == minutes ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            selectedMinutes == minutes
                            ? Theme.Colors.primary
                            : Theme.Colors.cardBackground
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var sliderSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Slider(
                value: Binding(
                    get: { Double(selectedMinutes) },
                    set: { newValue in
                        let newMinutes = Int(newValue)
                        if newMinutes != selectedMinutes {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            selectedMinutes = newMinutes
                        }
                    }
                ),
                in: 0...180,
                step: 5
            )
            .tint(Theme.Colors.primary)
            
            HStack {
                Text("0 min")
                Spacer()
                Text("3 hrs")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.Colors.textMuted)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var toggleSection: some View {
        Toggle(isOn: $limit.isActive) {
            HStack {
                Image(systemName: limit.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(limit.isActive ? Theme.Colors.success : Theme.Colors.textMuted)
                Text("Limit Active")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primary))
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var appsEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPS & CATEGORIES")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Colors.textMuted)
                .tracking(1.5)
            
            if selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty {
                Text("No apps selected")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -14) {
                        ForEach(Array(Array(selectedApps.applicationTokens.prefix(6)).enumerated()), id: \.offset) { idx, token in
                            Label(token)
                                .labelStyle(.iconOnly)
                                .scaleEffect(1.8)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .zIndex(Double(100 - idx))
                        }
                        let remainingSlots = max(0, 6 - selectedApps.applicationTokens.count)
                        ForEach(Array(Array(selectedApps.categoryTokens.prefix(remainingSlots)).enumerated()), id: \.offset) { idx, token in
                            let position = selectedApps.applicationTokens.count + idx
                            Label(token)
                                .labelStyle(.iconOnly)
                                .scaleEffect(1.8)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .zIndex(Double(100 - position))
                        }
                        let total = selectedApps.applicationTokens.count + selectedApps.categoryTokens.count
                        if total > 6 {
                            Text("+\(total - 6)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(Theme.Colors.cardBorder)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            
            Button {
                showingAppPicker = true
            } label: {
                Text(selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty ? "Choose Apps" : "Edit Apps")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
    
    private var deleteSection: some View {
        Button {
            showingDeleteConfirmation = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete Limit")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .confirmationDialog("Delete this limit?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the time limit and unblock the associated apps.")
        }
    }
    
    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(mins)m"
        }
        return "\(minutes)m"
    }
    
    private func saveSelection() {
        if let firstApp = selectedApps.applicationTokens.first {
            limit.setApplicationToken(firstApp)
            limit.categoryTokenData = nil
        } else if let firstCategory = selectedApps.categoryTokens.first {
            limit.setCategoryToken(firstCategory)
            limit.applicationTokenData = nil
        } else {
            limit.applicationTokenData = nil
            limit.categoryTokenData = nil
        }
        
        if let data = try? PropertyListEncoder().encode(selectedApps) {
            UserDefaults.standard.set(data, forKey: "limit_selection_\(limit.id.uuidString)")
        } else {
            UserDefaults.standard.removeObject(forKey: "limit_selection_\(limit.id.uuidString)")
        }
    }
}

// MARK: - Onboarding Flow View (Behavioral Design Funnel)

/// Complete onboarding steps following PAS (Problem-Agitation-Solution) framework
enum OnboardingStep: Int, CaseIterable {
    // Phase 1: Hook & Personalization
    case hook = 0
    case nameInput
    case goalSelection
    
    // Phase 2: Usage Baseline
    case currentUsage
    case targetUsage
    
    // Phase 3: Root Cause Analysis
    case problemApps
    case whyHardToQuit
    
    // Phase 4: Emotional Agitation
    case emotionalImpact
    
    // Phase 5: Social Proof
    case socialProof
    
    // Phase 6: Dependency Assessment
    case ageQuestion
    case dependencyResult
    
    // Phase 7: Solution Audit
    case whatTried
    case whyOthersFail
    
    // Phase 8: Stakes
    case yearsLost
    case yearsGained
    
    // Phase 9: Education
    case scienceExplanation
    
    // Phase 10: Exercise Demo Flow
    case exerciseSelection      // Pick Push-ups or Squats
    case setupTutorial          // Phone placement photo
    case exerciseDemo           // Push-up instruction with demo video
    case detectionTips          // Tips for better detection (requests camera)
    case liveExerciseDemo       // Actually do the exercise with camera counting
    case exerciseFrequency      // How often do you exercise?
    
    // Phase 11: Final Setup & Permissions
    case finishSetup            // "[Name], let's finish setting up"
    case screenTimePermission   // Screen Time permission
    case selectDistractingApps  // Select your most distracting apps
    case notificationPermission // Allow notifications
    case notificationWarning    // Warning if denied
    
    // Phase 12: Social Proof & Conversion
    case giveRating             // "Give us a rating" with testimonials
    case joinLogin              // Login options + skip
    case calculating            // Animated calculating progress
    case journeyChart           // "Your journey starts now" with chart
    case benefitsSummary        // "You will feel differences by..."
    
    // Phase 13: Paywall
    case paywall                // Trial offer
    case success                // Welcome to the app
    
    var progress: Double {
        Double(rawValue + 1) / Double(OnboardingStep.allCases.count)
    }
}

struct OnboardingFlowView: View {
    let isPreview: Bool
    let onComplete: () -> Void
    
    @State private var currentStep: OnboardingStep = .hook
    @State private var screenTimeManager = ScreenTimeManager.shared
    private let dataManager = OnboardingDataManager.shared
    
    // User data collected during onboarding
    @State private var userName: String = ""
    @State private var selectedGoals: Set<String> = []
    @State private var currentUsageHours: Double = 4
    @State private var targetUsageHours: Double = 2
    @State private var selectedApps: Set<String> = []
    @State private var selectedReasons: Set<String> = []
    @State private var selectedFeelings: Set<String> = []
    @State private var selectedAge: String = ""
    @State private var selectedPreviousSolutions: Set<String> = []
    @State private var yearsLostAnimated: Int = 0
    @State private var yearsGainedAnimated: Int = 0
    @State private var selectedExercise: String = ""
    @State private var exerciseFrequency: String = ""
    @State private var notificationsDenied: Bool = false
    @State private var calculatingProgress: Double = 0
    @State private var showingAppPicker: Bool = false
    @State private var onboardingRepsCompleted: Int = 0
    @State private var hasLoadedSavedState: Bool = false
    
    @State private var highestStepReached: OnboardingStep = .hook
    @GestureState private var dragOffset: CGFloat = 0
    
    // Debounce: track last step change to prevent rapid-fire navigation
    @State private var lastStepChangeTime: Date = .distantPast
    // Track when step changed for render timing measurement
    @State private var stepChangeTimestamp: Date = .distantPast
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Progress bar
                HStack {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)
                            
                            Capsule()
                                .fill(Color.white)
                                .frame(width: geo.size.width * currentStep.progress, height: 4)
                                .animation(.spring(response: 0.4), value: currentStep)
                        }
                    }
                    .frame(height: 4)
                    
                    if isPreview {
                        Button {
                            onComplete()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 32, height: 32)
                        }
                        .padding(.leading, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                // Content - Custom paging without forward swipe
                ZStack {
                    currentStepView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: dragOffset)
                // Disable drag gesture on steps with text input to prevent interference
                .gesture(
                    currentStep == .nameInput ? nil :
                    DragGesture(minimumDistance: 30)
                        .updating($dragOffset) { value, state, _ in
                            // Only allow backward drag (swipe right = positive translation = go back)
                            if value.translation.width > 0 && currentStep.rawValue > 0 {
                                state = value.translation.width * 0.3
                            }
                        }
                        .onEnded { value in
                            // Go back if swiped right far enough
                            if value.translation.width > 80 && currentStep.rawValue > 0 {
                                previousStep()
                            }
                        }
                )
            }
        }
        .onAppear {
            let appearStart = Date()
            if !hasLoadedSavedState {
                loadSavedState()
            }
            let loadElapsed = Date().timeIntervalSince(appearStart)
            if loadElapsed > 0.05 {
                print(String(format: "[Onboarding] loadSavedState took %.3fs", loadElapsed))
            }
            
            // NOTE: Superwall pre-warming removed from onboarding start
            // WKWebView processes take 10+ seconds to launch and block main thread
            // Pre-warm will happen when user reaches paywall step or visits settings
            print("[Onboarding] OnboardingFlowView appeared (Superwall preWarm skipped for performance)")
            
            // Pause Firebase listeners during onboarding - they fire on main thread
            // and can cause multi-second stalls during network reconnection events
            UserDataManager.shared.pauseListeners()
            
            MainThreadStallMonitor.shared.start(label: "Onboarding")
        }
        .onDisappear {
            MainThreadStallMonitor.shared.stop()
            
            // Resume Firebase listeners when leaving onboarding
            UserDataManager.shared.resumeListeners()
        }
        .onChange(of: userName) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedGoals) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: currentUsageHours) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: targetUsageHours) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedApps) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedReasons) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedFeelings) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedAge) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedPreviousSolutions) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: selectedExercise) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
        .onChange(of: exerciseFrequency) { _, _ in if hasLoadedSavedState { saveOnboardingState() } }
    }
    
    @ViewBuilder
    private var currentStepView: some View {
        switch currentStep {
        case .hook:
            OnboardingHookView(onContinue: { nextStep() })
        case .nameInput:
            OnboardingNameView(userName: $userName, onContinue: { nextStep() })
                .onAppear {
                    let renderDelay = Date().timeIntervalSince(stepChangeTimestamp)
                    print(String(format: "[Onboarding] ✅ OnboardingNameView APPEARED - %.3fs after step change", renderDelay))
                }
        case .goalSelection:
            OnboardingGoalsView(selectedGoals: $selectedGoals, userName: userName, onContinue: { nextStep() })
                .onAppear {
                    let delay = Date().timeIntervalSince(stepChangeTimestamp)
                    print(String(format: "[Onboarding] ✅ GoalsView APPEARED - %.3fs after step change", delay))
                }
        case .currentUsage:
            OnboardingCurrentUsageView(hours: $currentUsageHours, onContinue: { nextStep() })
                .onAppear {
                    let delay = Date().timeIntervalSince(stepChangeTimestamp)
                    print(String(format: "[Onboarding] ✅ CurrentUsageView APPEARED - %.3fs after step change", delay))
                }
        case .targetUsage:
            OnboardingTargetUsageView(currentHours: currentUsageHours, targetHours: $targetUsageHours, userName: userName, onContinue: { nextStep() })
                .onAppear {
                    let delay = Date().timeIntervalSince(stepChangeTimestamp)
                    print(String(format: "[Onboarding] ✅ TargetUsageView APPEARED - %.3fs after step change", delay))
                }
        case .problemApps:
            OnboardingProblemAppsView(selectedApps: $selectedApps, onContinue: { nextStep() })
                .onAppear {
                    let delay = Date().timeIntervalSince(stepChangeTimestamp)
                    print(String(format: "[Onboarding] ✅ ProblemAppsView APPEARED - %.3fs after step change", delay))
                }
        case .whyHardToQuit:
            OnboardingWhyHardView(selectedReasons: $selectedReasons, selectedApps: selectedApps, onContinue: { nextStep() })
        case .emotionalImpact:
            OnboardingEmotionalImpactView(selectedFeelings: $selectedFeelings, onContinue: { nextStep() })
        case .socialProof:
            OnboardingSocialProofView(onContinue: { nextStep() })
        case .ageQuestion:
            OnboardingAgeView(selectedAge: $selectedAge, onContinue: { nextStep() })
        case .dependencyResult:
            OnboardingDependencyResultView(currentHours: currentUsageHours, onContinue: { nextStep() })
        case .whatTried:
            OnboardingWhatTriedView(selectedSolutions: $selectedPreviousSolutions, selectedFeelings: selectedFeelings, onContinue: { nextStep() })
        case .whyOthersFail:
            OnboardingWhyOthersFailView(previousSolutions: selectedPreviousSolutions, onContinue: { nextStep() })
        case .yearsLost:
            OnboardingYearsLostView(dailyHours: currentUsageHours, yearsAnimated: $yearsLostAnimated, onContinue: { nextStep() })
        case .yearsGained:
            OnboardingYearsGainedView(yearsLost: yearsLostAnimated, yearsGained: $yearsGainedAnimated, onContinue: { nextStep() })
        case .scienceExplanation:
            OnboardingScienceView(onContinue: { nextStep() })
        case .exerciseSelection:
            OnboardingExercisePickerView(selectedExercise: $selectedExercise, onContinue: { nextStep() }, onSkip: { skipToFinish() })
        case .setupTutorial:
            OnboardingSetupTutorialView(onContinue: { nextStep() })
        case .exerciseDemo:
            OnboardingExerciseDemoView(exercise: selectedExercise, onContinue: { nextStep() })
        case .detectionTips:
            OnboardingDetectionTipsView(onContinue: { requestCameraAndContinue() })
        case .liveExerciseDemo:
            OnboardingLiveExerciseView(
                exercise: selectedExercise,
                onComplete: { reps in
                    onboardingRepsCompleted = reps
                    nextStep()
                },
                onSkip: { nextStep() }
            )
        case .exerciseFrequency:
            OnboardingExerciseFrequencyView(selectedFrequency: $exerciseFrequency, onContinue: { nextStep() })
        case .finishSetup:
            OnboardingFinishSetupView(userName: userName, onContinue: { nextStep() })
        case .screenTimePermission:
            OnboardingScreenTimeView(userName: userName, isPreview: isPreview, onComplete: { nextStep() })
        case .selectDistractingApps:
            OnboardingSelectAppsView(showingPicker: $showingAppPicker, onContinue: { nextStep() })
        case .notificationPermission:
            OnboardingNotificationView(onContinue: { granted in
                notificationsDenied = !granted
                if granted {
                    goToStep(.giveRating)
                } else {
                    nextStep()
                }
            })
        case .notificationWarning:
            OnboardingNotificationWarningView(onOpenSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }, onContinue: { nextStep() })
        case .giveRating:
            OnboardingRatingView(onContinue: { nextStep() })
        case .joinLogin:
            OnboardingJoinView(onLogin: { nextStep() }, onSkip: { nextStep() })
        case .calculating:
            OnboardingCalculatingView(progress: $calculatingProgress, onComplete: { nextStep() })
        case .journeyChart:
            OnboardingJourneyChartView(currentHours: currentUsageHours, targetHours: targetUsageHours, exerciseFrequency: exerciseFrequency, onContinue: { nextStep() })
        case .benefitsSummary:
            OnboardingBenefitsSummaryView(currentHours: currentUsageHours, targetHours: targetUsageHours, exerciseFrequency: exerciseFrequency, onContinue: { goToSuccess() })
        case .paywall:
            OnboardingPaywallView(onContinue: { nextStep() }, onRestore: { nextStep() })
        case .success:
            OnboardingSuccessView(userName: userName, isPreview: isPreview, onComplete: onComplete)
        }
    }
    
    private func skipToFinish() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = .exerciseFrequency
        }
    }
    
    private func goToStep(_ step: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }
    }
    
    private func requestCameraAndContinue() {
        Task {
            _ = await CameraManager.requestPermission()
            await MainActor.run {
                nextStep()
            }
        }
    }
    
    private func nextStep() {
        let now = Date()
        
        // Debounce: prevent rapid-fire step changes (e.g., from queued gestures during UI freeze)
        let timeSinceLastChange = now.timeIntervalSince(lastStepChangeTime)
        guard timeSinceLastChange > 0.3 else {
            print("[Onboarding] ⚠️ nextStep() DEBOUNCED - only \(String(format: "%.3fs", timeSinceLastChange)) since last change")
            return
        }
        
        print("[Onboarding] >>> nextStep() ENTER - \(Date())")
        let stepStart = Date()
        
        print("[Onboarding]   1. Resigning first responder...")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        print(String(format: "[Onboarding]   1. Done (%.3fs)", Date().timeIntervalSince(stepStart)))
        
        let allSteps = OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: currentStep),
           currentIndex < allSteps.count - 1 {
            let oldStep = currentStep
            
            // Mark the change time BEFORE updating state
            lastStepChangeTime = now
            stepChangeTimestamp = now
            
            print("[Onboarding]   2. Updating step state... (timestamp set for render tracking)")
            let animStart = Date()
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = allSteps[currentIndex + 1]
                if currentStep.rawValue > highestStepReached.rawValue {
                    highestStepReached = currentStep
                }
            }
            print(String(format: "[Onboarding]   2. Step updated (%.3fs)", Date().timeIntervalSince(animStart)))
            
            // Save progress
            print("[Onboarding]   3. Saving state...")
            let saveStart = Date()
            saveOnboardingState()
            print(String(format: "[Onboarding]   3. State saved (%.3fs)", Date().timeIntervalSince(saveStart)))
            
            let elapsed = Date().timeIntervalSince(stepStart)
            print(String(format: "[Onboarding] <<< nextStep() EXIT - total %.3fs (%@ → %@)", elapsed, String(describing: oldStep), String(describing: currentStep)))
        } else {
            print("[Onboarding] <<< nextStep() EXIT - no step change")
        }
    }
    
    private func goToSuccess() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = .success
            highestStepReached = .success
        }
        saveOnboardingState()
    }
    
    private func previousStep() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let allSteps = OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: currentStep),
           currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = allSteps[currentIndex - 1]
            }
        }
    }
    
    // MARK: - Persistence
    
    private func loadSavedState() {
        guard !isPreview else { return }
        
        let savedStep = dataManager.loadCurrentStep()
        if savedStep > 0, let step = OnboardingStep(rawValue: savedStep) {
            currentStep = step
            highestStepReached = step
        }
        
        userName = dataManager.loadUserName()
        selectedGoals = dataManager.loadSelectedGoals()
        currentUsageHours = dataManager.loadCurrentUsageHours()
        targetUsageHours = dataManager.loadTargetUsageHours()
        selectedApps = dataManager.loadSelectedApps()
        selectedReasons = dataManager.loadSelectedReasons()
        selectedFeelings = dataManager.loadSelectedFeelings()
        selectedAge = dataManager.loadSelectedAge()
        selectedPreviousSolutions = dataManager.loadSelectedPreviousSolutions()
        selectedExercise = dataManager.loadSelectedExercise()
        exerciseFrequency = dataManager.loadExerciseFrequency()
        notificationsDenied = dataManager.loadNotificationsDenied()
        onboardingRepsCompleted = dataManager.loadOnboardingRepsCompleted()
        
        hasLoadedSavedState = true
        print("[Onboarding] Restored state - step: \(currentStep), userName: \(userName)")
    }
    
    private func saveOnboardingState() {
        guard !isPreview else { return }
        
        // Save all values to UserDefaults (fast, local-only)
        dataManager.saveCurrentStep(currentStep.rawValue)
        dataManager.saveUserName(userName)
        dataManager.saveSelectedGoals(selectedGoals)
        dataManager.saveCurrentUsageHours(currentUsageHours)
        dataManager.saveTargetUsageHours(targetUsageHours)
        dataManager.saveSelectedApps(selectedApps)
        dataManager.saveSelectedReasons(selectedReasons)
        dataManager.saveSelectedFeelings(selectedFeelings)
        dataManager.saveSelectedAge(selectedAge)
        dataManager.saveSelectedPreviousSolutions(selectedPreviousSolutions)
        dataManager.saveSelectedExercise(selectedExercise)
        dataManager.saveExerciseFrequency(exerciseFrequency)
        dataManager.saveNotificationsDenied(notificationsDenied)
        dataManager.saveOnboardingRepsCompleted(onboardingRepsCompleted)
        
        // Schedule a single debounced Firebase sync (instead of 14 separate syncs)
        dataManager.scheduleDebouncedSync()
        
        print("[Onboarding] Saved state - step: \(currentStep)")
    }
}

// MARK: - Onboarding Views

// Reusable Continue Button
struct OnboardingContinueButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    
    // Debounce state to prevent rapid-fire taps during UI freezes
    @State private var isProcessing = false
    @State private var lastTapTime: Date = .distantPast
    
    init(_ title: String = "Continue", isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
    
    var body: some View {
        Button {
            // Debounce: ignore taps within 500ms of each other
            let now = Date()
            guard now.timeIntervalSince(lastTapTime) > 0.5 else {
                print("[Onboarding] ⚠️ DEBOUNCED tap on '\(title)' (too fast)")
                return
            }
            
            // Prevent re-entry while processing
            guard !isProcessing else {
                print("[Onboarding] ⚠️ BLOCKED tap on '\(title)' (still processing)")
                return
            }
            
            lastTapTime = now
            isProcessing = true
            
            print("[Onboarding] 📱 BUTTON TAP DETECTED: '\(title)' at \(Date())")
            let tapStart = Date()
            action()
            let elapsed = Date().timeIntervalSince(tapStart)
            print(String(format: "[Onboarding] 📱 BUTTON ACTION COMPLETE: '\(title)' took %.3fs", elapsed))
            
            // Reset after a short delay to allow next tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isProcessing = false
            }
        } label: {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(isEnabled && !isProcessing ? .white : Color.white.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!isEnabled || isProcessing)
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}

// MARK: - Starfield View

struct StarfieldView: View {
    @State private var stars: [Star] = []
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Deep space gradient
                RadialGradient(
                    colors: [Color(hex: "0A1033"), .black],
                    center: .center,
                    startRadius: 100,
                    endRadius: 500
                )
                .ignoresSafeArea()
                
                ForEach(stars) { star in
                    Circle()
                        .fill(Color.white)
                        .frame(width: star.size, height: star.size)
                        .position(star.position)
                        .opacity(star.opacity)
                        .animation(
                            .easeInOut(duration: star.twinkleDuration)
                            .repeatForever(autoreverses: true),
                            value: star.opacity
                        )
                }
            }
            .onAppear {
                createStars(in: geometry.size)
            }
        }
    }
    
    private func createStars(in size: CGSize) {
        for _ in 0..<100 {
            stars.append(Star(
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: CGFloat.random(in: 0...size.height)
                ),
                size: CGFloat.random(in: 1...3),
                opacity: Double.random(in: 0.3...0.8),
                twinkleDuration: Double.random(in: 1.0...3.0)
            ))
        }
    }
}

struct Star: Identifiable {
    let id = UUID()
    let position: CGPoint
    let size: CGFloat
    var opacity: Double
    let twinkleDuration: Double
}

// MARK: - Phase 1: Hook

struct OnboardingHookView: View {
    let onContinue: () -> Void
    
    @State private var showVisuals = false
    @State private var showContent = false
    @State private var pulseGlow = false
    @State private var phoneShake = false
    @State private var dumbbellBounce = false
    
    var body: some View {
        ZStack {
            // Standard App Background
            OnboardingBackground()
            
            // Enhanced atmospheric glow behind the hero visual
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.Colors.primary.opacity(pulseGlow ? 0.3 : 0.15), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: pulseGlow ? 220 : 180
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 50)
                .offset(y: -100)
            
            VStack(spacing: 0) {
                Spacer()
                
                // --- Hero Transformation Visual ---
                HStack(spacing: 24) {
                    // Left: Doomscrolling (Phone)
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .frame(width: 100, height: 100)
                            
                            Image(systemName: "iphone")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.5))
                            
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.3))
                                .offset(x: 10, y: 10)
                                .offset(y: phoneShake ? -3 : 3)
                        }
                        .rotationEffect(.degrees(phoneShake ? -2 : 2))
                        
                        Text("Doomscroll")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            // Subtle strikethrough only on label, not title
                            .strikethrough(color: .white.opacity(0.3))
                    }
                    .offset(x: showVisuals ? 0 : -20)
                    .opacity(showVisuals ? 1 : 0)
                    
                    // Middle: Arrow
                    Image(systemName: "arrow.right")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.Colors.primary)
                        .opacity(showVisuals ? 1 : 0)
                        .scaleEffect(showVisuals ? 1 : 0.5)
                        .padding(.horizontal, 8)
                    
                    // Right: Gains (Dumbbell)
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.primary.opacity(0.1))
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Circle()
                                        .stroke(Theme.Colors.primary.opacity(0.3), lineWidth: 1)
                                )
                            
                            Image(systemName: "dumbbell.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Theme.Colors.primary)
                                .shadow(color: Theme.Colors.primary.opacity(0.6), radius: 15)
                                .scaleEffect(dumbbellBounce ? 1.1 : 1.0)
                        }
                        
                        Text("Gains")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.Colors.primary)
                    }
                    .offset(x: showVisuals ? 0 : 20)
                    .opacity(showVisuals ? 1 : 0)
                }
                .padding(.bottom, 50)
                
                Spacer()
                
                // --- Main Copy ---
                VStack(spacing: 12) {
                    // Combined headline for better flow
                    Text("Trade Doomscrolling")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        Text("for")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                        
                        Text("Gains")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(Theme.Colors.primary)
                            .shadow(color: Theme.Colors.primary.opacity(0.5), radius: 8)
                    }
                    
                    Text("Do push-ups to unlock your apps.\nGet fit while you break the habit.")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                        .lineSpacing(4)
                }
                .offset(y: showContent ? 0 : 20)
                .opacity(showContent ? 1 : 0)
                
                Spacer()
                Spacer()
                
                // CTA
                OnboardingContinueButton("Let's Go", action: {
                    print("[Onboarding] 🚀 LET'S GO BUTTON PRESSED - \(Date())")
                    let buttonStart = Date()
                    onContinue()
                    let elapsed = Date().timeIntervalSince(buttonStart)
                    print(String(format: "[Onboarding] ✅ LET'S GO onContinue() completed in %.3fs", elapsed))
                })
                    .opacity(showContent ? 1 : 0)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            print("[Onboarding] 🎬 OnboardingHookView appeared - \(Date())")
            
            // Entrance animations
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) {
                showVisuals = true
            }
            
            withAnimation(.easeOut(duration: 0.8).delay(0.6)) {
                showContent = true
            }
            
            // Continuous animations
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                pulseGlow = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(0.5)) {
                phoneShake = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5, blendDuration: 1.0).repeatForever(autoreverses: true).delay(1.0)) {
                dumbbellBounce = true
            }
        }
    }
}

// MARK: - Phase 1: Name Input

struct OnboardingNameView: View {
    @Binding var userName: String
    let onContinue: () -> Void
    
    // Use local state to prevent parent re-renders on every keystroke
    @State private var localName: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Simple solid background - avoid expensive gradients during text input
            Theme.Colors.background
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 24) {
                    Text("First things first,")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Text("What should we call you?")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    
                    // TextField with local state for smooth typing
                    TextField("Your name", text: $localName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 16)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            syncAndContinue()
                        }
                }
                
                Spacer()
                Spacer()
                
                OnboardingContinueButton(isEnabled: !localName.isEmpty, action: {
                    syncAndContinue()
                })
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isTextFieldFocused = false
            }
        }
        .onAppear {
            localName = userName
            // Delay keyboard focus significantly to avoid contributing to stalls
            // User can tap to focus if they want it sooner
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: userName) { newValue in
            // Keep local copy aligned if user navigates back
            if newValue != localName {
                localName = newValue
            }
        }
    }
    
    @MainActor
    private func syncAndContinue() {
        guard !localName.isEmpty else { return }
        isTextFieldFocused = false
        userName = localName
        onContinue()
    }
}

// MARK: - Phase 1: Goal Selection

struct OnboardingGoalsView: View {
    @Binding var selectedGoals: Set<String>
    let userName: String
    let onContinue: () -> Void
    
    private let goals = [
        ("📱", "Reduce Screen Time"),
        ("🌙", "Quit late-night scrolling"),
        ("💪", "Build self-control"),
        ("📚", "Better focus for work/study"),
        ("😴", "Improve sleep quality"),
        ("🧘", "Mental clarity")
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("So, tell us \(userName.isEmpty ? "" : userName),")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("What goals do you want to achieve?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                Text("Select up to 3")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(goals, id: \.1) { emoji, title in
                        SelectableRowButton(
                            emoji: emoji,
                            title: title,
                            isSelected: selectedGoals.contains(title)
                        ) {
                            if selectedGoals.contains(title) {
                                selectedGoals.remove(title)
                            } else if selectedGoals.count < 3 {
                                selectedGoals.insert(title)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            
            OnboardingContinueButton(isEnabled: !selectedGoals.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 2: Current Usage

struct OnboardingCurrentUsageView: View {
    @Binding var hours: Double
    let onContinue: () -> Void
    
    private let options = ["Under 1 hour", "1-3 hours", "3-4 hours", "4-5 hours", "5-7 hours", "More than 7 hours"]
    private let hourValues: [Double] = [0.5, 2, 3.5, 4.5, 6, 8]
    @State private var selectedIndex: Int = 3
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("How much time do you spend")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("on your phone every day?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Your best guess is ok")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            
            Spacer()
            
            VStack(spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedIndex = index
                            hours = hourValues[index]
                        }
                    } label: {
                        Text(option)
                            .font(.system(size: 17, weight: selectedIndex == index ? .semibold : .regular))
                            .foregroundStyle(selectedIndex == index ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(RoundedRectangle(cornerRadius: 14).fill(selectedIndex == index ? .white : Color.white.opacity(0.08)))
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(action: onContinue)
        }
        }
    }
}

// MARK: - Phase 2: Target Usage

struct OnboardingTargetUsageView: View {
    let currentHours: Double
    @Binding var targetHours: Double
    let userName: String
    let onContinue: () -> Void
    
    private let options = ["Under 1 hour", "1-2 hours", "2-3 hours", "3-4 hours"]
    private let hourValues: [Double] = [0.5, 1.5, 2.5, 3.5]
    @State private var selectedIndex: Int = 1
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Don't feel bad, \(userName.isEmpty ? "friend" : userName).")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                
                Text("What matters is you're here to change.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 8)
                
                Text("How much time would you")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("like to spend instead?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 20)
            .multilineTextAlignment(.center)
            
            Spacer()
            
            VStack(spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedIndex = index
                            targetHours = hourValues[index]
                        }
                    } label: {
                        Text(option)
                            .font(.system(size: 17, weight: selectedIndex == index ? .semibold : .regular))
                            .foregroundStyle(selectedIndex == index ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(RoundedRectangle(cornerRadius: 14).fill(selectedIndex == index ? .white : Color.white.opacity(0.08)))
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(action: onContinue)
        }
        }
    }
}

// MARK: - Phase 3: Problem Apps

struct OnboardingProblemAppsView: View {
    @Binding var selectedApps: Set<String>
    let onContinue: () -> Void
    
    private let apps = [
        ("📱", "TikTok"), ("▶️", "YouTube"), ("📸", "Instagram"),
        ("🎮", "Mobile Games"), ("🐦", "Twitter/X"), ("💬", "Reddit"),
        ("🎧", "Discord"), ("🛒", "Shopping Apps"), ("📺", "Netflix")
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Now, let's find the cause.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("Which apps are taking")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("most of your time?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Select up to 3")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(apps, id: \.1) { emoji, name in
                        Button {
                            if selectedApps.contains(name) {
                                selectedApps.remove(name)
                            } else if selectedApps.count < 3 {
                                selectedApps.insert(name)
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Text(emoji)
                                    .font(.system(size: 32))
                                Text(name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(selectedApps.contains(name) ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(selectedApps.contains(name) ? Color.white : Color.white.opacity(0.1), lineWidth: selectedApps.contains(name) ? 2 : 1)
                                    )
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            
            OnboardingContinueButton(isEnabled: !selectedApps.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 3: Why Hard to Quit

struct OnboardingWhyHardView: View {
    @Binding var selectedReasons: Set<String>
    let selectedApps: Set<String>
    let onContinue: () -> Void
    
    private let reasons = [
        ("😰", "Fear Of Missing Out (FOMO)"),
        ("🔄", "Addictive app design"),
        ("🤖", "It's automatic, no reason"),
        ("😑", "Fills boring moments")
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Take a second to reflect on")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                Text("apps like \(selectedApps.first ?? "these").")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("What usually makes")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text("it hard to quit?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Select up to 3")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            .multilineTextAlignment(.center)
            
            Spacer()
            
            VStack(spacing: 12) {
                ForEach(reasons, id: \.1) { emoji, reason in
                    SelectableRowButton(emoji: emoji, title: reason, isSelected: selectedReasons.contains(reason)) {
                        if selectedReasons.contains(reason) {
                            selectedReasons.remove(reason)
                        } else if selectedReasons.count < 3 {
                            selectedReasons.insert(reason)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(isEnabled: !selectedReasons.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 4: Emotional Impact

struct OnboardingEmotionalImpactView: View {
    @Binding var selectedFeelings: Set<String>
    let onContinue: () -> Void
    
    private let feelings = [
        ("😤", "Irritable"), ("😶", "Not Present"), ("🧠", "Mentally Drained"),
        ("😔", "Regretful"), ("😶‍🌫️", "Empty"), ("😰", "Powerless"),
        ("😟", "Anxious"), ("😞", "Insecure"), ("🤯", "Overstimulated")
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Let's zoom in...")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("How does using these apps")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("for too long make you feel?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Select up to 2")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(feelings, id: \.1) { emoji, feeling in
                        Button {
                            if selectedFeelings.contains(feeling) {
                                selectedFeelings.remove(feeling)
                            } else if selectedFeelings.count < 2 {
                                selectedFeelings.insert(feeling)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text(emoji)
                                    .font(.system(size: 28))
                                Text(feeling)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(selectedFeelings.contains(feeling) ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(selectedFeelings.contains(feeling) ? Color.white : Color.white.opacity(0.1), lineWidth: selectedFeelings.contains(feeling) ? 2 : 1)
                                    )
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            
            OnboardingContinueButton(isEnabled: !selectedFeelings.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 5: Social Proof

struct OnboardingSocialProofView: View {
    let onContinue: () -> Void
    @State private var animatedCount: Int = 0
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 24) {
                Text("You're not alone")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("\(animatedCount.formatted())+")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.primary)
                    .contentTransition(.numericText())
                
                Text("people started with\nthe same goals")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            VStack(spacing: 16) {
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.yellow)
                    }
                }
                
                Text("\"Finally something that actually works. I've tried every screen time app - this is different.\"")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .italic()
                
                Text("— Alex M.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.05)))
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(action: onContinue)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5)) {
                animatedCount = 347892
            }
        }
        }
    }
}

// MARK: - Phase 6: Age Question

struct OnboardingAgeView: View {
    @Binding var selectedAge: String
    let onContinue: () -> Void
    
    private let ageRanges = ["Under 18", "18-24", "25-29", "30-40", "40 and over"]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("This helps us personalize")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                Text("your experience")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("How old are you?")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
            .padding(.top, 20)
            
            Spacer()
            
            VStack(spacing: 12) {
                ForEach(ageRanges, id: \.self) { age in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedAge = age
                        }
                    } label: {
                        Text(age)
                            .font(.system(size: 17, weight: selectedAge == age ? .semibold : .regular))
                            .foregroundStyle(selectedAge == age ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(RoundedRectangle(cornerRadius: 14).fill(selectedAge == age ? .white : Color.white.opacity(0.08)))
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(isEnabled: !selectedAge.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 6: Dependency Result

struct OnboardingDependencyResultView: View {
    let currentHours: Double
    let onContinue: () -> Void
    
    @State private var animate = false
    @State private var showBars = false
    
    private let averagePercent: Int = 25
    
    private var dependencyPercent: Int {
        min(Int(currentHours * 10 + 20), 95)
    }
    
    private var differencePercent: Int {
        dependencyPercent - averagePercent
    }
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            // Dramatic red/orange overlay from top
            RadialGradient(
                gradient: Gradient(colors: [Color(hex: "FF6B35").opacity(0.25), Color.clear]),
                center: .top,
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()
            .opacity(animate ? 1 : 0)
            .animation(.easeIn(duration: 1.0), value: animate)
            
            VStack(spacing: 24) {
                Spacer()
                
                // Title section
                VStack(spacing: 20) {
                    Text("It doesn't look good so far...")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(y: animate ? 0 : 20)
                        .opacity(animate ? 1 : 0)
                    
                    VStack(spacing: 4) {
                        Text("Your response indicates a clear")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        
                        HStack(spacing: 6) {
                            Text("negative dependence")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color(hex: "FF6B35"))
                            Text("on your phone*")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .offset(y: animate ? 0 : 20)
                    .opacity(animate ? 1 : 0)
                }
                
                Spacer()
                
                // Bar chart comparison - dramatically different heights
                HStack(spacing: 50) {
                    // User Bar - height capped to prevent overflow
                    VStack(spacing: 12) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.white.opacity(0.03))
                                .frame(width: 90, height: 280)
                            
                            // Bar height: scale percentage to max 260 (leaving room in 280 container)
                            let userBarHeight = min(CGFloat(dependencyPercent) / 100.0 * 280, 260)
                            
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "FF6B35"), Color(hex: "FFD93D")],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 90, height: showBars ? userBarHeight : 0)
                                .shadow(color: Color(hex: "FF6B35").opacity(0.4), radius: 15)
                            
                            // Percentage inside bar - positioned relative to actual bar height
                            Text("\(dependencyPercent)%")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .offset(y: showBars ? -userBarHeight + 45 : 0)
                                .opacity(showBars ? 1 : 0)
                        }
                        
                        Text("Your Result")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .opacity(animate ? 1 : 0)
                    }
                    
                    // Average Bar - shorter to show contrast
                    VStack(spacing: 12) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.white.opacity(0.03))
                                .frame(width: 90, height: 280)
                            
                            // Average bar scaled smaller for dramatic contrast
                            let avgBarHeight = CGFloat(averagePercent) / 100.0 * 200
                            
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "4A90A4").opacity(0.8), Color(hex: "89CFF0")],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 90, height: showBars ? avgBarHeight : 0)
                            
                            // Percentage inside bar
                            Text("\(averagePercent)%")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .offset(y: showBars ? -avgBarHeight + 40 : 0)
                                .opacity(showBars ? 1 : 0)
                        }
                        
                        Text("Average")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .opacity(animate ? 1 : 0)
                    }
                }
                .offset(y: animate ? 0 : 40)
                .opacity(animate ? 1 : 0)
                
                // Comparison text
                HStack(spacing: 4) {
                    Text("\(differencePercent)% higher")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(hex: "FF6B35"))
                    Text("than the average!")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)
                .offset(y: animate ? 0 : 20)
                .opacity(showBars ? 1 : 0)
                
                Spacer()
                
                // Disclaimer
                Text("*This is not a psychological diagnosis")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 8)
                    .opacity(animate ? 1 : 0)
                
                OnboardingContinueButton(action: onContinue)
                    .opacity(animate ? 1 : 0)
                    .offset(y: animate ? 0 : 20)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animate = true
            }
            
            // Delay bar animation to make it distinct
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 1.2)) {
                    showBars = true
                }
            }
        }
    }
}

// MARK: - Phase 7: What Have You Tried

struct OnboardingWhatTriedView: View {
    @Binding var selectedSolutions: Set<String>
    let selectedFeelings: Set<String>
    let onContinue: () -> Void
    
    private let solutions = [
        "Nothing yet", "Screen time limiters", "Uninstalling apps",
        "Digital Detox", "Grayscale Mode", "Working on Mindset",
        "Keeping phone away", "Morning/Night Routine", "Focus modes", "Other methods"
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let feeling = selectedFeelings.first {
                    Text("You said these apps make you \(feeling.lowercased()).")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                
                Text("What have you")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text("already tried?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Select all that apply")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.top, 20)
            .multilineTextAlignment(.center)
            
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(solutions, id: \.self) { solution in
                        Button {
                            if selectedSolutions.contains(solution) {
                                selectedSolutions.remove(solution)
                            } else {
                                selectedSolutions.insert(solution)
                            }
                        } label: {
                            Text(solution)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(selectedSolutions.contains(solution) ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(selectedSolutions.contains(solution) ? Color.white : Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            
            OnboardingContinueButton(isEnabled: !selectedSolutions.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 7: Why Others Fail

struct OnboardingWhyOthersFailView: View {
    let previousSolutions: Set<String>
    let onContinue: () -> Void
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Here's why those")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("didn't work")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 20)
            
            Spacer()
            
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.15)).frame(width: 56, height: 56)
                        Image(systemName: "xmark").font(.system(size: 24, weight: .bold)).foregroundStyle(.red)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Limiters")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Just block you. You feel restricted and eventually bypass them.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
                
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Theme.Colors.success.opacity(0.15)).frame(width: 56, height: 56)
                        Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.Colors.success)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ScreenBlock")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Replaces the habit. You earn time through exercise. It's sustainable.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.Colors.success.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.Colors.success.opacity(0.3), lineWidth: 1))
                )
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(action: onContinue)
        }
        }
    }
}

// MARK: - Phase 8: Years Lost

struct OnboardingYearsLostView: View {
    let dailyHours: Double
    @Binding var yearsAnimated: Int
    let onContinue: () -> Void
    
    @State private var showContent = false
    @State private var showButton = false
    
    private var yearsLost: Int {
        let totalHoursOver50Years = dailyHours * 365 * 50
        let wakingHoursIn50Years = 16.0 * 365 * 50
        return Int((totalHoursOver50Years / wakingHoursIn50Years) * 50)
    }
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            // Red ambient glow for dramatic effect
            RadialGradient(
                gradient: Gradient(colors: [Color(hex: "FF3B30").opacity(0.1), Color.clear]),
                center: .center,
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 12) {
                    Text("At this rate, you'll spend")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .offset(y: showContent ? 0 : 20)
                        .opacity(showContent ? 1 : 0)
                    
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(yearsAnimated)")
                            .font(.system(size: 140, weight: .black, design: .rounded))
                            .foregroundStyle(Color(hex: "FF3B30"))
                            .shadow(color: Color(hex: "FF3B30").opacity(0.4), radius: 30)
                            .contentTransition(.numericText())
                        
                        Text("years")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: "FF3B30").opacity(0.9))
                            .offset(y: -20)
                    }
                    .scaleEffect(showContent ? 1 : 0.8)
                    .opacity(showContent ? 1 : 0)
                    
                    Text("of your life looking at your phone")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                        .offset(y: showContent ? 0 : 20)
                        .opacity(showContent ? 1 : 0)
                    
                    // Improved segmented bar visualizer
                    VStack(spacing: 8) {
                        let totalBars = min(yearsLost + 2, 14)
                        
                        HStack(spacing: 6) {
                            ForEach(0..<totalBars, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(hex: "FF3B30").opacity(i < yearsAnimated ? 1 : 0.1),
                                                Color(hex: "FF3B30").opacity(i < yearsAnimated ? 0.6 : 0.05)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 20, height: 70)
                                    .shadow(color: i < yearsAnimated ? Color(hex: "FF3B30").opacity(0.3) : .clear, radius: 4)
                                    .animation(.spring(response: 0.4).delay(Double(i) * 0.05), value: yearsAnimated)
                            }
                        }
                        
                        Text("Each bar represents 1 year")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.top, 50)
                    .opacity(showContent ? 1 : 0)
                }
                
                Spacer()
                
                if showButton {
                    OnboardingContinueButton("What can I do?", action: onContinue)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 100)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showContent = true
            }
            
            // Animate numbers
            yearsAnimated = 0
            let target = yearsLost
            let steps = 40
            let duration = 2.0
            
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + (duration / Double(steps) * Double(i))) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        yearsAnimated = Int(Double(target) * Double(i) / Double(steps))
                    }
                    
                    if i == steps {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.spring(response: 0.5)) {
                                showButton = true
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Phase 8: Years Gained

struct OnboardingYearsGainedView: View {
    let yearsLost: Int
    @Binding var yearsGained: Int
    let onContinue: () -> Void
    
    @State private var animationComplete = false
    
    private var yearsToGain: Int { max(yearsLost / 3, 3) }
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 24) {
                Text("But here's the good news")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("+\(yearsGained)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Colors.success)
                        .contentTransition(.numericText())
                    Text("years")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.Colors.success.opacity(0.7))
                }
                
                Text("of your life back")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                
                VStack(alignment: .leading, spacing: 12) {
                    BenefitRowColored(icon: "heart.fill", text: "Better physical health", color: .red)
                    BenefitRowColored(icon: "brain.head.profile", text: "Improved mental clarity", color: .purple)
                    BenefitRowColored(icon: "moon.stars.fill", text: "Better sleep quality", color: .blue)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }
            
            Spacer()
            
            if animationComplete {
                OnboardingContinueButton("Show me how", action: onContinue)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Color.clear.frame(height: 100)
            }
        }
        .onAppear {
            animationComplete = false
            yearsGained = 0
            let target = yearsToGain
            let steps = 20
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / Double(steps) * Double(i)) {
                    withAnimation(.easeOut(duration: 0.05)) {
                        yearsGained = Int(Double(target) * Double(i) / Double(steps))
                    }
                    if i == steps {
                        withAnimation(.easeOut(duration: 0.3)) {
                            animationComplete = true
                        }
                    }
                }
            }
        }
        }
    }
}

struct BenefitRowColored: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color).frame(width: 24)
            Text(text).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - Phase 9: Science

struct OnboardingScienceView: View {
    let onContinue: () -> Void
    
    @State private var showTitle = false
    @State private var showCards = false
    @State private var showText = false
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                // Title Section
                VStack(spacing: 8) {
                    Text("The Science")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Behind It")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Theme.Colors.primary)
                }
                .padding(.top, 40)
                .offset(y: showTitle ? 0 : 20)
                .opacity(showTitle ? 1 : 0)
                
                Spacer()
                
                // Cards Section
                HStack(spacing: 20) {
                    // Push Card (Positive)
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Theme.Colors.success.opacity(0.15))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: "figure.strengthtraining.traditional")
                                    .font(.system(size: 36))
                                    .foregroundStyle(Theme.Colors.success)
                            )
                            .shadow(color: Theme.Colors.success.opacity(0.3), radius: 10)
                        
                        VStack(spacing: 4) {
                            Text("Push")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.Colors.success)
                            
                            Text("Earn minutes")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Theme.Colors.success.opacity(0.1),
                                        Theme.Colors.success.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Theme.Colors.success.opacity(0.2), lineWidth: 1)
                    )
                    .offset(x: showCards ? 0 : -50)
                    .opacity(showCards ? 1 : 0)
                    
                    // Scroll Card (Negative)
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: "iphone")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.white.opacity(0.4))
                            )
                        
                        VStack(spacing: 4) {
                            Text("Scroll")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white.opacity(0.4))
                            
                            Text("Spend minutes")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(hex: "1A1A1A"))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
                    .offset(x: showCards ? 0 : 50)
                    .opacity(showCards ? 1 : 0)
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Explanation Text
                VStack(spacing: 24) {
                    Text("It's easier to replace a habit\nthan to quit cold turkey.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 14))
                        Text("Based on habit replacement psychology")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .offset(y: showText ? 0 : 20)
                .opacity(showText ? 1 : 0)
                
                Spacer()
                
                OnboardingContinueButton("Let's set it up", action: onContinue)
                    .opacity(showText ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showTitle = true
            }
            
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3)) {
                showCards = true
            }
            
            withAnimation(.easeOut(duration: 0.8).delay(0.6)) {
                showText = true
            }
        }
    }
}

// MARK: - Phase 10: Exercise Selection (with Try Later)

struct OnboardingExercisePickerView: View {
    @Binding var selectedExercise: String
    let onContinue: () -> Void
    let onSkip: () -> Void
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Try out your favourite")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("Exercise from below!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("You can also skip this")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            
            Spacer()
            
            // Earn your first minutes badge
            HStack(spacing: 8) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 16))
                Text("Earn your first minutes!")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.primary)
            .padding(.bottom, 24)
            
            // Exercise options
            VStack(spacing: 16) {
                ExerciseRowButton(
                    icon: "figure.strengthtraining.traditional",
                    title: "Push-ups",
                    isSelected: selectedExercise == "Push-ups"
                ) {
                    selectedExercise = "Push-ups"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onContinue() }
                }
                
                ExerciseRowButton(
                    icon: "figure.run",
                    title: "Squats",
                    isSelected: selectedExercise == "Squats"
                ) {
                    selectedExercise = "Squats"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onContinue() }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Privacy note
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14))
                Text("The video won't leave your device.")
                    .font(.system(size: 14))
            }
            .foregroundStyle(.white.opacity(0.4))
            .padding(.bottom, 20)
            
            // Try Later button
            Button(action: onSkip) {
                Text("Try Later")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(.bottom, 40)
        }
        }
    }
}

struct ExerciseRowButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Exercise icon with arrows
                HStack(spacing: 4) {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                        Image(systemName: "arrow.up")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.primary)
                    
                    Image(systemName: icon)
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}

// MARK: - Phase 10: Setup Tutorial

struct OnboardingSetupTutorialView: View {
    let onContinue: () -> Void
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Spacer()
            
            // Video player for setup tutorial
            GeometryReader { geo in
                if let player = player {
                    PlayerFillView(player: player)
                        .frame(width: geo.size.width, height: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 32)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .onAppear {
                            player.play()
                        }
                        .onDisappear {
                            player.pause()
                        }
                } else {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: geo.size.width, height: 480)
                        .overlay(
                            VStack(spacing: 16) {
                                Image(systemName: "iphone.and.arrow.forward")
                                    .font(.system(size: 64))
                                    .foregroundStyle(.white.opacity(0.6))
                                
                                Text("Phone Setup")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        )
                }
            }
            .frame(height: 480)
            .padding(.horizontal, 24)
            
            Spacer()
            
            VStack(spacing: 12) {
                Text("Setup")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Place your phone on the floor facing you in a well-lit area.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
            
            OnboardingContinueButton("Next", action: onContinue)
        }
        }
        .onAppear {
            loadVideo(named: "vid3")
        }
    }
    
    private func loadVideo(named name: String) {
        guard let asset = NSDataAsset(name: name) else {
            print("Could not find video asset: \(name)")
            return
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        
        do {
            try asset.data.write(to: tempURL)
            player = AVPlayer(url: tempURL)
            player?.actionAtItemEnd = .none
            
            // Loop the video
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player?.currentItem,
                queue: .main
            ) { _ in
                player?.seek(to: .zero)
                player?.play()
            }
        } catch {
            print("Failed to write video: \(error)")
        }
    }
}

// MARK: - Phase 10: Exercise Demo

struct OnboardingExerciseDemoView: View {
    let exercise: String
    let onContinue: () -> Void
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Spacer()
            
            // Demo video
            GeometryReader { geo in
                if let player = player {
                    PlayerFillView(player: player)
                        .frame(width: geo.size.width, height: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 32)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .onAppear {
                            player.play()
                        }
                        .onDisappear {
                            player.pause()
                        }
                } else {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: geo.size.width, height: 480)
                        .overlay(
                    VStack(spacing: 16) {
                        Image(systemName: exercise == "Push-ups" ? "figure.strengthtraining.traditional" : "figure.run")
                            .font(.system(size: 80))
                            .foregroundStyle(Theme.Colors.primary.opacity(0.8))
                        
                        ProgressView()
                            .tint(.white)
                    }
                        )
                }
            }
            .frame(height: 480)
            .padding(.horizontal, 24)
            
            Spacer()
            
            VStack(spacing: 12) {
                Text(exercise)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Put your entire body in frame and exercise like in the video!")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
            
            OnboardingContinueButton("Next", action: onContinue)
        }
        }
        .onAppear {
            loadVideo(named: "vid2")
        }
    }
    
    private func loadVideo(named name: String) {
        guard let asset = NSDataAsset(name: name) else {
            print("Could not find video asset: \(name)")
            return
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        
        do {
            try asset.data.write(to: tempURL)
            player = AVPlayer(url: tempURL)
            player?.actionAtItemEnd = .none
            
            // Loop the video
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player?.currentItem,
                queue: .main
            ) { _ in
                player?.seek(to: .zero)
                player?.play()
            }
        } catch {
            print("Failed to write video: \(error)")
        }
    }
}

// MARK: - Phase 10: Detection Tips

struct OnboardingDetectionTipsView: View {
    let onContinue: () -> Void
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Text("Tips for better detection")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 20)
                .padding(.bottom, 80)
            
            VStack(alignment: .leading, spacing: 24) {
                TipRow(
                    icon: "iphone",
                    iconColor: Theme.Colors.primary,
                    text: "Make sure your whole body is fully in frame."
                )
                
                TipRow(
                    icon: "lightbulb.fill",
                    iconColor: Theme.Colors.primary,
                    text: "Make sure the background is clear and well-lit."
                )
                
                TipRow(
                    icon: "tshirt.fill",
                    iconColor: Theme.Colors.primary,
                    text: "Tuck in shirts and pants that are too baggy."
                )
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            OnboardingContinueButton(action: onContinue)
        }
        }
    }
}

struct TipRow: View {
    let icon: String
    let iconColor: Color
    let text: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(iconColor)
                .frame(width: 40)
            
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// Helper view to force AVPlayer to resize with aspect fill (no letterboxing)
struct PlayerFillView: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    
    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

// MARK: - Phase 10: Live Exercise Demo

struct OnboardingLiveExerciseView: View {
    let exercise: String
    let onComplete: (Int) -> Void
    let onSkip: () -> Void
    
    @State private var cameraManager = CameraManager()
    @State private var poseDetector = PoseDetector()
    @State private var pushUpAnalyzer = PushUpAnalyzer()
    @State private var repCount = 0
    @State private var isActive = false
    @State private var showCountdown = true
    @State private var countdownValue = 3
    
    private var exerciseType: Exercise {
        exercise == "Squats" ? .squats : .pushUps
    }
    
    var body: some View {
        ZStack {
            // Camera layer
            if cameraManager.isConfigured && isActive {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }
            
            // Skeleton Overlay
            if isActive {
                PoseOverlayView(
                    pose: poseDetector.detectedPose,
                    lineColor: Theme.Colors.skeleton,
                    jointColor: Theme.Colors.jointDot,
                    lineWidth: 4,
                    jointRadius: 6
                )
                .ignoresSafeArea()
            }
            
            // Gradient Overlay
            LinearGradient(
                colors: [Color.black.opacity(0.7), Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // Countdown overlay
            if showCountdown {
                VStack(spacing: 24) {
                    Text("Get Ready!")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text("\(countdownValue)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Colors.primary)
                        .contentTransition(.numericText())
                    
                    Text("Position yourself in frame")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                // UI Layer
                VStack(spacing: 0) {
                    // Title
                    Text(exercise.lowercased())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Colors.primary)
                        .padding(.top, 60)
                    
                    // Counter
                    VStack(spacing: 0) {
                        Text("\(repCount)")
                            .font(.system(size: 120, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.Gradients.counterText)
                            .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 10, x: 0, y: 0)
                            .contentTransition(.numericText())
                        
                        Text("REPS")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.Colors.primary.opacity(0.8))
                            .tracking(4)
                            .offset(y: -10)
                    }
                    .padding(.top, 40)
                    
                    // Earned time badge
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3")
                        Text("+\(repCount * 2) min earned")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Colors.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.Colors.primary.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.top, 20)
                    
                    Spacer()
                    
                    // Bottom buttons
                    VStack(spacing: 12) {
                        // Complete button
                        Button {
                            stopWorkout()
                            onComplete(repCount)
                        } label: {
                            Text(repCount > 0 ? "Complete (\(repCount) reps)" : "Complete")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        
                        // Skip button
                        Button(action: {
                            stopWorkout()
                            onSkip()
                        }) {
                            Text("Skip for now")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .task {
            // Configure camera
            await cameraManager.configure()
            startCountdown()
        }
        .onDisappear {
            stopWorkout()
        }
    }
    
    private func startCountdown() {
        showCountdown = true
        countdownValue = 3
        
        // Countdown animation
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) {
                withAnimation(.spring(response: 0.3)) {
                    countdownValue = 3 - i
                }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }
        }
        
        // Start workout after countdown
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showCountdown = false
                isActive = true
            }
            startWorkout()
        }
    }
    
    private func startWorkout() {
        cameraManager.frameHandler = { buffer in
            poseDetector.processFrame(buffer)
            
            DispatchQueue.main.async {
                if let pose = poseDetector.detectedPose {
                    pushUpAnalyzer.analyze(pose: pose)
                    
                    // Update rep count
                    if pushUpAnalyzer.repCount != repCount {
                        withAnimation(.spring(response: 0.2)) {
                            repCount = pushUpAnalyzer.repCount
                        }
                        // Haptic feedback on rep
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                    }
                }
            }
        }
        
        cameraManager.start()
    }
    
    private func stopWorkout() {
        isActive = false
        cameraManager.frameHandler = nil
        cameraManager.stop()
    }
}

// MARK: - Phase 10: Exercise Frequency

struct OnboardingExerciseFrequencyView: View {
    @Binding var selectedFrequency: String
    let onContinue: () -> Void
    
    private let frequencies = [
        ("figure.stand", "Never"),
        ("figure.walk", "1-3 times per week"),
        ("figure.run", "3-5 times per week"),
        ("figure.highintensity.intervaltraining", "Every day")
    ]
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaking of activity,")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text("How often do you currently exercise?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Choose one")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 40)
            
            VStack(spacing: 12) {
                ForEach(frequencies, id: \.1) { icon, frequency in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedFrequency = frequency
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: icon)
                                .font(.system(size: 20))
                                .foregroundStyle(selectedFrequency == frequency ? Theme.Colors.primary : .white.opacity(0.6))
                                .frame(width: 32)
                            
                            Text(frequency)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                            
                            Spacer()
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(selectedFrequency == frequency ? Color.white.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(selectedFrequency == frequency ? Color.white : Color.white.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            OnboardingContinueButton(isEnabled: !selectedFrequency.isEmpty, action: onContinue)
        }
        }
    }
}

// MARK: - Phase 11: Finish Setup

struct OnboardingFinishSetupView: View {
    let userName: String
    let onContinue: () -> Void
    
    @State private var showText = false
    @State private var showButton = false
    
    private var displayName: String {
        userName.isEmpty ? "Friend" : userName
    }
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 180)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(displayName), you're")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text("90% of the way")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Theme.Colors.primary)
                    
                    Text("towards your goals.")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .padding(.horizontal, 32)
                .opacity(showText ? 1 : 0)
                
                Spacer()
                
                Button(action: onContinue) {
                    Text("Let's Finish")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.blue.opacity(0.5))
                        )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .opacity(showButton ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showText = true
            }
            
            withAnimation(.easeOut(duration: 0.5).delay(0.5)) {
                showButton = true
            }
        }
    }
}

// MARK: - Phase 11: Screen Time Permission

struct OnboardingScreenTimeView: View {
    let userName: String
    let isPreview: Bool
    let onComplete: () -> Void
    @State private var screenTimeManager = ScreenTimeManager.shared
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Connect to Screen Time,")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Securely.")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text("To manage your app limits,\nwe'll need your permission")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.top, 20)
                
                Spacer()
                
                // iOS System Alert Mock - positioned to align with real iOS system alert
                // Tappable to trigger the same action as the Enable Screen Time button
                Button {
                    if isPreview {
                        onComplete()
                        return
                    }
                    isLoading = true
                    Task {
                        do {
                            try await screenTimeManager.requestAuthorization()
                        } catch {
                            print("[Onboarding] Screen Time authorization error: \(error.localizedDescription)")
                        }
                        await MainActor.run {
                            isLoading = false
                            onComplete()
                        }
                    }
                } label: {
                    VStack(spacing: -70) { // Negative spacing to pull arrow closer
                        IOSSystemAlert(
                            title: "\"ScreenBlock\" Would Like to Access Screen Time",
                            message: "Providing \"ScreenBlock\" access to Screen Time may allow it to see your activity data, restrict content, and limit the usage of apps and websites.",
                            buttons: [
                                IOSAlertButton(title: "Continue", style: .default),
                                IOSAlertButton(title: "Don't Allow", style: .highlighted)
                            ],
                            textAlignment: .leading,
                            messageFontSize: 14
                        )
                        
                        // Arrow pointing to Continue button (LEFT side)
                        HStack(spacing: 8) {
                            BouncingArrow()
                                .frame(maxWidth: .infinity)
                            
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 30)
                        .padding(.top, 0) // Ensure no extra padding
                        .zIndex(1) // Ensure arrow is on top if it overlaps
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .offset(y: 90) // Push down further to align with real iOS system alert position
                
                Spacer()
                
                // Privacy note
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14))
                    Text("Your sensitive data is protected by Apple")
                        .font(.system(size: 14))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 20)
                
                // CTA
                VStack(spacing: 16) {
                    Button {
                        print("[Onboarding] Enable Screen Time button pressed, isPreview: \(isPreview)")
                        print("[Onboarding] Current authorization status: \(screenTimeManager.isAuthorized)")
                        
                        if isPreview {
                            print("[Onboarding] Skipping authorization in preview mode")
                            onComplete()
                            return
                        }
                        
                        isLoading = true
                        Task {
                            do {
                                print("[Onboarding] Calling requestAuthorization...")
                                try await screenTimeManager.requestAuthorization()
                                print("[Onboarding] Screen Time authorization completed, isAuthorized: \(screenTimeManager.isAuthorized)")
                            } catch {
                                print("[Onboarding] Screen Time authorization error: \(error.localizedDescription)")
                            }
                            await MainActor.run {
                                isLoading = false
                                onComplete()
                            }
                        }
                    } label: {
                        HStack {
                            if isLoading { ProgressView().tint(.black) }
                            else { Text("Enable Screen Time").font(.system(size: 18, weight: .bold)) }
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isLoading)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - iOS System Alert Components

struct IOSAlertButton: Identifiable {
    let id = UUID()
    let title: String
    let style: IOSAlertButtonStyle
    
    enum IOSAlertButtonStyle {
        case `default`
        case cancel
        case destructive
        case highlighted // Blue filled button
    }
}

struct BouncingArrow: View {
    @State private var offset: CGFloat = 0
    
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(Theme.Colors.primary)
            .shadow(color: Theme.Colors.primary.opacity(0.5), radius: 8)
            .offset(y: offset)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    offset = -10
                }
            }
    }
}

struct IOSSystemAlert: View {
    let title: String
    let message: String
    let buttons: [IOSAlertButton]
    let textAlignment: TextAlignment
    let messageFontSize: CGFloat
    
    init(title: String, message: String, buttons: [IOSAlertButton], textAlignment: TextAlignment = .center, messageFontSize: CGFloat = 13) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.textAlignment = textAlignment
        self.messageFontSize = messageFontSize
    }
    
    var body: some View {
        VStack(spacing: 18) {
            // Content
            VStack(alignment: textAlignment == .leading ? .leading : .center, spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: textAlignment == .leading ? .leading : .center)
                
                Text(message)
                    .font(.system(size: messageFontSize))
                    .foregroundStyle(Color(white: 0.7))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: textAlignment == .leading ? .leading : .center)
            }
            
            // Buttons - separate bubble style like real iOS permission alerts
            HStack(spacing: 8) {
                ForEach(buttons) { button in
                    Text(button.title)
                        .font(.system(size: 17, weight: button.style == .highlighted ? .semibold : .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(button.style == .highlighted ? Color(red: 0.027, green: 0.604, blue: 0.996) : Color(white: 0.2)) // #079afe for highlighted
                        )
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.075, green: 0.078, blue: 0.09)) // #131417
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color(red: 0.188, green: 0.2, blue: 0.227), lineWidth: 0.5) // #30333a super thin border
        )
        .frame(width: 310) // Wider to match real alert
    }
}

// MARK: - Phase 11: Select Distracting Apps

struct OnboardingSelectAppsView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var showingPicker: Bool
    let onContinue: () -> Void
    
    @State private var selection = FamilyActivitySelection()
    @State private var showingLimitSetup = false
    @State private var limitName = "Distracting Apps"
    @State private var limitMinutes = 60
    @State private var iconRotation: Double = 0
    
    private let appIcons = ["play.rectangle.fill", "music.note", "bubble.left.fill", "camera.fill", "gamecontroller.fill", "cart.fill", "tv.fill", "message.fill", "globe", "photo.fill", "video.fill", "heart.fill"]
    private let presetMinutes = [15, 30, 60, 90, 120]
    
    private var hasSelection: Bool {
        !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty
    }
    
    private var appCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count
    }
    
    var body: some View {
        ZStack {
            // Starfield background for "space" feel
            StarfieldView()
                .opacity(0.5)
            
            // Main selection view
            if !showingLimitSetup {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Text("Let's set up ScreenBlock!")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        
                        Text("Select your most distracting apps")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text("You can always change this later in the App's settings.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    // Scattered app icons cloud - balanced organic arrangement
                    ZStack {
                        // Top row - spread out
                        Image(systemName: "globe")
                            .font(.system(size: 26))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: 0, y: -140)
                            .rotationEffect(.degrees(0))
                        
                        // Upper middle row
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -100, y: -80)
                            .rotationEffect(.degrees(-5))
                        
                        Image(systemName: "photo.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -10, y: -70)
                            .rotationEffect(.degrees(3))
                        
                        Image(systemName: "tv.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: 100, y: -60)
                            .rotationEffect(.degrees(-8))
                        
                        // Center row - main focus
                        Image(systemName: "heart.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -20, y: 10)
                            .rotationEffect(.degrees(0))
                        
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -120, y: 30)
                            .rotationEffect(.degrees(-6))
                        
                        Image(systemName: "message.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: 120, y: 20)
                            .rotationEffect(.degrees(5))
                        
                        // Lower middle row
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -30, y: 90)
                            .rotationEffect(.degrees(8))
                        
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: -100, y: 120)
                            .rotationEffect(.degrees(-4))
                        
                        // Bottom row
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .offset(x: 60, y: 130)
                            .rotationEffect(.degrees(10))
                    }
                    .frame(height: 340)
                    
                    Spacer()
                    
                    // Select Apps button
                    Button {
                        showingPicker = true
                    } label: {
                        Text("Select Apps")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(colors: [.white, Color(hex: "E0E0E0")], startPoint: .top, endPoint: .bottom)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .white.opacity(0.1), radius: 10, x: 0, y: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            } else {
                // Limit setup view
                limitSetupView
            }
        }
        .familyActivityPicker(isPresented: $showingPicker, selection: $selection)
        .onChange(of: showingPicker) { _, isShowing in
            if !isShowing && hasSelection {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showingLimitSetup = true
                }
            }
        }
    }
    
    private var limitSetupView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Create your first block list")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("\(appCount) apps selected")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Colors.primary)
            }
            .padding(.top, 20)
            
            // App icons preview
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: -14) {
                    ForEach(Array(Array(selection.applicationTokens.prefix(6)).enumerated()), id: \.offset) { idx, token in
                        Label(token)
                            .labelStyle(.iconOnly)
                            .scaleEffect(1.6)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .zIndex(Double(100 - idx))
                    }
                    let remainingSlots = max(0, 6 - selection.applicationTokens.count)
                    ForEach(Array(Array(selection.categoryTokens.prefix(remainingSlots)).enumerated()), id: \.offset) { idx, token in
                        let position = selection.applicationTokens.count + idx
                        Label(token)
                            .labelStyle(.iconOnly)
                            .scaleEffect(1.6)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .zIndex(Double(100 - position))
                    }
                    if appCount > 6 {
                        Text("+\(appCount - 6)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Theme.Colors.cardBorder)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.top, 24)
            
            // Name input
            VStack(alignment: .leading, spacing: 8) {
                Text("NAME")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1.5)
                
                TextField("Block list name", text: $limitName)
                    .font(.system(size: 17))
                    .padding(16)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            
            // Time limit
            VStack(spacing: 16) {
                Text("\(limitMinutes)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.primary)
                
                Text("minutes per day")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                
                // Presets
                HStack(spacing: 8) {
                    ForEach(presetMinutes, id: \.self) { minutes in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                limitMinutes = minutes
                            }
                        } label: {
                            Text(minutes >= 60 ? "\(minutes/60)h" : "\(minutes)m")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(limitMinutes == minutes ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(limitMinutes == minutes ? .white : Color.white.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.top, 32)
            
            Spacer()
            
            // Create button
            Button {
                createLimitAndContinue()
            } label: {
                Text("Create Block List")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
    
    private func createLimitAndContinue() {
        // Create a new AppTimeLimit
        let newLimit = AppTimeLimit(
            displayName: limitName.isEmpty ? "Distracting Apps" : limitName,
            dailyLimitMinutes: limitMinutes
        )
        
        // Set the first app/category token
        if let firstApp = selection.applicationTokens.first {
            newLimit.setApplicationToken(firstApp)
        } else if let firstCategory = selection.categoryTokens.first {
            newLimit.setCategoryToken(firstCategory)
        }
        
        // Save the full selection to UserDefaults
        if let data = try? PropertyListEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: "limit_selection_\(newLimit.id.uuidString)")
        }
        
        // Insert into SwiftData
        modelContext.insert(newLimit)
        try? modelContext.save()
        
        // Sync to Firebase
        Task {
            await UserDataManager.shared.saveTimeLimit(newLimit)
        }
        
        // Also save to ScreenTimeManager
        ScreenTimeManager.shared.selectedApps = selection
        
        // Start monitoring
        let limits = [newLimit]
        ScreenTimeManager.shared.startMonitoring(limits: limits, context: modelContext)
        
        onContinue()
    }
}

// MARK: - Phase 11: Notification Permission

struct OnboardingNotificationView: View {
    let onContinue: (Bool) -> Void
    @State private var isRequesting = false
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Let's set up!")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Text("Allow notifications to send you reminders")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    
                    Text("We use this to remind you to exercise and unblock your apps when you want to use them.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                
                Spacer()
                
                // iOS System Alert Mock - positioned to align with real iOS system alert
                // Tappable to trigger the same action as the Enable Notifications button
                Button {
                    isRequesting = true
                    Task {
                        let center = UNUserNotificationCenter.current()
                        do {
                            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                            await MainActor.run {
                                isRequesting = false
                                onContinue(granted)
                            }
                        } catch {
                            await MainActor.run {
                                isRequesting = false
                                onContinue(false)
                            }
                        }
                    }
                } label: {
                    VStack(spacing: -90) { // Negative spacing to pull arrow closer
                        IOSSystemAlert(
                            title: "\"ScreenBlock\" Would Like to Send You Notifications",
                            message: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.",
                            buttons: [
                                IOSAlertButton(title: "Don't Allow", style: .default),
                                IOSAlertButton(title: "Allow", style: .default)
                            ],
                            textAlignment: .leading,
                            messageFontSize: 14
                        )
                        
                        // Arrow positioned under the "Allow" button (right side)
                        HStack(spacing: 8) {
                            Color.clear
                                .frame(maxWidth: .infinity)
                            
                            BouncingArrow()
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 30)
                        .padding(.top, 0)
                        .zIndex(1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .offset(y: 90) // Push down to align with real iOS system alert position
                
                Spacer()
                
                Button {
                    isRequesting = true
                    Task {
                        let center = UNUserNotificationCenter.current()
                        do {
                            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                            await MainActor.run {
                                isRequesting = false
                                onContinue(granted)
                            }
                        } catch {
                            await MainActor.run {
                                isRequesting = false
                                onContinue(false)
                            }
                        }
                    }
                } label: {
                    HStack {
                        if isRequesting { ProgressView().tint(.black) }
                        else { Text("Enable Notifications").font(.system(size: 18, weight: .bold)) }
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isRequesting)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Phase 11: Notification Warning

struct OnboardingNotificationWarningView: View {
    let onOpenSettings: () -> Void
    let onContinue: () -> Void
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                Spacer()
                
                // Native iOS Alert Style - Matching IOSSystemAlert component exactly
                VStack(spacing: 16) {
                    // Content
                    VStack(spacing: 4) {
                        // Warning Icon
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                            .padding(.bottom, 8)
                        
                        Text("Limited Functionality")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text("Without notifications, you'll need to open ScreenBlock manually when you want to use a restricted app.\n\nYou can enable notifications anytime in Settings.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(white: 0.8))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    
                    // Buttons - using separate rounded rectangles like the system alert
                    HStack(spacing: 8) {
                        Button(action: onOpenSettings) {
                            Text("Open Settings")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 22)
                                        .fill(Color(white: 0.2))
                                )
                        }
                        
                        Button(action: onContinue) {
                            Text("Continue")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 22)
                                        .fill(Color(red: 0.027, green: 0.604, blue: 0.996)) // #079afe
                                )
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color(red: 0.075, green: 0.078, blue: 0.09)) // #131417
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color(red: 0.188, green: 0.2, blue: 0.227), lineWidth: 0.5) // #30333a super thin border
                )
                .frame(width: 320) // Wider to match previous sizing
                
                Spacer()
            }
        }
    }
}

// MARK: - Phase 12: Give Rating

struct OnboardingRatingView: View {
    let onContinue: () -> Void
    @State private var currentTestimonial = 0
    @State private var showContent = false
    @State private var showStars = false
    @State private var showAvatars = false
    @State private var starScale: [CGFloat] = [0, 0, 0, 0, 0]
    
    private let testimonials = [
        ("Devi J.", "@Devi_jones999", "If you want to improve yourself and your body, this is the app for you. The way you have to earn your screen time is really fun 10/10 app."),
        ("Marcus T.", "@marcus_fit", "Finally broke my phone addiction! Down from 6 hours to 2 hours daily. The exercise requirement makes you actually think twice before scrolling."),
        ("Sarah K.", "@sarahk_wellness", "Game changer for my productivity. I've never been more consistent with my workouts AND my focus has improved dramatically.")
    ]
    
    let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                // Title
                Text("Give us a rating")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                
                // Rating badge with laurels
                HStack(spacing: 8) {
                    Image(systemName: "laurel.leading")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                        .opacity(showContent ? 1 : 0)
                        .offset(x: showContent ? 0 : 20)
                    
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { index in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Color(red: 1.0, green: 0.8, blue: 0.0))
                                    .scaleEffect(starScale[index])
                                    .shadow(color: Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.4), radius: 8)
                            }
                        }
                        
                        Text("4.7")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 2)
                            .opacity(showContent ? 1 : 0)
                    }
                    
                    Image(systemName: "laurel.trailing")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                        .opacity(showContent ? 1 : 0)
                        .offset(x: showContent ? 0 : -20)
                }
                .padding(.top, 24)
                
                Text("ScreenBlock was made for people like you.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .padding(.horizontal, 32)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                
                // User avatars (Commented out until we have real photos)
                /*
                HStack(spacing: -16) {
                    if showAvatars {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill([Color.red, Color.green, Color.blue][index].opacity(0.8))
                                .frame(width: 52, height: 52)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.black.opacity(0.5), lineWidth: 3)
                                )
                                .transition(.scale.combined(with: .opacity))
                                .zIndex(Double(3 - index))
                        }
                    }
                }
                .padding(.top, 32)
                .onAppear {
                    withAnimation(.spring(duration: 0.6, bounce: 0.4).delay(0.8)) {
                        showAvatars = true
                    }
                }
                
                Text("+1000s users")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        Capsule()
                            .fill(Theme.Colors.primary.opacity(0.15))
                    )
                    .padding(.top, 12)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 10)
                */
                
                Spacer()
                
                // Testimonial card
                TabView(selection: $currentTestimonial) {
                    ForEach(0..<testimonials.count, id: \.self) { index in
                        TestimonialCard(
                            name: testimonials[index].0,
                            handle: testimonials[index].1,
                            review: testimonials[index].2
                        )
                        .tag(index)
                        .padding(.horizontal, 24)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 200)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 40)
                .padding(.bottom, 24) // Added padding between card and dots
                
                // Custom Paging Indicator
                HStack(spacing: 8) {
                    ForEach(0..<testimonials.count, id: \.self) { index in
                        Circle()
                            .fill(currentTestimonial == index ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.spring, value: currentTestimonial)
                    }
                }
                .padding(.bottom, 24)
                .opacity(showContent ? 1 : 0)
                
                Spacer()
                
                OnboardingContinueButton(action: onContinue)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showContent = true
            }
            
            // Animate stars sequentially
            for i in 0..<5 {
                withAnimation(.spring(duration: 0.5, bounce: 0.5).delay(0.3 + Double(i) * 0.1)) {
                    starScale[i] = 1.0
                }
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                currentTestimonial = (currentTestimonial + 1) % testimonials.count
            }
        }
    }
}

struct TestimonialCard: View {
    let name: String
    let handle: String
    let review: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Text(String(name.prefix(1)))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(handle)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
                
                Spacer()
                
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                    }
                }
            }
            
            Text(review)
                .font(.system(size: 16, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Phase 12: Join/Login

struct OnboardingJoinView: View {
    let onLogin: () -> Void
    let onSkip: () -> Void
    @State private var isLoading = false
    @State private var showContent = false
    
    // Animation states
    @State private var pulseGlow = false
    @State private var phoneShake = false
    @State private var dumbbellBounce = false
    
    private let authManager = AuthenticationManager.shared
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            // Enhanced atmospheric glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.Colors.primary.opacity(pulseGlow ? 0.3 : 0.15), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: pulseGlow ? 220 : 180
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 50)
                .offset(y: -100)
            
            VStack(spacing: 0) {
                Spacer()
                
                // --- Hero Transformation Visual ---
                HStack(spacing: 24) {
                    // Left: Doomscrolling (Phone)
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .frame(width: 100, height: 100)
                            
                            Image(systemName: "iphone")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.5))
                            
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.3))
                                .offset(x: 10, y: 10)
                                .offset(y: phoneShake ? -3 : 3)
                        }
                        .rotationEffect(.degrees(phoneShake ? -2 : 2))
                        
                        Text("Doomscroll")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .strikethrough(color: .white.opacity(0.3))
                    }
                    
                    // Middle: Arrow
                    Image(systemName: "arrow.right")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.Colors.primary)
                        .scaleEffect(showContent ? 1 : 0.5)
                        .padding(.horizontal, 8)
                    
                    // Right: Gains (Dumbbell)
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.primary.opacity(0.1))
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Circle()
                                        .stroke(Theme.Colors.primary.opacity(0.3), lineWidth: 1)
                                )
                            
                            Image(systemName: "dumbbell.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Theme.Colors.primary)
                                .shadow(color: Theme.Colors.primary.opacity(0.6), radius: 15)
                                .scaleEffect(dumbbellBounce ? 1.1 : 1.0)
                        }
                        
                        Text("Gains")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.Colors.primary)
                    }
                }
                .opacity(showContent ? 1 : 0)
                .scaleEffect(showContent ? 1 : 0.8)
                
                Spacer()
                
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Text("Join ")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                        Text("ScreenBlock")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(Theme.Gradients.primaryButton)
                    }
                    
                    Text("See the custom plan we've built for you\nand join our community.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                .padding(.bottom, 40)
                .offset(y: showContent ? 0 : 20)
                .opacity(showContent ? 1 : 0)
                
                VStack(spacing: 12) {
                    // Apple Sign In
                    SignInWithAppleButton(.continue) { request in
                        authManager.handleAppleSignInRequest(request)
                    } onCompletion: { result in
                        Task {
                            await authManager.handleAppleSignInCompletion(result)
                            if authManager.isAuthenticated {
                                onLogin()
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    
                    // Google Sign In
                    Button {
                        Task {
                            try? await authManager.signInWithGoogle()
                            if authManager.isAuthenticated {
                                onLogin()
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            GoogleLogo()
                                .frame(width: 20, height: 20)
                            
                            Text("Continue with Google")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    // Skip (Blue Gradient)
                    Button(action: onSkip) {
                        HStack(spacing: 8) {
                            Text("Skip")
                                .font(.system(size: 16, weight: .bold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "007AFF"), Color(hex: "00C7BE")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .offset(y: showContent ? 0 : 20)
                .opacity(showContent ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showContent = true
            }
            
            // Continuous animations
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                pulseGlow = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(0.5)) {
                phoneShake = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5, blendDuration: 1.0).repeatForever(autoreverses: true).delay(1.0)) {
                dumbbellBounce = true
            }
        }
    }
}

// MARK: - Phase 12: Calculating

struct OnboardingCalculatingView: View {
    @Binding var progress: Double
    let onComplete: () -> Void
    @State private var animatedProgress: Double = 0
    @State private var displayedPercent: Int = 0
    @State private var rotation: Double = 0
    @State private var isPaused: Bool = false
    
    let timer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Starfield background
            StarfieldView()
                .opacity(0.7)
            
            VStack(spacing: 0) {
                Spacer()
                
                Text("Calculating")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                
                // Modern Circular progress
                ZStack {
                    // Track
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 20)
                        .frame(width: 220, height: 220)
                    
                    // Progress
                    Circle()
                        .trim(from: 0, to: animatedProgress)
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "007AFF"), Color(hex: "00C7BE")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 20, lineCap: .round)
                        )
                        .frame(width: 220, height: 220)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Color(hex: "007AFF").opacity(0.5), radius: 20)
                    
                    VStack(spacing: 4) {
                        Text("\(displayedPercent)%")
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.top, 50)
                
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                        .rotationEffect(.degrees(rotation))
                    Text("Comparing data")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 32)
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
                
                Spacer()
                
                // Social proof badges
                HStack(spacing: 40) {
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "laurel.leading")
                            VStack(spacing: 2) {
                                HStack(spacing: 2) {
                                    ForEach(0..<5, id: \.self) { _ in
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.yellow)
                                    }
                                }
                                Text("4.7 Stars")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            Image(systemName: "laurel.trailing")
                        }
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                    }
                    
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "laurel.leading")
                            VStack(spacing: 2) {
                                Text("1,000+")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Users")
                                    .font(.system(size: 12))
                            }
                            Image(systemName: "laurel.trailing")
                        }
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onReceive(timer) { _ in
            guard !isPaused else { return }
            
            if displayedPercent < 100 {
                withAnimation(.linear(duration: 0.03)) {
                    displayedPercent += 1
                    animatedProgress = Double(displayedPercent) / 100.0
                }
                
                // Pause at 68% to simulate processing
                if displayedPercent == 68 {
                    isPaused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isPaused = false
                    }
                }
                
                // Brief pause at 89% for authenticity
                if displayedPercent == 89 {
                    isPaused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isPaused = false
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                onComplete()
            }
        }
    }
}

// MARK: - Phase 12: Journey Chart

struct OnboardingJourneyChartView: View {
    let currentHours: Double
    let targetHours: Double
    let exerciseFrequency: String
    let onContinue: () -> Void
    
    @State private var drawChart = false
    @State private var showLabels = false
    
    private var futureDate: String {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM, yyyy"
        return formatter.string(from: date)
    }
    
    private var daysSaved: Int {
        let hoursSaved = currentHours - targetHours
        return Int((hoursSaved * 365) / 24)
    }
    
    var body: some View {
        ZStack {
            // Starfield background
            StarfieldView()
                .opacity(0.5)
            
            VStack(spacing: 0) {
                // Laurel Header (more compact)
                HStack(spacing: 6) {
                    Image(systemName: "laurel.leading")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                    
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        Text("4.7")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    
                    Image(systemName: "laurel.trailing")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                .padding(.top, 10)
                
                VStack(spacing: 4) {
                    Text("Your journey of Self-")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 0) {
                        Text("Improvement ")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                        Text("starts now!")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Theme.Colors.primary)
                    }
                }
                .padding(.top, 6)
                
                // Chart Container
                GeometryReader { geo in
                    let chartWidth = geo.size.width - 70 // Leave space for Y labels
                    let chartHeight: CGFloat = 180
                    let leftPadding: CGFloat = 60
                    
                    ZStack(alignment: .topLeading) {
                        // Y-axis labels (left side, outside chart)
                        VStack {
                            HStack(spacing: 2) {
                                Text("4h")
                                    .font(.system(size: 16, weight: .semibold))
                                Image(systemName: "iphone")
                                    .font(.system(size: 18))
                            }
                            .foregroundStyle(.white)
                            
                            Spacer()
                            
                            HStack(spacing: 2) {
                                Text("3h")
                                    .font(.system(size: 16, weight: .semibold))
                                Image(systemName: "iphone")
                                    .font(.system(size: 18))
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: 55, height: chartHeight)
                        .padding(.top, 40)
                        
                        // Chart area
                        ZStack {
                            // Axis lines
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 0))
                                path.addLine(to: CGPoint(x: 0, y: chartHeight))
                                path.addLine(to: CGPoint(x: chartWidth, y: chartHeight))
                            }
                            .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                            
                            // Filled area under blue curve (shows first)
                            if drawChart {
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 20))
                                    path.addQuadCurve(to: CGPoint(x: chartWidth * 0.4, y: 90), control: CGPoint(x: chartWidth * 0.2, y: 30))
                                    path.addQuadCurve(to: CGPoint(x: chartWidth * 0.7, y: 130), control: CGPoint(x: chartWidth * 0.55, y: 110))
                                    path.addQuadCurve(to: CGPoint(x: chartWidth - 30, y: 145), control: CGPoint(x: chartWidth * 0.85, y: 140))
                                    path.addLine(to: CGPoint(x: chartWidth - 30, y: chartHeight))
                                    path.addLine(to: CGPoint(x: 0, y: chartHeight))
                                    path.closeSubpath()
                                }
                                .fill(
                                    LinearGradient(
                                        colors: [Theme.Colors.primary.opacity(0.4), Theme.Colors.primary.opacity(0.05)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                            
                            // Orange wavy line (Conventional) - starts low, ends HIGH with wobbles
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: chartHeight - 30)) // Start near bottom (low screen time at start)
                                // Wobble up
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.15, y: chartHeight - 60), control: CGPoint(x: chartWidth * 0.08, y: chartHeight - 20))
                                // Wobble down
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.3, y: chartHeight - 40), control: CGPoint(x: chartWidth * 0.22, y: chartHeight - 80))
                                // Wobble up higher
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.5, y: 60), control: CGPoint(x: chartWidth * 0.4, y: chartHeight - 50))
                                // Cross over and keep going up with wobbles
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.65, y: 80), control: CGPoint(x: chartWidth * 0.58, y: 40))
                                // Final push to top
                                path.addQuadCurve(to: CGPoint(x: chartWidth - 30, y: 25), control: CGPoint(x: chartWidth * 0.8, y: 90))
                            }
                            .trim(from: 0, to: drawChart ? 1 : 0)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            
                            // Blue smooth curve (Screentime) - starts high, ends LOW
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 20)) // Start near top (high screen time)
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.4, y: 90), control: CGPoint(x: chartWidth * 0.2, y: 30))
                                path.addQuadCurve(to: CGPoint(x: chartWidth * 0.7, y: 130), control: CGPoint(x: chartWidth * 0.55, y: 110))
                                path.addQuadCurve(to: CGPoint(x: chartWidth - 30, y: 145), control: CGPoint(x: chartWidth * 0.85, y: 140))
                            }
                            .trim(from: 0, to: drawChart ? 1 : 0)
                            .stroke(Theme.Colors.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            
                            // Labels at endpoints
                            if showLabels {
                                // Orange endpoint label
                                VStack(spacing: 4) {
                                    Text("Conventional")
                                        .font(.system(size: 11, weight: .medium))
                                    Text("Methods")
                                        .font(.system(size: 11, weight: .medium))
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Image(systemName: "xmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(.white)
                                        )
                                }
                                .foregroundStyle(.white)
                                .position(x: chartWidth - 30, y: -15)
                                
                                // Blue endpoint label
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Theme.Colors.primary)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Image(systemName: "dumbbell.fill")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(.white)
                                        )
                                    Text("ScreenBlock")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .position(x: chartWidth - 30, y: 175)
                            }
                        }
                        .frame(width: chartWidth, height: chartHeight + 40)
                        .padding(.leading, leftPadding)
                        .padding(.top, 40)
                        
                        // X-axis labels
                        HStack {
                            Text("Today")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text("Day 30")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.leading, leftPadding + 5)
                        .padding(.trailing, 70)
                        .padding(.top, chartHeight + 48)
                    }
                }
                .frame(height: 270)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                
                VStack(spacing: 12) {
                    Text("You will feel differences by:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                    
                    Text(futureDate)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .stroke(
                                    LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing),
                                    lineWidth: 2
                                )
                        )
                }
                .padding(.top, 8)
                
                // Benefits list
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.Colors.primary)
                            .frame(width: 28)
                        Text("Build a stronger chest & arms")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.Colors.primary)
                            .frame(width: 28)
                        Text("Save \(daysSaved)+ days this year")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.Colors.primary)
                            .frame(width: 28)
                        Text("Better focus & mental clarity")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.top, 16)
                
                Spacer()
                
                OnboardingContinueButton("Join ScreenBlock", action: onContinue)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).delay(0.5)) {
                drawChart = true
            }
            // Show labels after chart finishes drawing
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    showLabels = true
                }
            }
        }
    }
}

// MARK: - Phase 12: Benefits Summary

struct OnboardingBenefitsSummaryView: View {
    let currentHours: Double
    let targetHours: Double
    let exerciseFrequency: String
    let onContinue: () -> Void
    
    private var futureDate: String {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM, yyyy"
        return formatter.string(from: date)
    }
    
    private var daysSaved: Int {
        let hoursSaved = currentHours - targetHours
        return Int((hoursSaved * 365) / 24)
    }
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
                Text("You will feel differences by:")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 40)
                
                Text(futureDate)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .stroke(Theme.Colors.primary, lineWidth: 2)
                    )
                    .padding(.top, 8)
                
                // Benefits list
                VStack(alignment: .leading, spacing: 12) {
                    BenefitRow(icon: "dumbbell.fill", text: "Build a stronger chest & arms")
                    BenefitRow(icon: "calendar.badge.clock", text: "Save \(daysSaved)+ days this year")
                    BenefitRow(icon: "brain.head.profile", text: "Better focus & mental clarity")
                    BenefitRow(icon: "arrow.trianglehead.counterclockwise.rotate.90", text: "Break the doomscrolling habit")
                }
                .padding(.top, 24)
                .padding(.horizontal, 32)
                
                Spacer()
                
            // Before/After comparison - Apple Screen Time style
            HStack(spacing: 12) {
                // Before card
                AppleScreenTimeCard(
                    title: "Before",
                    subtitle: "ScreenBlock",
                    subtitleColor: .white,
                    hours: 5,
                    barHeights: [0.9, 0.7, 0.95, 0.6, 0.85, 0.75, 0.8],
                    isHighUsage: true
                )
                
                // After card
                AppleScreenTimeCard(
                    title: "After",
                    subtitle: "ScreenBlock",
                    subtitleColor: Theme.Colors.primary,
                    hours: 2,
                    barHeights: [0.3, 0.25, 0.15, 0.35, 0.2, 0.4, 0.25],
                    isHighUsage: true
                )
            }
            .padding(.horizontal, 20)
                
                Spacer()
                
                // 7-day journey badge
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16))
                    Text("7-Day Journey")
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 16)
                
                // Button triggers Superwall paywall, then continues
                // TODO: Re-enable paywall after testing
                OnboardingContinueButton("Join ScreenBlock", action: {
                    // SuperwallManager.shared.register(placement: "campaign_trigger") {
                    //     onContinue()
                    // }
                    onContinue() // Skip paywall for testing
                })
            }
        }
    }
}

// Apple Screen Time style card
struct AppleScreenTimeCard: View {
    let title: String
    let subtitle: String
    let subtitleColor: Color
    let hours: Int
    let barHeights: [Double] // 7 values from 0-1
    let isHighUsage: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
            
            Text(subtitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(subtitleColor)
            
            Spacer().frame(height: 8)
            
            // Daily Average
            Text("Daily Average")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            
            Text("\(hours) hours")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            
            Spacer().frame(height: 8)
            
            // Apple-style bar chart
            ZStack(alignment: .bottom) {
                // Grid lines (3 dashed lines)
                VStack(spacing: 0) {
                    Spacer()
                    Divider()
                        .background(Color.white.opacity(0.1))
                    Spacer()
                    Divider()
                        .background(Color.white.opacity(0.1))
                    Spacer()
                    Divider()
                        .background(Color.white.opacity(0.1))
                    Spacer()
                }
                .frame(height: 70)
                
                // Bars
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<7, id: \.self) { index in
                        AppleScreenTimeBar(
                            height: barHeights[index],
                            maxHeight: 70,
                            isHighUsage: isHighUsage
                        )
                    }
                }
            }
            .frame(height: 70)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12)) // Darker, cleaner background
        )
    }
}

// Individual bar in the Apple-style chart
struct AppleScreenTimeBar: View {
    let height: Double
    let maxHeight: CGFloat
    let isHighUsage: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Multi-segment bar like Apple's
            if isHighUsage {
                // High usage: multiple color segments stacked seamlessly
                VStack(spacing: 0) {
                    // Top segment (Orange)
                    Rectangle()
                        .fill(Color(red: 1.0, green: 0.58, blue: 0.0)) // Apple Orange
                        .frame(height: max(2, CGFloat(height * 0.15) * maxHeight))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3))
                    
                    // Middle segment (Teal/Blue)
                    Rectangle()
                        .fill(Color(red: 0.2, green: 0.6, blue: 0.8)) // Light Blue
                        .frame(height: max(2, CGFloat(height * 0.35) * maxHeight))
                    
                    // Middle segment (Darker Blue)
                    Rectangle()
                        .fill(Color(red: 0.0, green: 0.48, blue: 1.0)) // System Blue
                        .frame(height: max(2, CGFloat(height * 0.3) * maxHeight))
                    
                    // Bottom segment (Primary Cyan)
                    Rectangle()
                        .fill(Theme.Colors.primary) // Cyan
                        .frame(height: max(2, CGFloat(height * 0.2) * maxHeight))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 0))
                }
            } else {
                // Low usage: just cyan bars
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.Colors.primary)
                    .frame(height: max(8, CGFloat(height) * maxHeight))
            }
        }
        .frame(width: 16)
    }
}

struct BenefitRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 28)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - Phase 13: Paywall (Superwall)

struct OnboardingPaywallView: View {
    let onContinue: () -> Void
    let onRestore: () -> Void
    
    var body: some View {
        Color.clear
            .onAppear {
                // TODO: Re-enable paywall after testing
                // SuperwallManager.shared.register(placement: "campaign_trigger") {
                //     onContinue()
                // }
                onContinue() // Skip paywall for testing
            }
    }
}

// MARK: - Phase 13: Success

struct OnboardingSuccessView: View {
    let userName: String
    let isPreview: Bool
    let onComplete: () -> Void
    @State private var showCheckmark = false
    
    var body: some View {
        ZStack {
            OnboardingBackground()
            
            VStack(spacing: 0) {
            Spacer()
            
            // Animated checkmark
            ZStack {
                Circle()
                    .fill(Theme.Colors.primary.opacity(0.15))
                    .frame(width: 140, height: 140)
                
                Circle()
                    .fill(Theme.Colors.primary)
                    .frame(width: 100, height: 100)
                    .scaleEffect(showCheckmark ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(showCheckmark ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.2), value: showCheckmark)
            }
            
            Text("You're all set\(userName.isEmpty ? "" : ", \(userName)")!")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 32)
            
            Text("Your journey to a healthier\nrelationship with screens starts now.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            
            Spacer()
            
            Button {
                if !isPreview {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                }
                onComplete()
            } label: {
                Text("Let's Go!")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showCheckmark = true
            }
        }
        }
    }
}

// MARK: - Reusable Components

struct SelectableRowButton: View {
    let emoji: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(emoji).font(.system(size: 24))
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.vertical, 16)
            .padding(.trailing, 40) // Always reserve space for checkmark
            .overlay(alignment: .trailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .padding(.trailing, 16)
                    .opacity(isSelected ? 1 : 0)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.white : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
    }
}

struct PermissionCardDark: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)).frame(width: 48, height: 48)
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(description).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
    }
}

#Preview {
    ContentView()
}
