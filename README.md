# Cell Analyzer for iPhone

An iOS app (SwiftUI, iOS 17+) for analyzing the cellular network and the cell towers your iPhone connects to: decoded cell identities, bands and frequencies, signal quality, coverage maps, estimated tower positions, and heuristics for fake base stations ("IMSI catchers").

## The iOS constraint, and how the app handles it

Apple does **not** let apps read the serving cell ID, TAC, PCI, EARFCN, or signal values (RSRP/RSRQ/SINR). Those are behind private frameworks and entitlements that App Store apps can't get. Since iOS 16, even the carrier name and MCC/MNC return placeholder values.

Cell Analyzer stays on public APIs and combines two sources:

| Source | What it provides |
| --- | --- |
| **Live from iOS** (`CTTelephonyNetworkInfo`, `NWPathMonitor`, Core Location) | Radio technology per SIM (2G/3G/LTE/5G NSA/5G SA) and when it changes, which SIM carries data, Wi-Fi vs cellular, position |
| **Field Test Mode screenshots** (`*3001#12345#*`) | Everything the modem reports for the serving cell: cell ID, TAC, PCI, EARFCN/NR-ARFCN, band, bandwidth, RSRP, RSRQ, SINR. The app reads the screenshots with on-device OCR (Vision). |

You can also paste text (for example copied with Live Text) or type values in by hand.

## Features

- **Live tab**: per-SIM radio technology, connection path, a recording mode that logs radio changes with GPS (background capable, for drive tests), and the latest measured cell with signal gauges.
- **Screenshot import**: multi-select Field Test screenshots. The text is recognized on the device, then parsed with typo-tolerant label matching, missing-minus-sign repair, plausibility checks, and NSA handling (LTE anchor and NR leg become linked measurements). Each screenshot is geotagged by matching its timestamp to the recorded track. Every value can be reviewed and edited before saving.
- **Cell decoding**:
  - LTE ECI → eNB ID + sector.
  - NR NCI → gNB ID with a configurable 22–32-bit split.
  - UMTS → RNC + C-ID.
  - EARFCN / NR-ARFCN / UARFCN / ARFCN → band, downlink/uplink frequency and duplex mode. Uses the full 3GPP band tables and resolves overlapping NR bands (n77/n78, n41/n90…) by region.
  - PCI split into SSS group and PSS ID.
  - Operator and country names from MCC/MNC.
- **Signal analysis**: graded RSRP/RSRQ/SINR, history chart, a composite score, and a rough Shannon-based throughput estimate.
- **Tower location**:
  - A signal-weighted centroid of your measurements estimates where a cell is.
  - An optional [OpenCellID](https://opencellid.org) lookup (needs your own free key) shows the registered position and range.
  - Distance and bearing from you to the site, and a timing-advance distance when the screenshot includes TA.
- **Coverage map**: every located measurement coloured by signal or technology, plus cell sites.
- **Insights**: time on each technology, band usage, handovers, radio changes, area changes, and an event timeline.
- **Security checks** (heuristics only):
  - Test-network PLMNs (001-01, 999-99).
  - Unallocated MCCs.
  - Drops from 4G/5G to 2G.
  - A cell ID reused with a different PCI or frequency.
  - A cell changing its TAC.
  - Brief A→B→A tracking-area switches.
  - Two cells on the same channel and PCI close together.
  - Unusually strong signal.
  - A cell far from its registered site, or missing from the database.
- **Export / import**: CSV (spreadsheets), JSON (round-trips back into the app), and KML (Google Earth).
- **Demo data**: Settings › Load demo data adds a synthetic 40-minute drive, so every screen can be explored in the Simulator, which has no cellular radio.
- **Privacy**: all data stays on the device. Only an OpenCellID lookup sends anything off the phone, and it sends just the cell identity, never your location.

## Project layout

```
project.yml                      XcodeGen spec for the iOS app
CellAnalyzerUITests/             UI smoke test: launches with demo data, visits every screen, saves screenshots
scripts/ocr-screenshots.swift    Prints the text in UI-test screenshots (used in CI)
CellAnalyzer/                    iOS app (SwiftUI)
  App/                           App entry point and AppModel (object graph and derived analysis)
  Services/                      CoreTelephony, Core Location, NWPathMonitor, Vision OCR, OpenCellID, storage
  Views/                         Live, Capture, Cells, Map, Insights, Settings
Packages/CellAnalyzerCore/       Platform-independent Swift package (no UIKit), unit-tested on Linux and macOS
  Models/                        RadioTechnology, CellObservation, PLMN, CellKey
  Spectrum/                      LTE/NR/UMTS/GSM band tables and channel→frequency math
  Identity/                      ECI/NCI/UTRAN cell-ID decoding
  Signal/                        Grading, scores, throughput estimate
  Parsing/                       Field Test OCR line assembly and parser
  Operators/                     MCC/MNC directory
  Analysis/                      Cell aggregation, session statistics, anomaly detection
  Geo/                           Distances, bearings, timing advance, weighted centroid
  Lookup/                        OpenCellID request/response
  Export/                        CSV / JSON / KML
```

## Building

Requirements: Xcode 16 or later, iOS 17 or later on the device, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open CellAnalyzer.xcodeproj
```

Then in Xcode, select the **CellAnalyzer** target › *Signing & Capabilities*, choose your team, and change the bundle identifier (`com.ipcells.CellAnalyzer`) if needed. Run it on a real iPhone; the simulator has no cellular radio.

Core library tests:

```sh
swift test --package-path Packages/CellAnalyzerCore
```

CI (`.github/workflows/ci.yml`):
- runs those tests on Linux and macOS;
- builds the app for the iOS Simulator and for devices (unsigned);
- runs the UI smoke test on a Simulator with demo data, uploads the screenshots as the `app-screenshots` artifact, and prints their recognized text in the job log.

To try the app in the Simulator, launch with the `-demoData` argument, or use Settings › Load demo data.

## Using Field Test Mode

1. Phone app › Keypad › dial `*3001#12345#*` › Call.
2. Open the LTE / 5G NR pages that show the serving cell: *Serving Cell Info*, *Serving Cell Meas*, or *RsrpRsrqSinr*. Labels differ by iOS version and modem.
3. Take screenshots (side button + volume up).
4. In Cell Analyzer, go to Live › **Import screenshots**, check the values, and save.

Tip: start **Recording** first. Screenshots taken during the session are then placed on the map using their timestamps.

## Accuracy notes

- Field Test labels aren't documented and change between iOS versions. The parser uses a broad alias table and fuzzy matching. If a value isn't recognized, it shows the raw OCR text, and you can edit the measurement.
- NR gNB-ID length is operator-specific; set it in Settings if gNB IDs look wrong.
- The tower estimate is a signal-weighted centroid. It's biased towards where you measured and needs samples from several directions.
- The security heuristics flag patterns, not proof. Networks get re-planned and databases are incomplete. Treat several findings close together in time and place as a reason to look closer. iOS Lockdown Mode disables 2G entirely.
