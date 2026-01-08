//
//  TimeLimitSetupView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-30.
//

import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings
import UIKit

/// View for setting up time limits per app/category
struct TimeLimitSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \AppTimeLimit.createdAt, order: .reverse) private var timeLimits: [AppTimeLimit]
    @State private var screenTimeManager = ScreenTimeManager.shared
    @State private var showingCreateLimit = false
    @State private var editingLimit: AppTimeLimit?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
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
                    .padding(.top, Theme.Spacing.md)
                }
            }
            .navigationTitle("App Time Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.primary)
                }
            }
            .sheet(isPresented: $showingCreateLimit) {
                CreateTimeLimitSheet { newLimit in
                    modelContext.insert(newLimit)
                    try? modelContext.save()
                    screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
                    
                    // Sync to Firebase
                    Task {
                        await UserDataManager.shared.saveTimeLimit(newLimit)
                    }
                }
            }
            .sheet(item: $editingLimit) { limitToEdit in
                // Capture immutable values before the sheet dismisses
                let limitId = limitToEdit.id
                let bonusMinutes = limitToEdit.bonusMinutesEarned
                
                EditTimeLimitSheet(limit: limitToEdit, onSave: { newName, newMinutes, newIsActive in
                    print("[EditFlow] onSave received for \(newName) => \(newMinutes) min, active: \(newIsActive)")
                    
                    // Find the limit in our query results using the captured ID
                    guard let limit = timeLimits.first(where: { $0.id == limitId }) else {
                        print("[TimeLimitSetup] ❌ Could not find limit with ID: \(limitId)")
                        return
                    }
                    
                    // Update the limit
                    limit.displayName = newName
                    limit.dailyLimitMinutes = newMinutes
                    limit.isActive = newIsActive
                    
                    print("[TimeLimitSetup] Updating \(newName) to \(newMinutes) min (local + Firebase)")
                    
                    // Save to SwiftData
                    do {
                        try modelContext.save()
                        print("[TimeLimitSetup] ✅ Saved to SwiftData: \(newName) = \(newMinutes) min, active: \(newIsActive)")
                    } catch {
                        print("[TimeLimitSetup] ❌ SwiftData save failed: \(error)")
                    }
                    
                    // Save to Firebase (primary database)
                    Task {
                        await UserDataManager.shared.saveTimeLimitDirect(
                            id: limitId.uuidString,
                            displayName: newName,
                            limitType: limit.limitTypeRaw,
                            dailyLimitMinutes: newMinutes,
                            bonusMinutesEarned: bonusMinutes,
                            isActive: newIsActive,
                            scheduleStartHour: limit.scheduleStartHour,
                            scheduleStartMinute: limit.scheduleStartMinute,
                            scheduleEndHour: limit.scheduleEndHour,
                            scheduleEndMinute: limit.scheduleEndMinute,
                            scheduleDays: Array(limit.scheduleDays)
                        )
                        print("[TimeLimitSetup] ✅ Saved to Firebase: \(newName)")
                    }
                    
                    screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
                }, onDelete: {
                    deleteLimit(limitToEdit)
                })
            }
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
            HStack {
                Text("ACTIVE LIMITS")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1)
                
                Spacer()
                
                if timeLimits.count > 0 {
                    Button {
                        deleteAllLimits()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text("Delete All")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.red.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            
            ForEach(timeLimits) { limit in
                TimeLimitRow(limit: limit) {
                    editingLimit = limit
                } onDelete: {
                    deleteLimit(limit)
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
        let limitId = limit.id.uuidString
        
        if let appToken = limit.getApplicationToken() {
            screenTimeManager.unshieldApp(appToken)
        } else if let categoryToken = limit.getCategoryToken() {
            screenTimeManager.unshieldCategory(categoryToken)
        }
        
        // Remove saved selection
        UserDefaults.standard.removeObject(forKey: "limit_selection_\(limit.id.uuidString)")
        
        modelContext.delete(limit)
        try? modelContext.save()
        screenTimeManager.startMonitoring(limits: timeLimits, context: modelContext)
        
        // Delete from Firebase
        Task {
            await UserDataManager.shared.deleteTimeLimit(id: limitId)
        }
    }
    
    private func deleteAllLimits() {
        for limit in timeLimits {
            if let appToken = limit.getApplicationToken() {
                screenTimeManager.unshieldApp(appToken)
            } else if let categoryToken = limit.getCategoryToken() {
                screenTimeManager.unshieldCategory(categoryToken)
            }
            UserDefaults.standard.removeObject(forKey: "limit_selection_\(limit.id.uuidString)")
            modelContext.delete(limit)
        }
        try? modelContext.save()
        screenTimeManager.stopMonitoring()
    }
}

// MARK: - Create Time Limit Sheet

struct CreateTimeLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let onCreate: (AppTimeLimit) -> Void
    
    @State private var limitName: String = ""
    @State private var selectedLimitType: LimitType = .dailyLimit
    @State private var dailyMinutes: Int = 30
    @State private var selectedApps = FamilyActivitySelection()
    @State private var showingAppPicker = false
    @State private var currentStep = 1
    @FocusState private var isNameFieldFocused: Bool
    
    // Schedule fields
    @State private var scheduleStartTime = Calendar.current.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
    @State private var scheduleEndTime = Calendar.current.date(from: DateComponents(hour: 6, minute: 0)) ?? Date()
    @State private var selectedDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7] // 1=Sunday
    
    private let presetMinutes = [15, 30, 45, 60, 90, 120]
    private let dayNames = ["S", "M", "T", "W", "T", "F", "S"] // Sunday first
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Step indicator
                    stepIndicator
                    
                    if currentStep == 1 {
                        step1NameAndTime
                    } else {
                        step2SelectApps
                    }
                }
            }
            .navigationTitle(currentStep == 1 ? "New Limit" : "Select Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    if currentStep == 1 {
                        Button("Next") {
                            withAnimation {
                                currentStep = 2
                            }
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.primary)
                        .disabled(limitName.isEmpty)
                    } else {
                        Button("Create") {
                            createLimit()
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.primary)
                        .disabled(selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty)
                    }
                }
            }
            .familyActivityPicker(
                isPresented: $showingAppPicker,
                selection: $selectedApps
            )
        }
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...2, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStep ? Theme.Colors.primary : Theme.Colors.cardBorder)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
    }
    
    private var step1NameAndTime: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Name field
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("LIMIT NAME")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .tracking(1.5)
                    
                    TextField("e.g., Social Media, Games", text: $limitName)
                        .font(.system(size: 17))
                        .padding(Theme.Spacing.md)
                        .background(Theme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .focused($isNameFieldFocused)
                        .submitLabel(.done)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.lg)
                
                // Limit Type Picker
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("LIMIT TYPE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .tracking(1.5)
                    
                    HStack(spacing: 10) {
                        ForEach(LimitType.allCases, id: \.self) { type in
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    selectedLimitType = type
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: type == .dailyLimit ? "hourglass" : "calendar.badge.clock")
                                        .font(.system(size: 18))
                                    Text(type.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(selectedLimitType == type ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    selectedLimitType == type
                                    ? Theme.Colors.primary
                                    : Theme.Colors.cardBackground
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    
                    Text(selectedLimitType.description)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                .padding(.horizontal, Theme.Spacing.md)
                
                // Show different UI based on limit type
                if selectedLimitType == .dailyLimit {
                    dailyLimitSettings
                } else {
                    scheduleSettings
                }
                
                Spacer()
            }
        }
    }
    
    private var dailyLimitSettings: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Time selection
            VStack(spacing: Theme.Spacing.md) {
                Text("\(dailyMinutes)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.primary)
                
                Text("minutes per day")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            
            // Preset buttons
            VStack(spacing: Theme.Spacing.md) {
                Text("QUICK SELECT")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1.5)
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(presetMinutes, id: \.self) { minutes in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                dailyMinutes = minutes
                            }
                        } label: {
                            Text(formatMinutes(minutes))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(dailyMinutes == minutes ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    dailyMinutes == minutes
                                    ? Theme.Colors.primary
                                    : Theme.Colors.cardBackground
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            
            // Slider
            VStack(spacing: Theme.Spacing.sm) {
                Slider(
                    value: Binding(
                        get: { Double(dailyMinutes) },
                        set: { dailyMinutes = Int($0) }
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
    }
    
    private var scheduleSettings: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Time Range
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("BLOCK TIME")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1.5)
                
                VStack(spacing: 12) {
                    // Start Time
                    HStack {
                        Text("From")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        DatePicker("", selection: $scheduleStartTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.Colors.primary)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // End Time
                    HStack {
                        Text("To")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        DatePicker("", selection: $scheduleEndTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.Colors.primary)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            
            // Days of Week
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("ACTIVE DAYS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1.5)
                
                HStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { index in
                        let dayNumber = index + 1 // 1 = Sunday
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                if selectedDays.contains(dayNumber) {
                                    selectedDays.remove(dayNumber)
                                } else {
                                    selectedDays.insert(dayNumber)
                                }
                            }
                        } label: {
                            Text(dayNames[index])
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(selectedDays.contains(dayNumber) ? .black : Theme.Colors.textSecondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    selectedDays.contains(dayNumber)
                                    ? Theme.Colors.primary
                                    : Theme.Colors.cardBackground
                                )
                                .clipShape(Circle())
                        }
                    }
                }
                
                // Quick select buttons
                HStack(spacing: 12) {
                    Button {
                        selectedDays = [1, 2, 3, 4, 5, 6, 7]
                    } label: {
                        Text("Every day")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedDays.count == 7 ? Theme.Colors.primary : Theme.Colors.textMuted)
                    }
                    
                    Button {
                        selectedDays = [2, 3, 4, 5, 6] // Mon-Fri
                    } label: {
                        Text("Weekdays")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedDays == [2, 3, 4, 5, 6] ? Theme.Colors.primary : Theme.Colors.textMuted)
                    }
                    
                    Button {
                        selectedDays = [1, 7] // Sun, Sat
                    } label: {
                        Text("Weekends")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedDays == [1, 7] ? Theme.Colors.primary : Theme.Colors.textMuted)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, Theme.Spacing.md)
            
            // Schedule summary
            VStack(spacing: 4) {
                Text("Apps will be blocked")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(scheduleSummary)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Theme.Spacing.md)
        }
    }
    
    private var scheduleSummary: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let startStr = formatter.string(from: scheduleStartTime)
        let endStr = formatter.string(from: scheduleEndTime)
        
        var daysStr: String
        if selectedDays.count == 7 {
            daysStr = "every day"
        } else if selectedDays == [2, 3, 4, 5, 6] {
            daysStr = "on weekdays"
        } else if selectedDays == [1, 7] {
            daysStr = "on weekends"
        } else {
            let dayAbbrevs = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let selectedNames = selectedDays.sorted().compactMap { dayAbbrevs[safe: $0 - 1] }
            daysStr = "on \(selectedNames.joined(separator: ", "))"
        }
        
        return "\(startStr) – \(endStr)\n\(daysStr)"
    }
    
    private var step2SelectApps: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Monitored Apps")
                    .font(Theme.Typography.title())
                    .foregroundStyle(.white)
                
                Text("Apps sharing this \(dailyMinutes) min limit")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.lg)
            
            // Selected apps List
            if !selectedApps.applicationTokens.isEmpty || !selectedApps.categoryTokens.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Apps Section
                        ForEach(Array(selectedApps.applicationTokens), id: \.self) { token in
                            HStack(spacing: 16) {
                                Label(token)
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 56))
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                
                                Label(token)
                                    .labelStyle(.titleOnly)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, 10)
                        }
                        
                        // Categories Section
                        ForEach(Array(selectedApps.categoryTokens), id: \.self) { token in
                            HStack(spacing: 16) {
                                Label(token)
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 56))
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                
                                Label(token)
                                    .labelStyle(.titleOnly)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.bottom, Theme.Spacing.xl)
                }
            } else {
                // Empty state
                Spacer()
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "apps.iphone.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text("No apps selected")
                        .font(Theme.Typography.title())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
            }
            
            // Bottom Action Bar
            VStack(spacing: Theme.Spacing.md) {
                Button {
                    showingAppPicker = true
                } label: {
                    Text(selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty 
                         ? "Choose Apps" 
                         : "Edit Selection")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.Colors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
        }
        .background(Theme.Colors.background)
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
    
    private func createLimit() {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: scheduleStartTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: scheduleEndTime)
        
        let limit = AppTimeLimit(
            displayName: limitName,
            limitType: selectedLimitType,
            dailyLimitMinutes: dailyMinutes,
            scheduleStartHour: startComponents.hour ?? 22,
            scheduleStartMinute: startComponents.minute ?? 0,
            scheduleEndHour: endComponents.hour ?? 6,
            scheduleEndMinute: endComponents.minute ?? 0,
            scheduleDays: selectedDays
        )
        
        // Store all selected apps in one limit
        // For now, we'll use the first app token (simplification)
        // In a full implementation, you'd want to track multiple tokens per limit
        if let firstApp = selectedApps.applicationTokens.first {
            limit.setApplicationToken(firstApp)
        } else if let firstCategory = selectedApps.categoryTokens.first {
            limit.setCategoryToken(firstCategory)
        }
        
        // Store the full selection for monitoring
        if let data = try? PropertyListEncoder().encode(selectedApps) {
            UserDefaults.standard.set(data, forKey: "limit_selection_\(limit.id.uuidString)")
        }
        
        onCreate(limit)
        dismiss()
    }
}

