# Menu Bar Popover Redesign

**Date:** 2026-03-31
**Status:** Approved

## Problem

The current menu bar popover feels dated, cluttered, and hard to scan. Everything has equal visual weight - health indicators, pause buttons, handoff fields, and meeting status all compete for attention in a flat vertical stack. The primary use cases (checking system health and hitting quick actions) aren't prioritized over secondary features.

## Design Direction

Streamlined hybrid: compact header row with health collapsed when healthy, segmented pause control, native toggle for sensitive mode, and a labeled handoff section with project picker. Comfortable density with breathing room.

## Layout Zones (top to bottom)

### 1. Status Header

Left side: rounded-square icon container (34x34, corner radius 10) with state indicator + two-line text (state label + subtitle). Right side: queue depth number.

**States (driven by `trackingState` enum, which takes priority over `sensitiveMode` bool):**
- **Active:** Green dot in green-tinted container. Subtitle: "N/N services healthy" (green text) - derived by counting loaded services among daemon, watcher, and optionally WhatsApp. Queue shown as quiet gray number.
- **Needs Attention:** Amber warning icon in amber-tinted container. Subtitle: "1 service down" (amber text). Queue shown in amber if elevated. Note: this is intentionally amber (warning) rather than the current red - red is reserved for individual service failure rows inside the health detail card.
- **Paused:** Amber pause icon in amber-tinted container. Subtitle: "Resumes in Xm" (amber text) - updated on each 5-second polling cycle, rounded to nearest minute. If `pauseUntil` is "indefinite", subtitle reads "Paused indefinitely".
- **Sensitive:** Purple shield icon in purple-tinted container. Subtitle: "Reduced capture active" (purple text). When paused while sensitive mode is on, Paused state takes priority for the header display; the sensitive toggle still reflects the `sensitiveMode` bool independently.

Separated from rest by a 1px divider (`rgba(255,255,255,0.06)`).

### 2. Health Detail Card (conditional)

Only appears when `trackingState == .needsAttention` or queue depth > 10.

Amber-tinted card (`rgba(210,153,34,0.06)` background, `rgba(210,153,34,0.12)` border, corner radius 10). Shows rows:
- Daemon: loaded (green) / missing (red)
- Watcher: loaded (green) / missing (red)
- WhatsApp: loaded (green) / missing (red) - only shown if `whatsappLaunchdState` is present
- Queue: count (amber if > 10)

When all services are healthy and queue is normal, this card is hidden entirely.

**Visual order note:** When meeting status is active (Zone 6), it renders between this card and the pause controls. The zone numbers reflect logical grouping, not strict visual order - see Zone 6 for details.

### 3. Pause Controls

**When active/sensitive:** Segmented control (iOS-style). Three segments: `Pause 15m | Pause 1h | Until Tmrw`. Container: `rgba(255,255,255,0.04)` background, 1px border, corner radius 10, 3px internal padding. Each segment: corner radius 8, 7px vertical padding, 11px font.

**When paused:** Segmented control is replaced by a single full-width "Resume Tracking" button. Green tint: `rgba(63,185,80,0.10)` background, `rgba(63,185,80,0.20)` border, green text. Play icon prefix.

### 4. Sensitive Mode Toggle

Full-width row: icon + "Sensitive Mode" label on left, native macOS `Toggle` on right. Background: `rgba(255,255,255,0.03)`, corner radius 10, 8px vertical / 12px horizontal padding.

When active, the toggle is on and the row could optionally get a subtle purple tint.

### 5. Handoff Section

Separated by a 1px divider. Section label: "HANDOFF TO JC" in uppercase micro text (10px, `#484f58`, 0.8px letter spacing).

- **Project picker:** Full-width dropdown row. Shows currently selected project with a small down-caret on the right. Background: `rgba(255,255,255,0.04)`, border: `rgba(255,255,255,0.08)`, corner radius 8. Menu contains `portfolioProjects` list.
- **Task input + send:** HStack with text field ("What should JC do?") and a 30x30 send button (up-arrow icon, blue tint). Same styling as project picker for the text field.
- **"Sent" confirmation:** Brief green "Sent" text appears next to send button for 2 seconds after successful handoff.

