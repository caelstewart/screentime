# Screentime Workout - Setup Guide

## Quick Start

### 1. Add Family Controls Capability
1. Select target → **Signing & Capabilities** → **+ Capability** → **Family Controls**

### 2. Create App Group (Required for Extension)
1. Select target → **Signing & Capabilities** → **+ Capability** → **App Groups**
2. Add: `group.app.screentime-workout`

### 3. Build and Run
- Test on a **real device** (FamilyControls has limited simulator support)

---

## How Time Limits Work

### User Flow:
1. **User sets daily limit**: "Instagram - 30 min/day"
2. **User uses app normally** - no blocking initially
3. **DeviceActivity monitors usage** in the background
4. **When limit is reached** → App gets blocked with a shield
5. **User completes workout** → Earns bonus time, app unblocks
6. **Next day** → Limits reset, cycle repeats

### Key Components:

| Component | Purpose |
|-----------|---------|
| `AppTimeLimit` | SwiftData model storing per-app limits |
| `ScreenTimeManager` | Manages monitoring and shields |
| `DeviceActivityMonitor` | Extension that applies shields when limits hit |
| `TimeLimitSetupView` | UI for setting limits |

---

## Creating the DeviceActivityMonitor Extension

The extension runs as a separate process and is called by iOS when usage thresholds are reached.

### Step 1: Add Extension Target
1. **File → New → Target**
2. Search for **Device Activity Monitor Extension**
3. Name it: `DeviceActivityMonitorExtension`
4. Set **Team** and **Bundle Identifier**: `app.screentime-workout.DeviceActivityMonitor`

### Step 2: Add Capabilities to Extension
1. Select the extension target
2. **Signing & Capabilities** → **+ Capability** → **Family Controls**
3. **Signing & Capabilities** → **+ Capability** → **App Groups**
4. Add the same App Group: `group.app.screentime-workout`

### Step 3: Copy Extension Code
Replace the generated `DeviceActivityMonitorExtension.swift` with the code in:
`DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.swift`

### Step 4: Update Info.plist
The extension's Info.plist needs:
```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.deviceactivity.monitor</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).DeviceActivityMonitorExtension</string>
</dict>
```

---

## Customizing the Shield (Restricted Screen)

To replace the default "Restricted" screen with your own branding:

### Step 1: Add Shield Configuration Target
1. **File → New → Target**
2. Search for **Shield Configuration Extension**
3. Name it: `ShieldConfigurationExtension`
4. Set **Team** and **Bundle Identifier**: `app.screentime-workout.ShieldConfiguration`

### Step 2: Copy Extension Code
Replace the generated `ShieldConfigurationExtension.swift` with the code in:
`ShieldConfigurationExtension/ShieldConfigurationExtension.swift`

This will style the restricted screen with:
- Dark background (Neon theme)
- Custom title: "Limit Reached"
- Custom subtitle prompting for a workout
- "Earn More Time" button that opens your app
- "Close" button

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Main App Process                         │
├─────────────────────────────────────────────────────────────┤
│  TimeLimitSetupView                                         │
│    └── Creates AppTimeLimit records in SwiftData            │
│    └── Calls ScreenTimeManager.startMonitoring()            │
│                                                             │
│  ScreenTimeManager                                          │
│    └── Sets up DeviceActivitySchedule (daily)               │
│    └── Creates DeviceActivityEvents for each limit          │
│    └── Handles bonus time distribution                      │
│                                                             │
│  HomeViewModel                                              │
│    └── completeWorkout() → distributeBonusTime()            │
│    └── Refreshes monitoring after workout                   │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ DeviceActivity Framework
                            ▼
┌─────────────────────────────────────────────────────────────┐
│             DeviceActivityMonitor Extension                 │
├─────────────────────────────────────────────────────────────┤
│  Runs in separate process                                   │
│  Called by iOS when:                                        │
│    - intervalDidStart: New day begins → remove shields      │
│    - eventDidReachThreshold: Limit hit → apply shields      │
│                                                             │
│  Uses ManagedSettingsStore to apply/remove shields          │
│  Communicates via App Group UserDefaults                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Setting a Time Limit:
```
User → TimeLimitSetupView → AppTimeLimit (SwiftData)
                         → ScreenTimeManager.startMonitoring()
                         → DeviceActivityCenter.startMonitoring(schedule, events)
```

### When Limit is Reached:
```
iOS detects usage threshold → DeviceActivityMonitor.eventDidReachThreshold()
                           → ManagedSettingsStore.shield.applications = [blocked]
                           → User sees shield on app
```

### Earning Bonus Time:
```
User completes workout → HomeViewModel.completeWorkout()
                      → ScreenTimeManager.distributeBonusTime()
                      → Removes shields from blocked apps
                      → Restarts monitoring with higher thresholds
```

---

## Testing

### Test Workflow:
1. Set a **5-minute limit** on an app for easy testing
2. Use that app for 5+ minutes
3. Verify the app gets blocked
4. Complete a workout
5. Verify the app unblocks

### Debug Logging:
All Screen Time operations are logged with `[ScreenTime]` prefix:
```
[ScreenTime] Monitoring app 'Instagram' with 30 min limit
[ScreenTime] Threshold reached for event: limit_xxx
[ScreenTime] Distributed 5 bonus minutes to 3 limits
```

---

## Troubleshooting

### "Family Controls capability is missing"
→ Add capability in Signing & Capabilities for both main app AND extension

### Shields not applying when limit is reached
→ Ensure DeviceActivityMonitor extension is properly set up
→ Check extension target has Family Controls capability
→ Verify App Group is the same in both targets

### Bonus time not unblocking apps
→ Check that `distributeBonusTime()` is being called
→ Verify the app token matches what was blocked

### Extension not receiving events
→ Extension must be built and embedded in main app
→ Check Embed Extensions setting in Build Phases

---

## App Store Notes

When submitting, Apple may ask about FamilyControls usage:

**Purpose**: "Users set their own daily app time limits. When exceeded, apps are blocked until they earn more time by completing exercises."

**User Control**: "Users have full control - they set their own limits, can modify or disable them anytime, and the blocking only affects their own device."

**Not Parental Controls**: "This is personal productivity/wellness focused, not for monitoring other users."
