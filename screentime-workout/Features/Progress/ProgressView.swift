//
//  ProgressView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI
import SwiftData

struct ProgressDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ProgressViewModel()
    @State private var selectedPeriod: TimePeriod = .week
    
    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        Text("Progress")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    
                    // Period Selector
                    HStack(spacing: 0) {
                        ForEach(TimePeriod.allCases, id: \.self) { period in
                            Button(action: { 
                                withAnimation(.spring(response: 0.3)) {
                                    selectedPeriod = period
                                }
                            }) {
                                Text(period.rawValue)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selectedPeriod == period ? .black : Theme.Colors.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedPeriod == period
                                        ? Theme.Colors.primary
                                        : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(4)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                    
                    // Stats Cards
                    HStack(spacing: 12) {
                        StatCard(
                            title: "Push-ups",
                            value: viewModel.periodPushUps(for: selectedPeriod),
                            icon: "figure.strengthtraining.traditional",
                            color: Theme.Colors.primary
                        )
                        
                        StatCard(
                            title: "Time Earned",
                            value: viewModel.periodMinutes(for: selectedPeriod),
                            suffix: "m",
                            icon: "clock.fill",
                            color: Theme.Colors.success
                        )
                        
                        StatCard(
                            title: "Workouts",
                            value: viewModel.periodWorkouts(for: selectedPeriod),
                            icon: "flame.fill",
                            color: Theme.Colors.reward
                        )
                    }
                    .padding(.horizontal, 16)
                    .animation(.spring(response: 0.3), value: selectedPeriod)
                    
                    // Chart (changes based on selected period)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selectedPeriod.chartTitle)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .tracking(1.5)
                        
                        PeriodChart(data: viewModel.chartData(for: selectedPeriod))
                    }
                    .padding(20)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Theme.Colors.primary.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .animation(.spring(response: 0.3), value: selectedPeriod)
                    
                    // Recent Workouts
                    VStack(alignment: .leading, spacing: 16) {
                        Text("RECENT WORKOUTS")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .tracking(1.5)
                        
                        if viewModel.recentWorkouts.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "figure.strengthtraining.traditional")
                                        .font(.system(size: 32))
                                        .foregroundStyle(Theme.Colors.textMuted)
                                    Text("No workouts yet")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.Colors.textMuted)
                                }
                                .padding(.vertical, 24)
                                Spacer()
                            }
                        } else {
                            ForEach(viewModel.recentWorkouts) { workout in
                                WorkoutRow(workout: workout)
                            }
                        }
                    }
                    .padding(20)
                    .background(Theme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Theme.Colors.primary.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    
                    Spacer(minLength: 100)
                }
            }
        }
        .onAppear {
            print("[ProgressView] Tab appeared")
            let start = Date()
            viewModel.loadData(context: modelContext)
            print(String(format: "[ProgressView] onAppear completed in %.3fs", Date().timeIntervalSince(start)))
        }
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: Int
    var suffix: String = ""
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct PeriodChart: View {
    let data: [ChartData]
    
    private let chartHeight: CGFloat = 120
    private let barWidth: CGFloat = 12
    
    private var maxValue: Int {
        max(data.map { $0.value }.max() ?? 1, 1)
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(data) { item in
                VStack(spacing: 8) {
                    // Bar container - fixed height for all bars
                    ZStack(alignment: .bottom) {
                        // Background track for all bars (same width)
                        Capsule()
                            .fill(item.isHighlighted ? Theme.Colors.primary.opacity(0.2) : Theme.Colors.cardBorder.opacity(0.3))
                            .frame(width: barWidth)
                        
                        // Active Bar
                        if item.value > 0 {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: item.isHighlighted 
                                            ? [Theme.Colors.primary, Theme.Colors.primary.opacity(0.7)]
                                            : [Theme.Colors.primary.opacity(0.6), Theme.Colors.primary.opacity(0.3)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(
                                    width: barWidth,
                                    height: max(CGFloat(item.value) / CGFloat(maxValue) * chartHeight, 8)
                                )
                                .shadow(color: item.isHighlighted ? Theme.Colors.primary.opacity(0.4) : .clear, radius: 4, y: 0)
                        } else {
                            // Zero state dot
                            Circle()
                                .fill(Theme.Colors.cardBorder)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: chartHeight)
                    
                    // Label
                    Text(item.label)
                        .font(.system(size: 10, weight: item.isHighlighted ? .bold : .medium))
                        .foregroundStyle(item.isHighlighted ? Theme.Colors.primary : Theme.Colors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: chartHeight + 30) // Chart height + label space
    }
}

struct WorkoutRow: View {
    let workout: WorkoutSession
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.primary.opacity(0.1))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Colors.primary)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(workout.reps)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("push-ups")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                
                Text(workout.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            
            Spacer()
            
            // Earned time pill
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10))
                Text("\(workout.minutesEarned) min")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Theme.Colors.success)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.Colors.success.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding(.vertical, 8)
        // No background, just a clean row
        .contentShape(Rectangle())
    }
}