### 6. Meeting Status (conditional, renders between Zone 2 and Zone 3)

Only appears when `meetingViewModel.state != .idle`. Slides in between the health detail card (or status header if health card is hidden) and the pause controls. Same design as current `MeetingStatusView` but adapted to match new card radius/color system:
- Corner radius 10 (matching other cards)
- Same subtle background treatment
- Pulse animation on recording icon preserved

### 7. Footer

Centered "Control Center" text link with arrow glyph. 11px, `#484f58`. Not a button - just a tappable text. Opens the Control Center window.

## What Moves to Control Center

- **Dashboard summary** (current project, hours, JC activity, focus level) - was not a primary popover use case
- **WhatsApp section** - secondary feature, better suited to a dedicated tab

## Popover Dimensions

- Width: 340px (unchanged)
- Padding: 20px
- Height: dynamic, driven by content. Shorter in happy path (no health card, no meeting), taller when problems detected or meeting active.

## Color System

| State | Icon BG | Icon/Text Color | Hex |
|-------|---------|-----------------|-----|
| Active | `rgba(63,185,80,0.12)` | Green | `#3fb950` |
| Paused | `rgba(210,153,34,0.12)` | Amber | `#d29922` |
| Sensitive | `rgba(139,92,246,0.12)` | Purple | `#8b5cf6` |
| Needs Attention | `rgba(210,153,34,0.12)` | Amber | `#d29922` |
| Error/Missing | - | Red | `#f85149` |

Card backgrounds: `rgba(255,255,255,0.04)` with `rgba(255,255,255,0.06-0.08)` borders.
Main background: existing `DarkUtilityGlass.background` gradient.

## Typography

- State label: 14px, semibold, -0.2 letter spacing
- State subtitle: 10px, state color
- Segment labels: 11px, medium weight
- Section labels: 10px, uppercase, 0.8px letter spacing, `#484f58`
- Input placeholder: 11px, `#484f58`
- Footer: 11px, `#484f58`

## Files to Modify

| File | Change |
|------|--------|
| `Views/MenuBarPopoverView.swift` | New layout structure, zone ordering, conditional sections |
| `Views/StatusHeaderView.swift` | Rounded-square icon container, two-line layout, right-aligned queue |
| `Views/HealthDetailCard.swift` | New file replacing `HealthStripView` in the popover. Conditional visibility, row-based layout. `HealthStripView.swift` remains for potential Control Center use. |
| `Views/QuickActionsGrid.swift` | Replace with segmented control + resume button swap |
| `Theme/DarkUtilityGlass.swift` | Add new `popoverCardRadius: CGFloat = 10` constant (keep existing `cardCornerRadius = 18` for Control Center), new color constants, icon container style |
| `Views/MeetingStatusView.swift` | Adjust corner radius and background to match new system |
| `Views/WhatsAppSectionView.swift` | Remove from popover (keep file for Control Center use) |

## Files NOT Modified

- `ViewModels/MenuBarViewModel.swift` - Minor addition only: a computed property for the health summary string (e.g., `"3/3 services healthy"`). No structural changes.
- `OpenClawHelperApp.swift` - No structural changes
- `Views/ControlCenterView.swift` - Out of scope (dashboard summary migration is a separate task)

## Interactions

- **Tap "Pause 15m" segment:** Calls `viewModel.pause(seconds: 900)`
- **Tap "Pause 1h" segment:** Calls `viewModel.pause(seconds: 3600)`
- **Tap "Until Tmrw" segment:** Calls `viewModel.pauseUntilTomorrow()`
- **Tap Resume button:** Calls `viewModel.resume()`
- **Toggle sensitive:** Calls `viewModel.setSensitiveMode(_:)`
- **Select project:** Updates `viewModel.handoffProject` via Menu picker
- **Submit task:** Calls `viewModel.sendQuickHandoff()` on Return or send button tap
- **Tap Control Center:** Opens window via `openWindow(id:)` + `NSApp.activate`

## Animation

- Health detail card: slide in/out with `.transition(.opacity.combined(with: .move(edge: .top)))` when state changes
- Meeting section: same slide transition
- Segmented control to Resume button: cross-fade transition
- Send confirmation: fade in/out over 2 seconds
