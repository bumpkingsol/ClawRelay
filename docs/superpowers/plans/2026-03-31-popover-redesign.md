# Popover Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the macOS menu bar popover to be visually polished with clear hierarchy - health collapsed when healthy, segmented pause control, native sensitive toggle, labeled handoff section with project picker.

**Architecture:** Pure SwiftUI view layer changes. Existing ViewModels and data models stay intact. New `HealthDetailCard` view replaces `HealthStripView` in the popover. Theme file gets new popover-specific constants. One small computed property added to `BridgeSnapshot` for the health summary string.

**Tech Stack:** SwiftUI, macOS 14+, SF Symbols

**Spec:** `docs/superpowers/specs/2026-03-31-popover-redesign-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Theme/DarkUtilityGlass.swift` | Modify | Add popover-specific constants, state colors |
| `Models/BridgeSnapshot.swift` | Modify | Add `healthSummary` and `healthyCount`/`totalServiceCount` computed properties |
| `Views/StatusHeaderView.swift` | Rewrite | New layout: icon container + two-line text + right-aligned queue |
| `Views/HealthDetailCard.swift` | Create | Conditional amber card with per-service health rows |
| `Views/QuickActionsGrid.swift` | Rewrite | Segmented pause control + resume button swap + sensitive toggle |
| `Views/MeetingStatusView.swift` | Modify | Update corner radius and background to match new system |
| `Views/MenuBarPopoverView.swift` | Rewrite | New zone-based layout, remove dashboard/WhatsApp, add transitions |

All paths relative to `mac-helper/OpenClawHelper/`.

**Note:** `WhatsAppSectionView.swift` is already absent from the popover view - no removal action needed. The file is kept for future Control Center use.

**Note:** Health summary properties (`healthSummary`, `isFullyHealthy`, etc.) live on `BridgeSnapshot` rather than `MenuBarViewModel` as originally noted in the spec. This is a better fit since the model owns the data. The spec's "Files NOT Modified" note about ViewModel is superseded.

---

### Task 1: Theme Constants

**Files:**
- Modify: `mac-helper/OpenClawHelper/Theme/DarkUtilityGlass.swift`

- [ ] **Step 1: Add popover constants and state colors**

Add below the existing `compactBody` line (line 18):

```swift
    // Popover-specific
    static let popoverCardRadius: CGFloat = 10
    static let popoverSegmentRadius: CGFloat = 8

    // State colors
    static let activeGreen = Color(red: 0.247, green: 0.725, blue: 0.314)       // #3fb950
    static let warningAmber = Color(red: 0.824, green: 0.600, blue: 0.133)       // #d29922
    static let sensitivePurple = Color(red: 0.545, green: 0.361, blue: 0.965)    // #8b5cf6
    static let errorRed = Color(red: 0.973, green: 0.318, blue: 0.286)           // #f85149
    static let accentBlue = Color(red: 0.345, green: 0.651, blue: 1.0)           // #58a6ff
    static let mutedGray = Color(red: 0.302, green: 0.341, blue: 0.376)          // #4d5761

    // Card backgrounds
    static let cardBackground = Color.white.opacity(0.04)
    static let cardBorder = Color.white.opacity(0.06)
    static let subtleBackground = Color.white.opacity(0.03)
    static let divider = Color.white.opacity(0.06)

    // Section label style
    static let sectionLabel = Font.system(size: 10).weight(.medium)
    static let sectionLabelColor = Color(red: 0.282, green: 0.310, blue: 0.345) // #484f58
```