// Safe array subscript for TimeLimitSetupView
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Time Limit Row

struct TimeLimitRow: View {
    let limit: AppTimeLimit
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    // Load the saved selection for this limit
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
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                // Header: Name and Status
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
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
        let overlap: CGFloat = 32 // How much of each icon is visible (rest overlapped)
        let badgeSize: CGFloat = 40 // slightly smaller to visually match icon footprint
        
        return ZStack(alignment: .leading) {
            if let selection = savedSelection {
                let apps = Array(selection.applicationTokens)
                let categories = Array(selection.categoryTokens)
                let totalCount = apps.count + categories.count
                
                // Show up to 8 icons, then a +X badge for overflow
                let showCounter = totalCount > 8
                let maxIcons = showCounter ? 7 : min(totalCount, 8)
                
                let displayApps = Array(apps.prefix(maxIcons))
                let displayCategories = Array(categories.prefix(max(0, maxIcons - displayApps.count)))
                let displayedCount = displayApps.count + displayCategories.count
                
                // Apps
                ForEach(Array(displayApps.enumerated()), id: \.offset) { index, token in
                    Label(token)
                        .labelStyle(.iconOnly)
                        .scaleEffect(1.8)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .offset(x: CGFloat(index) * overlap)
                        .zIndex(Double(10 - index))
                }
                
                // Categories
                ForEach(Array(displayCategories.enumerated()), id: \.offset) { index, token in
                    let position = displayApps.count + index
                    Label(token)
                        .labelStyle(.iconOnly)
                        .scaleEffect(1.8)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .offset(x: CGFloat(position) * overlap)
                        .zIndex(Double(10 - position))
                }
                
                // Counter Badge
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

// MARK: - Edit Time Limit Sheet

struct EditTimeLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let limit: AppTimeLimit
    let onSave: (_ name: String, _ minutes: Int, _ isActive: Bool) -> Void
    let onDelete: () -> Void
    
    @State private var selectedMinutes: Int
    @State private var limitName: String
    @State private var isActive: Bool
    @State private var selectedApps: FamilyActivitySelection
    @State private var showingAppPicker = false
    @State private var showingDeleteConfirmation = false
    
    // Schedule fields
    @State private var scheduleStartTime: Date
    @State private var scheduleEndTime: Date
    @State private var selectedDays: Set<Int>
    
    private let presetMinutes = [15, 30, 45, 60, 90, 120]
    private let dayNames = ["S", "M", "T", "W", "T", "F", "S"]
    
    init(limit: AppTimeLimit, onSave: @escaping (_ name: String, _ minutes: Int, _ isActive: Bool) -> Void, onDelete: @escaping () -> Void) {
        self.limit = limit
        self.onSave = onSave
        self.onDelete = onDelete
        self._selectedMinutes = State(initialValue: limit.dailyLimitMinutes)
        self._limitName = State(initialValue: limit.displayName)
        self._isActive = State(initialValue: limit.isActive)
        
        // Initialize schedule fields from limit
        var startComponents = DateComponents()
        startComponents.hour = limit.scheduleStartHour
        startComponents.minute = limit.scheduleStartMinute
        let startDate = Calendar.current.date(from: startComponents) ?? Date()
        self._scheduleStartTime = State(initialValue: startDate)
        
        var endComponents = DateComponents()
        endComponents.hour = limit.scheduleEndHour
        endComponents.minute = limit.scheduleEndMinute
        let endDate = Calendar.current.date(from: endComponents) ?? Date()
        self._scheduleEndTime = State(initialValue: endDate)
        
        self._selectedDays = State(initialValue: limit.scheduleDays)
        
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
        NavigationStack {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                    .onTapGesture {
                        hideKeyboard()
                    }
                
                ScrollView {
                    editContent
                }
                // Make sure taps on the scroll area also dismiss keyboard
                .contentShape(Rectangle())
                .onTapGesture {
                    hideKeyboard()
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Edit Limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        print("[EditSheet] Save tapped - name: \(limitName), minutes: \(selectedMinutes), active: \(isActive)")
                        
                        // Save app selection to UserDefaults
                        saveSelection()
                        
                        // Update schedule fields on the limit object directly
                        if limit.limitType == .scheduled {
                            let calendar = Calendar.current
                            let startComponents = calendar.dateComponents([.hour, .minute], from: scheduleStartTime)
                            let endComponents = calendar.dateComponents([.hour, .minute], from: scheduleEndTime)
                            
                            limit.scheduleStartHour = startComponents.hour ?? 22
                            limit.scheduleStartMinute = startComponents.minute ?? 0
                            limit.scheduleEndHour = endComponents.hour ?? 6
                            limit.scheduleEndMinute = endComponents.minute ?? 0
                            limit.scheduleDays = selectedDays
                        }
                        
                        // Let parent handle all persistence (SwiftData + Firebase)
                        onSave(limitName, selectedMinutes, isActive)
                        print("[EditSheet] onSave callback completed")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.primary)
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .familyActivityPicker(
                isPresented: $showingAppPicker,
                selection: $selectedApps
            )
        }
    }

    @ViewBuilder
    private var editContent: some View {
        VStack(spacing: 12) {
            nameSection
            
            // Show different UI based on limit type
            if limit.limitType == .scheduled {
                scheduleEditSection
            } else {
                minutesSection
                presetsSection
                sliderSection
            }
            
            toggleSection
            appsEditorSection
            deleteSection
            Spacer(minLength: 24)
        }
    }
    
    private var scheduleEditSection: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Type indicator
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.primary)
                Text("Scheduled Block")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            
            // Time Range
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("BLOCK TIME")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1.5)
                
