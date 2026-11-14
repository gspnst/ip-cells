import SwiftUI
import UIKit

/// Step-by-step guide to Field Test Mode.
struct HelpView: View {
    @State private var copied = false

    var body: some View {
        List {
            Section {
                step(1, "Open Field Test Mode",
                     "In the Phone app keypad, dial *3001#12345#* and tap Call. Field Test opens; no call is made.")
                Button {
                    UIPasteboard.general.string = "*3001#12345#*"
                    copied = true
                } label: {
                    Label(copied ? "Copied – paste it in the Phone keypad" : "Copy the code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                step(2, "Find the serving cell",
                     "On iOS 15 and later, open the menu or All Metrics and go to the LTE or 5G NR pages, such as Serving Cell Info, Serving Cell Meas or RsrpRsrqSinr. Older iPhones with Intel modems show LTE › Serving Cell Info.")
                step(3, "Take screenshots",
                     "Press side button + volume up. Capture the page with the cell identity (cell ID, TAC, PCI, frequency, band) and the one with measurements (RSRP, RSRQ, SINR). Values refresh every few seconds.")
                step(4, "Import",
                     "In Cell Analyzer, tap Live › Import screenshots and pick them. Check the values, fix any OCR errors, and save.")
            } header: {
                Text("Capture cell data")
            }

            Section {
                tip("Drive tests", "Start Recording on the Live tab first. Screenshots are then placed on the map using their timestamp, even if you take them later.")
                tip("Dual SIM", "Field Test shows the SIM that carries data. Switch the data line in Settings › Cellular to measure the other one.")
                tip("5G NSA", "In NSA mode the phone uses an LTE anchor cell plus a 5G NR cell. Screenshot both pages; they are imported as two linked measurements.")
                tip("OCR mistakes", "A dropped minus sign on RSRP/RSRQ is fixed automatically and flagged. Check cell IDs, since one wrong digit means a different cell.")
                tip("Live Text", "You can also select text in a screenshot with Live Text, copy it, and use Paste copied text in the import screen.")
            } header: {
                Text("Tips")
            }

            Section("Reading the numbers") {
                legend("RSRP", "Signal strength. Above −80 dBm is excellent, −90 good, −100 fair, below −110 very weak.")
                legend("RSRQ", "Signal quality. Above −10 dB is excellent; below −15 dB the cell is loaded or there is interference.")
                legend("SINR", "Signal-to-noise ratio, the main factor in speed. Above 20 dB is excellent; below 0 dB is poor.")
                legend("PCI", "Physical cell ID (0–503 LTE, 0–1007 NR). Only unique locally.")
                legend("EARFCN / NR-ARFCN", "Channel number. Cell Analyzer converts it to band and frequency.")
                legend("ECI / NCI", "Global cell ID. Split into the base station (eNB/gNB) ID and the sector/cell.")
                legend("TAC", "Tracking area code: a group of cells the phone registers with.")
            }
        }
        .navigationTitle("Field Test guide")
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legend(_ term: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(term).font(.subheadline.weight(.semibold).monospaced())
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Explains why the app works the way it does.
struct LimitationsView: View {
    var body: some View {
        List {
            Section("Available to apps") {
                Label("Radio technology per SIM (GSM … LTE, 5G NSA, 5G SA) and when it changes", systemImage: "checkmark.circle")
                Label("Which SIM carries data", systemImage: "checkmark.circle")
                Label("Whether traffic goes over Wi-Fi or cellular, metered or Low Data Mode", systemImage: "checkmark.circle")
                Label("Precise location (with your permission)", systemImage: "checkmark.circle")
            }
            .foregroundStyle(.primary)

            Section {
                Label("Cell ID, TAC/LAC, PCI", systemImage: "xmark.circle")
                Label("EARFCN / band / frequency", systemImage: "xmark.circle")
                Label("RSRP, RSRQ, SINR, RSSI (signal values)", systemImage: "xmark.circle")
                Label("Neighbouring cells", systemImage: "xmark.circle")
                Label("Carrier name / MCC / MNC (placeholder values since iOS 16)", systemImage: "xmark.circle")
            } header: {
                Text("Not available to apps")
            } footer: {
                Text("Apple keeps these behind private frameworks and entitlements that App Store apps can't get. Apps that show them use private APIs and only run on jailbroken or developer-provisioned devices. Cell Analyzer stays on public APIs and reads Field Test Mode, which shows the same modem data, from your screenshots instead.")
            }

            Section("Going further") {
                Text("For continuous baseband-level data, Apple's \"Baseband for iOS\" logging profile (from the Apple Developer bug-reporting profiles) makes the system write detailed cellular logs into sysdiagnose archives. Research tools such as CellGuard from TU Darmstadt analyze those. This app concentrates on what you can do on the phone without such profiles.")
                    .font(.subheadline)
            }
        }
        .navigationTitle("iOS limitations")
    }
}
