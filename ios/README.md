# Fleet Agent for iOS

A native iOS/iPadOS app that acts as a lightweight osquery-compatible agent for Fleet. Enrolls with a Fleet server, polls for distributed queries, executes them against device APIs, and reports results back.

See [DESIGN.md](DESIGN.md) for architecture details.

## Prerequisites

- **Xcode 15+** (with iOS 16.0+ SDK)
- **Docker** running MySQL + Redis (`make deps` from repo root, or `docker compose up`)
- **Fleet server** built from this repo

## Quick Start

### 1. Start Infrastructure

```bash
# From repo root — start MySQL, Redis, and supporting services
docker compose up -d

# Build and prepare the server
CGO_ENABLED=1 go build -tags full,fts5,netgo -o build/fleet ./cmd/fleet
./build/fleet prepare db --dev
./build/fleet serve --dev --dev_license
```

Server runs at `https://localhost:8080`. Get the enroll secret from the UI or:
```bash
./build/fleetctl get enroll-secret
```

### 2. Build the iOS App

```bash
cd ios/
xcodebuild -project FleetAgent.xcodeproj -scheme FleetAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug build
```

### 3. Install and Launch on Simulator

```bash
# Boot simulator (if not already running)
xcrun simctl boot "iPhone 16"

# Install
xcrun simctl install booted FleetAgent.app

# Set config (replace YOUR_SECRET with the enroll secret)
xcrun simctl spawn booted defaults write com.fleetdm.agent \
  debug_server_url "https://localhost:8080"
xcrun simctl spawn booted defaults write com.fleetdm.agent \
  debug_enroll_secret "YOUR_SECRET"

# Launch
xcrun simctl launch booted com.fleetdm.agent
```

### 4. Enroll

Tap the **Enroll** button in the app. You should see:
- **Enrolled** (green) with a node key
- **Poll #1** within a few seconds

The host will appear in the Fleet dashboard at `https://localhost:8080/hosts`.

## Running Tests

```bash
cd ios/
xcodebuild test -project FleetAgent.xcodeproj -scheme FleetAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug
```

58 tests covering: Keychain, config, enrollment, API client (with mock HTTP), query engine (all 11 tables), polling manager, and JSON encoding/decoding.

## Available Tables

| Table | Data |
|-------|------|
| `device_info` | device name, model, system version, vendor ID |
| `os_version` | major, minor, patch, full version string |
| `battery` | level (0-100), charging state |
| `disk_space` | total/available bytes |
| `network_info` | wifi/cellular, expensive, constrained |
| `system_info` | model, CPU arch, memory, kernel, hostname |
| `screen` | width, height, scale, brightness |
| `locale_info` | language, region, timezone |
| `thermal_state` | nominal/fair/serious/critical |
| `managed_config` | MDM AppConfig key-value pairs |
| `passcode_info` | biometric type, availability |

View all table data: tap the **gear icon** → **Query Tables**.

## Testing Silent Push

Simulate an APNs silent push to trigger an immediate poll:

```bash
xcrun simctl push booted com.fleetdm.agent - <<'EOF'
{
  "aps": {
    "content-available": 1
  }
}
EOF
```

## Useful Commands

```bash
# Screenshot
xcrun simctl io booted screenshot screenshot.png

# Stream app logs
xcrun simctl spawn booted log stream --predicate 'process == "FleetAgent"'

# Clear enrollment (reset app state)
xcrun simctl spawn booted defaults delete com.fleetdm.agent

# Terminate app
xcrun simctl terminate booted com.fleetdm.agent
```

## Project Structure

```
ios/
├── FleetAgent/
│   ├── FleetAgentApp.swift          # App entry + AppDelegate (BGTask, APNs)
│   ├── ContentView.swift            # Main UI (config, enrollment, polling cards)
│   ├── DebugConfigView.swift        # Debug config entry screen
│   ├── DebugTablesView.swift        # Table data viewer
│   ├── ConfigurationManager.swift   # MDM AppConfig + debug config
│   ├── ApiClient.swift              # HTTP client (enroll, config, queries, push token)
│   ├── KeychainManager.swift        # Secure credential storage
│   ├── PollingManager.swift         # Foreground timer + BGTask + query execution
│   ├── Info.plist                   # BGTask + remote-notification background modes
│   └── Tables/
│       ├── QueryEngine.swift        # SQL dispatch engine
│       ├── DeviceInfoTable.swift
│       ├── OSVersionTable.swift
│       ├── BatteryTable.swift
│       ├── DiskSpaceTable.swift
│       ├── NetworkInfoTable.swift
│       ├── SystemInfoTable.swift
│       ├── ScreenTable.swift
│       ├── LocaleInfoTable.swift
│       ├── ThermalStateTable.swift
│       ├── ManagedConfigTable.swift
│       └── PasscodeInfoTable.swift
├── FleetAgentTests/                 # 58 unit tests
├── FleetAgent.xcodeproj/
├── DESIGN.md                        # Full architecture document
└── README.md                        # This file
```

## Server-Side Changes (Step 8)

This branch includes Go server changes:

- **`LoadHostByNodeKey`** accepts both `node_key` and `orbit_node_key` — mobile agents authenticate with orbit key for distributed queries
- **`POST /api/fleet/orbit/push_token`** — new endpoint to store APNs push token
- **Migration** — adds `push_token` column to `host_orbit_info`
- **Re-enrollment** — mobile platforms sync `node_key = orbit_node_key`
