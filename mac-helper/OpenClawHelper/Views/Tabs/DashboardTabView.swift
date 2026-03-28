import SwiftUI

struct DashboardTabView: View {
    @StateObject var viewModel: DashboardViewModel

    var body: some View {
        Group {
            if let data = viewModel.data {
                dashboardContent(data)
            } else if let error = viewModel.lastError {
                errorState(error)
            } else {
                loadingState
            }
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to server...")
                .font(DarkUtilityGlass.monoCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(DarkUtilityGlass.compactBody)
                .foregroundStyle(.secondary)
            Button("Retry") {
                viewModel.lastError = nil
                viewModel.refreshDashboard()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dashboard Content

    private func dashboardContent(_ data: DashboardData) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Stale daemon warning
                if data.status.daemonStale, let lastActivity = data.status.lastActivity {
                    staleBanner(lastActivity)
                }

                // Top row: 3 status cards
                HStack(spacing: 12) {
                    nowCard(data)
                    focusCard(data)
                    jcCard(data)
                }

                // Middle: Time allocation
                timeAllocationCard(data)

                // Bottom row: 2 panels
                HStack(alignment: .top, spacing: 12) {
                    needsAttentionPanel(data)
                    recentHandoffsPanel(data)
                }

                historySection(data)
            }
            .padding(20)
        }
    }

    // MARK: - Stale Banner

    private func staleBanner(_ lastActivity: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Daemon data may be stale (last activity: \(relativeTime(lastActivity)))")
                .font(DarkUtilityGlass.monoCaption)
                .foregroundStyle(.yellow)
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - NOW Card

    private func nowCard(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NOW")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(data.status.idleState == "active" ? .green : .orange)
                    .frame(width: 8, height: 8)
            }

            Text(data.status.currentProject.isEmpty ? "Unknown" : data.status.currentProject)
                .font(.title3.bold())
                .lineLimit(1)

            Text(data.status.currentApp)
                .font(DarkUtilityGlass.monoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let projectTime = data.timeAllocation.first(where: { $0.project.lowercased() == data.status.currentProject.lowercased() }) {
                Text(String(format: "%.1fh today (%d%%)", projectTime.hours, projectTime.percentage))
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - FOCUS Card

    private func focusCard(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOCUS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(focusColor(data.status.focusLevel))
                    .frame(width: 8, height: 8)
            }

            Text(data.status.focusLevel.capitalized)
                .font(.title3.bold())

            if let mode = data.status.focusMode, !mode.isEmpty {
                Text(mode)
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
            }

            Text(String(format: "%.1f switches/hr", data.status.focusSwitchesPerHour))
                .font(DarkUtilityGlass.monoCaption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - JC Card

    private func jcCard(_ data: DashboardData) -> some View {
        let inProgress = data.jcActivity.first(where: { $0.status == "in-progress" })

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("JC")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(inProgress != nil ? .green : .gray)
                    .frame(width: 8, height: 8)
            }

            Text(inProgress != nil ? "Working" : "Idle")
                .font(.title3.bold())

            if let task = inProgress {
                Text(task.description)
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("No active tasks")
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Time Allocation

    private func timeAllocationCard(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIME ALLOCATION")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(data.timeAllocation) { project in
                HStack(spacing: 10) {
                    Text(project.project)
                        .font(DarkUtilityGlass.monoCaption)
                        .frame(width: 90, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.08))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(projectColor(project.project))
                                .frame(width: max(0, geo.size.width * CGFloat(project.percentage) / 100.0), height: 8)
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.1fh", project.hours))
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    Text("\(project.percentage)%")
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Needs Attention Panel

    private func needsAttentionPanel(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEEDS ATTENTION")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            let neglected = data.neglected.filter { $0.days > 2 }.sorted { $0.days > $1.days }
            let inProgressJC = data.jcActivity.filter { $0.status == "in-progress" }
            let completedJC = Array(data.jcActivity.filter { $0.status == "completed" }.prefix(3))

            if neglected.isEmpty && inProgressJC.isEmpty && completedJC.isEmpty {
                Text("Nothing flagged")
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            // Neglected projects
            ForEach(neglected) { project in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(project.project)
                        .font(DarkUtilityGlass.monoCaption)
                    Spacer()
                    Text("\(project.days)d ago")
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }

            // JC in-progress items
            ForEach(inProgressJC) { entry in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(entry.description)
                        .font(DarkUtilityGlass.monoCaption)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // JC completed items
            ForEach(completedJC) { entry in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(entry.description)
                        .font(DarkUtilityGlass.monoCaption)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }

    // MARK: - Recent Handoffs Panel

    private func recentHandoffsPanel(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT HANDOFFS")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if data.handoffs.isEmpty {
                Text("No handoffs")
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            ForEach(Array(data.handoffs.prefix(5))) { handoff in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(handoff.task)
                            .font(DarkUtilityGlass.monoCaption)
                            .lineLimit(1)
                        Text(handoff.project)
                            .font(DarkUtilityGlass.monoCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(handoff.status)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(handoffStatusColor(handoff.status).opacity(0.2), in: Capsule())
                        .foregroundStyle(handoffStatusColor(handoff.status))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }

    // MARK: - History Section

    private func historySection(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This Week")
                    .font(.headline)
                Spacer()
                Picker("", selection: $viewModel.historyDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: viewModel.historyDays) { _ in
                    viewModel.refreshDashboard()
                }
            }

            let entries = data.history ?? []
            if entries.isEmpty {
                Text("No historical data yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                let grouped = Dictionary(grouping: entries, by: { $0.date })
                let sortedDates = grouped.keys.sorted(by: >)

                ForEach(Array(sortedDates.prefix(viewModel.historyDays)), id: \.self) { date in
                    let dayEntries = grouped[date] ?? []
                    let totalHours = dayEntries.reduce(0) { $0 + $1.hours }

                    HStack(spacing: 8) {
                        Text(formatDayLabel(date))
                            .font(DarkUtilityGlass.monoCaption)
                            .frame(width: 36, alignment: .leading)

                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(dayEntries.sorted(by: { $0.hours > $1.hours })) { entry in
                                    let fraction = totalHours > 0 ? entry.hours / totalHours : 0
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(projectColor(entry.project))
                                        .frame(width: max(geo.size.width * fraction, 2))
                                }
                            }
                        }
                        .frame(height: 12)

                        Text("\(totalHours, specifier: "%.1f")h")
                            .font(DarkUtilityGlass.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .glassCard()
    }

    private func formatDayLabel(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE"
        return dayFormatter.string(from: date)
    }

    // MARK: - Color Helpers

    private func focusColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "focused": return .green
        case "multitasking": return .orange
        case "scattered": return .red
        default: return .secondary
        }
    }

    private func projectColor(_ project: String) -> Color {
        switch project.lowercased() {
        case "project-gamma": return .green
        case "project-alpha": return .blue
        case "project-beta": return .orange
        case "project-delta": return .purple
        case "openclaw": return .cyan
        default: return .gray
        }
    }

    private func handoffStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "completed": return .green
        case "in-progress": return .orange
        default: return .secondary
        }
    }

    // MARK: - Relative Time Helper

    private func relativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString) else {
            return "unknown"
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400)) days ago"
    }
}
