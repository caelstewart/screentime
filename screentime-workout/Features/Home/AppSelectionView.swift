//
//  AppSelectionView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import FamilyControls

struct AppSelectionView: View {
    @Binding var selectedCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var screenTimeManager = ScreenTimeManager.shared
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background
                    .ignoresSafeArea()
                
                if screenTimeManager.isAuthorized {
                    // Real Family Activity Picker
                    FamilyActivityPicker(selection: $screenTimeManager.selectedApps)
                        .ignoresSafeArea(.container, edges: .bottom)
                } else {
                    // Authorization needed view
                    authorizationNeededView
                }
            }
            .navigationTitle("Select Apps to Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedCount = screenTimeManager.selectedAppCount
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
        }
    }
    
    // MARK: - Authorization Needed View
    
    private var authorizationNeededView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.primary.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "hourglass.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Colors.primary)
            }
            
            // Text
            VStack(spacing: Theme.Spacing.sm) {
                Text("Screen Time Access Required")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text("Grant access to select which apps to block until you complete your workouts.")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            
            Spacer()
            
            // Request Authorization Button
            Button {
                Task {
                    try? await screenTimeManager.requestAuthorization()
                }
            } label: {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("Grant Access")
                }
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.Gradients.primaryButton)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }
}

#Preview {
    AppSelectionView(selectedCount: .constant(0))
}