// MARK: - View Model

@Observable
class ProgressViewModel {
    var allWorkouts: [WorkoutSession] = []
    var recentWorkouts: [WorkoutSession] = []
    
    func loadData(context: ModelContext) {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        
        do {
            allWorkouts = try context.fetch(descriptor)
            recentWorkouts = Array(allWorkouts.prefix(10))
        } catch {
            print("Failed to fetch workouts: \(error)")
        }
    }
    
    func periodPushUps(for period: TimePeriod) -> Int {
        filterWorkouts(for: period).reduce(0) { $0 + $1.reps }
    }
    
    func periodMinutes(for period: TimePeriod) -> Int {
        filterWorkouts(for: period).reduce(0) { $0 + $1.minutesEarned }
    }
    
    func periodWorkouts(for period: TimePeriod) -> Int {
        filterWorkouts(for: period).count
    }
    
    func chartData(for period: TimePeriod) -> [ChartData] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        switch period {
        case .week:
            // Last 7 days
            return (0..<7).reversed().map { daysAgo in
                let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                let dayWorkouts = allWorkouts.filter { calendar.isDate($0.completedAt, inSameDayAs: date) }
                let total = dayWorkouts.reduce(0) { $0 + $1.reps }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "E"
                
                return ChartData(
                    label: formatter.string(from: date),
                    value: total,
                    isHighlighted: daysAgo == 0
                )
            }
            
        case .month:
            // Last 4 weeks
            return (0..<4).reversed().map { weeksAgo in
                let weekStart = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: today)!
                let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
                
                let weekWorkouts = allWorkouts.filter { $0.completedAt >= weekStart && $0.completedAt < weekEnd }
                let total = weekWorkouts.reduce(0) { $0 + $1.reps }
                
                return ChartData(
                    label: "W\(4 - weeksAgo)",
                    value: total,
                    isHighlighted: weeksAgo == 0
                )
            }
            
        case .year:
            // Last 12 months
            return (0..<12).reversed().map { monthsAgo in
                let monthStart = calendar.date(byAdding: .month, value: -monthsAgo, to: today)!
                let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
                
                let monthWorkouts = allWorkouts.filter { $0.completedAt >= monthStart && $0.completedAt < monthEnd }
                let total = monthWorkouts.reduce(0) { $0 + $1.reps }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                
                return ChartData(
                    label: formatter.string(from: monthStart),
                    value: total,
                    isHighlighted: monthsAgo == 0
                )
            }
            
        case .all:
            // Show by month if we have data, otherwise just show last 6 months
            let months = min(12, max(6, allWorkouts.count > 0 ? 12 : 6))
            return (0..<months).reversed().map { monthsAgo in
                let monthStart = calendar.date(byAdding: .month, value: -monthsAgo, to: today)!
                let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
                
                let monthWorkouts = allWorkouts.filter { $0.completedAt >= monthStart && $0.completedAt < monthEnd }
                let total = monthWorkouts.reduce(0) { $0 + $1.reps }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                
                return ChartData(
                    label: formatter.string(from: monthStart),
                    value: total,
                    isHighlighted: monthsAgo == 0
                )
            }
        }
    }
    
    private func filterWorkouts(for period: TimePeriod) -> [WorkoutSession] {
        let calendar = Calendar.current
        let now = Date()
        
        let startDate: Date
        switch period {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .year:
            startDate = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:
            return allWorkouts
        }
        
        return allWorkouts.filter { $0.completedAt >= startDate }
    }
}

// MARK: - Supporting Types

enum TimePeriod: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"
    
    var chartTitle: String {
        switch self {
        case .week: return "LAST 7 DAYS"
        case .month: return "LAST 4 WEEKS"
        case .year: return "LAST 12 MONTHS"
        case .all: return "ALL TIME"
        }
    }
}

struct ChartData: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let isHighlighted: Bool
}

