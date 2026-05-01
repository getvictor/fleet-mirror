# iOS osquery Agent — Design Document

## Overview

A native iOS/iPadOS app that acts as a lightweight osquery-compatible agent for Fleet. It enrolls with a Fleet server, polls for distributed queries and configuration, executes queries against local device APIs, and reports results back — mirroring the functionality of the Android agent (`android/`) and the macOS Orbit agent (`orbit/`).

## Current State

Fleet currently manages iOS devices **only via MDM**, collecting data through 3 fixed commands:
- `DeviceInformation` — device name, capacity, OS version, WiFi MAC
- `InstalledApplicationList` — app name, version, identifier
- `CertificateList` — installed certificates

There is no custom query capability, no background agent, and no existing iOS app code.

---

## Architecture

### App Delivery & Execution Model

**Recommended: Standalone Swift/SwiftUI app + dual wake mechanism**

| Option | Approach | Verdict |
|--------|----------|---------|
| A. BGTaskScheduler only | System-scheduled background refresh (~15-30 min) | Unreliable cadence |
| B. APNs silent push only | Server-controlled timing, ~30s execution window | Requires MDM enrollment |
| **C. Combine A + B** | **BGTask for periodic heartbeat + APNs for on-demand queries** | **Selected** |
| D. Network Extension | Persistent background via VPN entitlement | Overkill, UX issues |

**Distribution:** Via Apple Business Manager (ABM) + VPP, pushed as a managed app with configuration attached.

**Tech stack:** Swift, SwiftUI, no third-party dependencies. Minimum deployment target: iOS 16.0.

**Bundle identifier:** `com.fleetdm.agent` (matches Android)

---

## Step-by-Step Implementation Plan

### Step 1 — Scaffold & Deploy (DONE)

Minimal SwiftUI app with:
- "Hello" counter incrementing every 15 seconds (configurable interval)
- Managed App Config (AppConfig) plumbing for MDM credential delivery
- Debug config screen for simulator development (enter server_url, enroll_secret manually)
- Builds and runs on iOS Simulator without Apple Developer account

### Step 2 — Enrollment

Connect to Fleet server via Orbit enroll endpoint. Store credentials in Keychain. Handle re-enrollment on 401.

### Step 3 — Polling & Config

Add BGAppRefreshTask for periodic background execution. Fetch orbit config and distributed queries each cycle.

### Step 4 — Query Engine + First Tables

Build table-dispatch query engine. Implement starter tables: `device_info`, `os_version`, `battery`.

### Step 5 — Result Submission

Wire up result submission to Fleet via osquery log endpoints.

### Step 6 — Remaining Tables

Add remaining tables: `disk_space`, `network_info`, `system_info`, `screen`, `locale_info`, `thermal_state`, `managed_config`, `passcode_info`.

### Step 7 — APNs Silent Push

Register app push token with Fleet. Handle silent push for on-demand distributed queries.

### Step 8 — Server-Side Support

Backend changes to distinguish MDM-only iOS hosts from agent-equipped ones, correlate agent enrollment with existing MDM host record.

---

## Enrollment Mechanism (Step 2)

### Credential Delivery

**Production (MDM):** Managed App Configuration (AppConfig) — the iOS equivalent of Android's Managed Configuration.

```
Fleet Server                        ABM/VPP                         iOS Device
    │                                  │                                │
    │──── Deploy app via VPP ─────────>│                                │
    │     with AppConfig:              │──── Install app ──────────────>│
    │     {                            │     with managed config        │
    │       "enroll_secret": "...",    │                                │
    │       "server_url": "...",       │                                │
    │       "host_uuid": "..."         │                                │
    │     }                            │                                │
    │                                                                   │
    │<──────────── POST /api/fleet/orbit/enroll ────────────────────────│
    │              { enroll_secret, hardware_uuid,                       │
    │                hardware_serial, platform: "ios",                   │
    │                computer_name }                                     │
    │                                                                   │
    │──────────── { orbit_node_key } ──────────────────────────────────>│
    │                                                    (store in Keychain)
```

**Development (Simulator):** Debug config screen where values are entered manually and stored in UserDefaults. Same code path after credential loading.

### API Details

**Enroll Request:**
```
POST /api/fleet/orbit/enroll
{
  "enroll_secret": "<from AppConfig>",
  "hardware_uuid": "<UIDevice.identifierForVendor or AppConfig host_uuid>",
  "hardware_serial": "<not available from app — correlate via MDM>",
  "platform": "ios",
  "computer_name": "<UIDevice.name>"
}
```

