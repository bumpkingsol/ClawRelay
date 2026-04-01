import SwiftUI

struct MeetingsTabView: View {
    @ObservedObject var meetingVM: MeetingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if meetingVM.state == .recording || meetingVM.state == .preparing {
                    liveBanner
                }

                if meetingVM.state == .idle || meetingVM.state == .finalizing {
                    statsStrip
                    subTabPicker
                }

                switch meetingVM.meetingsSubTab {
                case .meetings:
                    meetingsListSection
                case .people:
                    peopleListSection
                }
            }
            .padding(16)
        }
        .onAppear {
            meetingVM.fetchMeetingHistory()
            meetingVM.fetchParticipants()
        }
        .sheet(item: transcriptSheetBinding) { transcript in
            MeetingTranscriptSheet(transcript: transcript, state: meetingVM.transcriptFetchState) {
                meetingVM.dismissTranscript()
            }
        }
    }

    // MARK: - Live Banner

    private var liveBanner: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text("Recording")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(meetingVM.formattedElapsed)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Toggle Sidebar") {
                    meetingVM.toggleSidebar()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Stop") {
                    meetingVM.stopMeeting()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()
            }

            HStack(spacing: 16) {
                Label("Cards: \(meetingVM.firedCardCount)", systemImage: "rectangle.stack")
                if meetingVM.briefing != nil {
                    Label("Briefing loaded", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 12) {
            statCard(title: "This Week", value: "\(meetingVM.meetingHistory.count)", subtitle: "meetings")
            statCard(title: "Total Hours", value: totalHours, subtitle: avgDuration)
            statCard(title: "Top Participant", value: topParticipant, subtitle: "")
            statCard(title: "Pattern", value: topPattern, subtitle: "")
        }
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Sub-Tab Picker

    private var subTabPicker: some View {
        Picker("", selection: $meetingVM.meetingsSubTab) {
            Text("Meetings").tag(MeetingViewModel.MeetingsSubTab.meetings)
            Text("People").tag(MeetingViewModel.MeetingsSubTab.people)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Meetings List

    private var meetingsListSection: some View {
        VStack(spacing: 8) {
            if meetingVM.meetingHistory.isEmpty {
                Text("No meetings recorded yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                ForEach(meetingVM.meetingHistory) { meeting in
                    MeetingRowView(meeting: meeting) {
                        meetingVM.fetchTranscript(for: meeting.id)
                    }
                }
            }
        }
    }

    // MARK: - People List

    private var peopleListSection: some View {
        VStack(spacing: 8) {
            if meetingVM.participantProfiles.isEmpty {
                Text("No participant profiles yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                ForEach(meetingVM.participantProfiles) { participant in
                    ParticipantRowView(participant: participant)
                }
            }
        }
    }

    // MARK: - Computed Stats

    private var totalHours: String {
        let totalSecs = meetingVM.meetingHistory.compactMap(\.durationSeconds).reduce(0, +)
        let hours = Double(totalSecs) / 3600.0
        return String(format: "%.1fh", hours)
    }

    private var avgDuration: String {
        let durations = meetingVM.meetingHistory.compactMap(\.durationSeconds)
        guard !durations.isEmpty else { return "" }
        let avg = durations.reduce(0, +) / durations.count / 60
        return "avg \(avg)min"
    }

    private var topParticipant: String {
        var counts: [String: Int] = [:]
        for meeting in meetingVM.meetingHistory {
            for p in meeting.participants {
                counts[p, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "—"
    }

    private var topPattern: String {
        // Pull from the first participant profile that has patterns
        for p in meetingVM.participantProfiles {
            if let patterns = p.profile?["patterns"]?.stringValue, !patterns.isEmpty {
                return String(patterns.prefix(60))
            }
        }
        return "—"
    }

    private var transcriptSheetBinding: Binding<TranscriptSheetItem?> {
        Binding(
            get: {
                guard let transcript = meetingVM.selectedMeetingTranscript else { return nil }
                return TranscriptSheetItem(response: transcript)
            },
            set: { newValue in
                if newValue == nil {
                    meetingVM.dismissTranscript()
                }
            }
        )
    }
}

private struct TranscriptSheetItem: Identifiable {
    let id = UUID()
    let response: TranscriptResponse
}

private struct MeetingTranscriptSheet: View {
    let transcript: TranscriptSheetItem
    let state: MeetingTranscriptFetchState
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch state {
                    case .loading:
                        ProgressView("Loading transcript…")
                    case .summaryOnly:
                        Text("Raw transcript was purged. Summary is still available.")
                            .foregroundStyle(.secondary)
                    case .missing:
                        Text("Transcript is not available for this meeting.")
                            .foregroundStyle(.secondary)
                    case let .failed(message):
                        Text(message)
                            .foregroundStyle(.red)
                    case .live, .idle:
                        if let segments = transcript.response.transcript, !segments.isEmpty {
                            ForEach(segments) { segment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(segment.speaker)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(segment.text)
                                        .font(.system(size: 12))
                                    Text(segment.ts)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 8)
                            }
                        } else {
                            Text("Transcript is not available for this meeting.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Transcript")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