- [ ] **Step 2: Build to verify no compilation errors**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Theme/DarkUtilityGlass.swift
git commit -m "feat(theme): add popover-specific constants and state colors"
```

---

### Task 2: Health Summary Computed Property

**Files:**
- Modify: `mac-helper/OpenClawHelper/Models/BridgeSnapshot.swift`

- [ ] **Step 1: Add computed properties to BridgeSnapshot**

Add above the `static let placeholder` line (line 29):

```swift
    var totalServiceCount: Int {
        whatsappLaunchdState != nil ? 3 : 2
    }

    var healthyServiceCount: Int {
        var count = 0
        if daemonLaunchdState == "loaded" { count += 1 }
        if watcherLaunchdState == "loaded" { count += 1 }
        if let wa = whatsappLaunchdState, wa == "loaded" { count += 1 }
        return count
    }

    var healthSummary: String {
        "\(healthyServiceCount)/\(totalServiceCount) services healthy"
    }

    var isFullyHealthy: Bool {
        healthyServiceCount == totalServiceCount && queueDepth <= 10
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Models/BridgeSnapshot.swift
git commit -m "feat(model): add health summary computed properties to BridgeSnapshot"
```

---

### Task 3: Redesign StatusHeaderView

**Files:**
- Rewrite: `mac-helper/OpenClawHelper/Views/StatusHeaderView.swift`

- [ ] **Step 1: Rewrite StatusHeaderView with new layout**

Replace the entire file content with:

```swift
import SwiftUI

struct StatusHeaderView: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        HStack(alignment: .center) {
            // Icon container
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(stateColor.opacity(0.12))
                .frame(width: 34, height: 34)
                .overlay {
                    stateIcon
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(stateLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)

                Text(stateSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
            }

            Spacer()

            Text("Queue: \(snapshot.queueDepth)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(snapshot.queueDepth > 10 ? DarkUtilityGlass.warningAmber : DarkUtilityGlass.mutedGray)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            DarkUtilityGlass.divider.frame(height: 1)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch snapshot.trackingState {
        case .active:
            Circle()
                .fill(DarkUtilityGlass.activeGreen)
                .frame(width: 10, height: 10)
                .shadow(color: DarkUtilityGlass.activeGreen.opacity(0.27), radius: 4)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.warningAmber)
        case .sensitive:
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.sensitivePurple)
        case .needsAttention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.warningAmber)
        }
    }

    private var stateLabel: String {
        switch snapshot.trackingState {
        case .active: return "Active"
        case .paused: return "Paused"
        case .sensitive: return "Sensitive Mode"
        case .needsAttention: return "Needs Attention"
        }
    }

    private var stateSubtitle: String {
        switch snapshot.trackingState {
        case .active:
            return snapshot.healthSummary
        case .paused:
            return pauseSubtitle
        case .sensitive:
            return "Reduced capture active"
        case .needsAttention:
            let down = snapshot.totalServiceCount - snapshot.healthyServiceCount
            return "\(down) service\(down == 1 ? "" : "s") down"
        }
    }

    private var pauseSubtitle: String {
        guard let until = snapshot.pauseUntil, until != "indefinite" else {
            return "Paused indefinitely"
        }
        if let epoch = TimeInterval(until) {
            let remaining = epoch - Date().timeIntervalSince1970
            if remaining <= 0 { return "Resuming..." }
            let minutes = Int(ceil(remaining / 60))
            if minutes >= 60 {
                let hours = minutes / 60
                return "Resumes in \(hours)h \(minutes % 60)m"
            }
            return "Resumes in \(minutes)m"
        }
        return "Until \(until)"
    }

    private var stateColor: Color {
        switch snapshot.trackingState {
        case .active: return DarkUtilityGlass.activeGreen
        case .paused: return DarkUtilityGlass.warningAmber
        case .sensitive: return DarkUtilityGlass.sensitivePurple
        case .needsAttention: return DarkUtilityGlass.warningAmber
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/StatusHeaderView.swift
git commit -m "feat(ui): redesign StatusHeaderView with icon container and health summary"
```

---

### Task 4: Create HealthDetailCard

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/HealthDetailCard.swift`

- [ ] **Step 1: Create HealthDetailCard.swift**

```swift
import SwiftUI

struct HealthDetailCard: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        VStack(spacing: 6) {
            healthRow("Daemon", value: snapshot.daemonLaunchdState)
            healthRow("Watcher", value: snapshot.watcherLaunchdState)
            if let waState = snapshot.whatsappLaunchdState {
                healthRow("WhatsApp", value: waState)
            }
            healthRow("Queue", value: "\(snapshot.queueDepth) pending",
                       isHealthy: snapshot.queueDepth <= 10,
                       warnColor: DarkUtilityGlass.warningAmber)
        }
        .padding(10)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(DarkUtilityGlass.warningAmber.opacity(0.06))
                .strokeBorder(DarkUtilityGlass.warningAmber.opacity(0.12), lineWidth: 1)
        )
    }

    private func healthRow(_ label: String, value: String, isHealthy: Bool? = nil, warnColor: Color = DarkUtilityGlass.errorRed) -> some View {
        let healthy = isHealthy ?? (value == "loaded")
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(healthy ? DarkUtilityGlass.activeGreen : warnColor)
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

The project uses explicit `PBXFileReference` entries. Add the new file to the Xcode project so it compiles:

```bash
cd mac-helper && ruby -e '
  proj = File.read("OpenClawHelper.xcodeproj/project.pbxproj")

  # Find the PBXFileReference for HealthStripView to use as anchor
  anchor = proj[/.*HealthStripView\.swift.*PBXFileReference.*\n/] ||
           proj[/.*PBXFileReference.*HealthStripView\.swift.*\n/]

  if anchor.nil?
    # Try line-by-line approach
    lines = proj.lines
    idx = lines.index { |l| l.include?("HealthStripView.swift") && l.include?("PBXFileReference") }
    anchor = lines[idx] if idx
  end

  puts anchor ? "Found anchor" : "WARNING: anchor not found"
'
```

If the project uses folder references or auto-discovery, the file may already be found. Run a build to check:

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`

If build fails with "Cannot find HealthDetailCard in scope", open `OpenClawHelper.xcodeproj` in Xcode and drag `Views/HealthDetailCard.swift` into the Views group, then close Xcode.

- [ ] **Step 3: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/HealthDetailCard.swift mac-helper/OpenClawHelper.xcodeproj/project.pbxproj
git commit -m "feat(ui): add HealthDetailCard for conditional health display"
```

---

### Task 5: Redesign QuickActionsGrid (Segmented Control + Sensitive Toggle)

**Files:**
- Rewrite: `mac-helper/OpenClawHelper/Views/QuickActionsGrid.swift`

- [ ] **Step 1: Rewrite QuickActionsGrid with segmented control and sensitive toggle**

Replace the entire file content with:

```swift
import SwiftUI

struct QuickActionsGrid: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 12) {
            pauseControl
            sensitiveToggle
        }
    }

    @ViewBuilder
    private var pauseControl: some View {
        if viewModel.snapshot.trackingState == .paused {
            // Resume button
            Button(action: { viewModel.resume() }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                    Text("Resume Tracking")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DarkUtilityGlass.activeGreen)
            .background(
                RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                    .fill(DarkUtilityGlass.activeGreen.opacity(0.10))
                    .strokeBorder(DarkUtilityGlass.activeGreen.opacity(0.20), lineWidth: 1)
            )
        } else {
            // Segmented pause control
            HStack(spacing: 0) {
                pauseSegment("Pause 15m") { viewModel.pause(seconds: 900) }
                pauseSegment("Pause 1h") { viewModel.pause(seconds: 3600) }
                pauseSegment("Until Tmrw") { viewModel.pauseUntilTomorrow() }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                    .fill(DarkUtilityGlass.cardBackground)
                    .strokeBorder(DarkUtilityGlass.cardBorder, lineWidth: 1)
            )
        }
    }

    private func pauseSegment(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverSegmentRadius)
                        .fill(Color.white.opacity(0.001)) // hit target
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SegmentButtonStyle())
    }

    private var sensitiveToggle: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Sensitive Mode")
                .font(.system(size: 12))

            Spacer()

            Toggle("", isOn: Binding(
                get: { viewModel.snapshot.sensitiveMode },
                set: { viewModel.setSensitiveMode($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(viewModel.snapshot.sensitiveMode
                      ? DarkUtilityGlass.sensitivePurple.opacity(0.06)
                      : DarkUtilityGlass.subtleBackground)
        )
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering || configuration.isPressed ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverSegmentRadius)
                    .fill(configuration.isPressed
                          ? Color.white.opacity(0.08)
                          : isHovering ? Color.white.opacity(0.05) : Color.clear)
            )
            .onHover { isHovering = $0 }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/QuickActionsGrid.swift
git commit -m "feat(ui): replace action buttons with segmented control and sensitive toggle"
```

---

### Task 6: Update MeetingStatusView

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/MeetingStatusView.swift`

- [ ] **Step 1: Update corner radius and background**

In `MeetingStatusView.swift`, replace the background modifier on line 49:

Old:
```swift
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
```

New:
```swift
        .background(
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(DarkUtilityGlass.cardBackground)
                .strokeBorder(DarkUtilityGlass.cardBorder, lineWidth: 1)
        )
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingStatusView.swift
git commit -m "feat(ui): update MeetingStatusView to match new popover card style"
```

---

### Task 7: Rewrite MenuBarPopoverView (Main Assembly)

**Files:**
- Rewrite: `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift`

This is the main popover layout that assembles all zones. Depends on all previous tasks.

- [ ] **Step 1: Rewrite MenuBarPopoverView with new zone layout**

Replace the entire file content with:

```swift
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            // Zone 1: Status Header
            StatusHeaderView(snapshot: viewModel.snapshot)

            // Zone 2: Health Detail Card (conditional)
            if !viewModel.snapshot.isFullyHealthy {
                HealthDetailCard(snapshot: viewModel.snapshot)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zone 6: Meeting Status (between health and pause when active)
            if meetingViewModel.state != .idle {
                MeetingStatusView(viewModel: meetingViewModel)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zone 3 + 4: Pause Controls & Sensitive Toggle
            QuickActionsGrid(viewModel: viewModel)

            // Divider before handoff
            DarkUtilityGlass.divider.frame(height: 1)

            // Zone 5: Handoff Section
            handoffSection

            // Zone 7: Footer
            Button(action: openControlCenter) {
                Text("Control Center \(Image(systemName: "arrow.up.right"))")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 340)
        .background(DarkUtilityGlass.background)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: viewModel.snapshot.trackingState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.snapshot.isFullyHealthy)
        .animation(.easeInOut(duration: 0.25), value: meetingViewModel.state)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Handoff Section

    private var handoffSection: some View {
        VStack(spacing: 8) {
            // Section label
            HStack {
                Text("HANDOFF TO JC")
                    .font(DarkUtilityGlass.sectionLabel)
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
                    .tracking(0.8)
                Spacer()
            }

            // Project picker
            Menu {
                ForEach(MenuBarViewModel.portfolioProjects, id: \.self) { project in
                    Button(project.capitalized) {
                        viewModel.handoffProject = project
                    }
                }
            } label: {
                HStack {
                    Text(viewModel.handoffProject.isEmpty ? "Select project" : viewModel.handoffProject)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.handoffProject.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DarkUtilityGlass.cardBackground)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)

            // Task input + send
            HStack(spacing: 6) {
                TextField("What should JC do?", text: $viewModel.handoffTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DarkUtilityGlass.cardBackground)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .onSubmit {
                        if !viewModel.handoffTask.isEmpty {
                            viewModel.sendQuickHandoff()
                        }
                    }

                if viewModel.handoffSent {
                    Text("Sent")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkUtilityGlass.activeGreen)
                        .transition(.opacity)
                }

                Button(action: { viewModel.sendQuickHandoff() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DarkUtilityGlass.accentBlue)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DarkUtilityGlass.accentBlue.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.handoffTask.isEmpty)
            }
        }
    }

    private func openControlCenter() {
        openWindow(id: "control-center")
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift
git commit -m "feat(ui): rewrite popover layout with zone-based design"
```

---

### Task 8: Visual Verification

No code changes. Run the app and verify all three states visually.

- [ ] **Step 1: Build and run**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Launch app and verify healthy state**

Open the menu bar popover. Verify:
- Green dot in rounded-square container
- "Active" label + "N/N services healthy" subtitle
- Queue count in top-right corner
- Segmented pause control with three segments
- Sensitive toggle with switch
- "HANDOFF TO JC" section with project picker and task input
- "Control Center" footer link
- Health detail card is NOT visible

- [ ] **Step 3: Verify problem state**

Simulate a problem (stop the daemon or watcher). Verify:
- Header changes to amber "Needs Attention"
- Health detail card slides in with per-service rows
- Each service shows green/red status

- [ ] **Step 4: Verify paused state**

Click "Pause 15m". Verify:
- Header changes to "Paused" with countdown
- Segmented control replaced by green "Resume Tracking" button
- Clicking Resume restores active state and segmented control

- [ ] **Step 5: Verify handoff**

Select a project from the picker, type a task, press Return or click send. Verify:
- "Sent" confirmation appears briefly
- Task field clears after send