**Enroll Response:**
```json
{ "orbit_node_key": "<token>" }
```

**Credential Storage:** iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock` so background execution can access the node key.

**Re-enrollment:** On HTTP 401, clear stored node key and re-enroll automatically (same pattern as Android's `withReenrollOnUnauthorized`).

**Advantage over Android:** Fleet already knows about the device via MDM enrollment. The app enrollment links the osquery agent to the existing MDM host record rather than creating a new host.

### Reading AppConfig in iOS

```swift
// MDM-delivered configuration
UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")
// Returns: ["server_url": "...", "enroll_secret": "...", "host_uuid": "..."]
```

---

## Polling & Distribution Mechanism (Step 3)

### Dual Mechanism

iOS severely limits background execution compared to Android's reliable 15-minute WorkManager. Two complementary mechanisms are used:

#### A. BGAppRefreshTask — Periodic Heartbeat

```
App registers BGAppRefreshTask on launch
    → iOS schedules it (15-30+ min, system-determined)
    → App wakes, calls:
        POST /api/fleet/orbit/config        (get config)
        POST /api/osquery/distributed/read  (get pending queries)
    → Executes queries against device APIs
    → POST /api/osquery/distributed/write   (submit results)
    → Schedules next BGAppRefreshTask
    → ~30s execution budget
```

#### B. APNs Silent Push — Server-Initiated (Step 7)

```
Fleet admin runs a live query targeting iOS device
    → Fleet server sends silent push via APNs
       (Fleet already has APNs infrastructure for MDM)
    → iOS wakes app in background
    → App fetches distributed queries and executes them
    → Submits results back to Fleet
    → ~30s execution budget
```

#### Why Both?

- **BGTask** handles steady-state "phone home every N minutes" (config refresh, scheduled queries)
- **APNs** handles on-demand distributed queries with near-real-time response
- This is **better than Android's polling-only model** because you get server-initiated query execution

### Server-Side Consideration

The app's APNs push token is separate from the MDM push token. New endpoint needed:
```
POST /api/fleet/orbit/push_token
{ "orbit_node_key": "...", "push_token": "..." }
```

---

## Query Execution Engine (Step 4)

### Architecture

SQLite is a first-class citizen on iOS (system framework). The engine uses a table-dispatch pattern:

```
Incoming SQL query (e.g. "SELECT * FROM battery WHERE level < 20")
    → Parse table name from query
    → Dispatch to table implementation
    → Table implementation calls iOS APIs to populate rows
    → Return result rows as [[String: String]] dictionaries
```

### Initial Implementation — Simple Dispatch

```swift
func executeSql(_ query: String) -> [[String: String]] {
    let tableName = parseTableName(query)
    switch tableName {
    case "device_info":  return DeviceInfoTable.generate()
    case "os_version":   return OSVersionTable.generate()
    case "battery":      return BatteryTable.generate()
    // ... more tables
    }
}
```

### Future — SQLite Virtual Tables

The architecture supports upgrading to real SQLite virtual tables, where `SELECT * FROM battery WHERE level < 20` executes as actual SQL with filtering/joins handled by SQLite:

```swift
sqlite3_create_module(db, "battery", &batteryModule, nil)
// Now standard SQL works against the virtual table
```

Start with simple dispatch (matching Android's current level), upgrade later if needed.

---

## Tables (Steps 4 + 6)

### Table Inventory

| Table | Step | iOS API | Data Returned |
|-------|------|---------|---------------|
| `device_info` | 4 | `UIDevice`, `ProcessInfo` | device name, model, system version, vendor ID |
| `os_version` | 4 | `ProcessInfo.operatingSystemVersion` | major, minor, patch version |
| `battery` | 4 | `UIDevice.batteryLevel/State` | level (0-100), state (charging/full/unplugged) |
| `disk_space` | 6 | `FileManager.attributesOfFileSystem` | total, available, important/opportunistic capacity |
| `network_info` | 6 | `NWPathMonitor` | interface type (wifi/cellular), is expensive, is constrained |
| `system_info` | 6 | `UIDevice`, `utsname()` | model, CPU arch, physical memory, kernel info |
| `screen` | 6 | `UIScreen` | bounds, scale, brightness |
| `locale_info` | 6 | `Locale.current` | language, region, timezone |
| `thermal_state` | 6 | `ProcessInfo.thermalState` | nominal/fair/serious/critical |
| `managed_config` | 6 | `UserDefaults` AppConfig | MDM-pushed key-value pairs |
| `passcode_info` | 6 | `LAContext` | biometric type (Face ID/Touch ID), availability |

### What iOS Cannot Provide (vs Android)

| Data | Why | Mitigation |
|------|-----|------------|
| Installed apps | iOS sandbox — can't enumerate other apps | MDM already collects this via `InstalledApplicationList` |
| Hardware serial | Not accessible from app APIs | Fleet already has serial from DEP/MDM enrollment |
| Carrier info | `CTCarrier` deprecated in iOS 16+ | Very limited, low priority |
| Storage encryption | Always encrypted on iOS | Can report `true` as constant |

### iOS-Unique Tables (not on Android)

- `managed_config` — reads MDM AppConfig values (unique insight into MDM state)
- `passcode_info` — biometric availability via `LAContext`
- `thermal_state` — iOS thermal monitoring (useful for fleet health)
- `icloud_info` — ubiquity identity token (is iCloud signed in)

---

## Dev Environment

### Requirements

| Need | Solution | Notes |
|------|----------|-------|
| iOS device | Xcode Simulator (iPhone 16) | No physical device needed |
| MDM config | Debug screen in app | Manually enter server_url, enroll_secret |
| Fleet server | `make serve` from fleet repo | Local Docker (MySQL + Redis) |

### Key Commands

```bash
# Build
cd ios/ && xcodebuild -project FleetAgent.xcodeproj -scheme FleetAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug build