                VStack(spacing: 12) {
                    HStack {
                        Text("From")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        DatePicker("", selection: $scheduleStartTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.Colors.primary)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    HStack {
                        Text("To")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        DatePicker("", selection: $scheduleEndTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.Colors.primary)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            
            // Days of Week
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("ACTIVE DAYS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .tracking(1.5)
                
                HStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { index in
                        let dayNumber = index + 1
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                if selectedDays.contains(dayNumber) {
                                    selectedDays.remove(dayNumber)
                                } else {
                                    selectedDays.insert(dayNumber)
                                }
                            }
                        } label: {
                            Text(dayNames[index])
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(selectedDays.contains(dayNumber) ? .black : Theme.Colors.textSecondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    selectedDays.contains(dayNumber)
                                    ? Theme.Colors.primary
                                    : Theme.Colors.cardBackground
                                )
                                .clipShape(Circle())
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
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
                in: 5...180,
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
        Toggle(isOn: $isActive) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
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
                        // Apps
                        ForEach(Array(Array(selectedApps.applicationTokens.prefix(6)).enumerated()), id: \.offset) { idx, token in
                            Label(token)
                                .labelStyle(.iconOnly)
                                .scaleEffect(1.8)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .zIndex(Double(100 - idx))
                        }
                        // Categories (fill remaining slots up to 6)
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
                        // Overflow badge
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
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

#Preview {
    TimeLimitSetupView()
}