# Install on simulator
xcrun simctl install booted FleetAgent.app

# Launch
xcrun simctl launch booted com.fleetdm.agent

# Screenshot
xcrun simctl io booted screenshot screenshot.png

# Logs
xcrun simctl spawn booted log stream --predicate 'process == "FleetAgent"'
```

---

## Comparison: iOS vs Android vs macOS

| Capability | iOS Agent (this project) | Android Agent | macOS (Orbit + osquery) |
|-----------|--------------------------|---------------|-------------------------|
| Language | Swift | Kotlin | Go + C++ |
| Enrollment | AppConfig via MDM | Managed Configuration | CLI / pkg installer |
| Background execution | BGTask + APNs | WorkManager (15 min) | Daemon (always running) |
| Query engine | Table dispatch → SQLite | Table dispatch (stub) | Full osquery (SQLite virtual tables) |
| Installed apps | No (MDM covers this) | Yes (PackageManager) | Yes (osquery table) |
| Distribution | ABM/VPP | Android Enterprise | Download / MDM |
| Push mechanism | APNs (shared with MDM infra) | N/A (polling only) | Agent polling |

---

## Step 8 — Server-Side Support (Implementation Plan)

### A. Make osquery endpoints accept orbit_node_key

**Problem:** `/api/osquery/distributed/read` and `/write` authenticate via `LoadHostByNodeKey` which queries `WHERE node_key = ?`. Mobile agents only have `orbit_node_key`.

**Fix 1:** Modify `LoadHostByNodeKey` in `server/datastore/mysql/hosts.go` — change WHERE clause to `WHERE h.node_key = ? OR h.orbit_node_key = ?`. Both columns have UNIQUE indexes.

**Fix 2:** In `EnrollOrbit` re-enrollment path, for mobile platforms (ios/ipados/android), also update `node_key` alongside `orbit_node_key` to keep them in sync.

### B. Push token endpoint: `POST /api/fleet/orbit/push_token`

New authenticated orbit endpoint to store the iOS agent's APNs push token. Follows the `setOrUpdateDeviceToken` pattern. Stores token in `host_orbit_info.push_token` column.

**Files modified:**
- `server/fleet/api_orbit.go` — request/response types
- `server/fleet/service.go` — Service interface method
- `server/fleet/datastore.go` — Datastore interface method
- `server/service/orbit.go` — endpoint + service implementation
- `server/service/handler.go` — endpoint registration
- `server/datastore/mysql/hosts.go` — datastore implementation
- `server/mock/datastore_mock.go` — mock

### C. Migration

Add `push_token VARCHAR(500)` column to `host_orbit_info` table.

---

## References

- Android agent: `android/` in fleet repo, PR fleetdm/fleet#43924
- Orbit agent (macOS): `orbit/` in fleet repo
- iOS MDM implementation: `server/mdm/apple/`
- APNs infrastructure: `server/mdm/nanomdm/push/`
- Orbit enroll endpoint: `POST /api/fleet/orbit/enroll`
- Apple Managed App Configuration: [Apple Developer Docs](https://developer.apple.com/documentation/devicemanagement/implementing-managed-app-configuration)
