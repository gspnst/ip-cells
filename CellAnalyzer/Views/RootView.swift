import SwiftUI
import CellAnalyzerCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            NavigationStack { LiveView() }
                .tabItem { Label("Live", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationStack { CellsListView() }
                .tabItem { Label("Cells", systemImage: "cellularbars") }
            NavigationStack { CoverageMapView() }
                .tabItem { Label("Map", systemImage: "map") }
            NavigationStack { InsightsView() }
                .tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }
                .badge(model.anomalies.filter { $0.severity >= .medium }.count)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { showOnboarding = !model.settings.hasCompletedOnboarding }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                model.settings.hasCompletedOnboarding = true
                showOnboarding = false
                model.location.requestPermission()
            }
            .interactiveDismissDisabled()
        }
    }
}

struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                Text("Cell Analyzer")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity)

                OnboardingPoint(icon: "lock.shield",
                                title: "What iOS allows",
                                text: "Apple doesn't let apps read cell IDs or signal strength. Live, the app sees the radio technology (2G–5G, SA/NSA) for each SIM, plus your location and network path.")
                OnboardingPoint(icon: "camera.viewfinder",
                                title: "Field Test screenshots",
                                text: "For the rest, dial *3001#12345#* to open Field Test Mode and take screenshots. The app reads them on the device and pulls out the cell ID, band, PCI, RSRP, RSRQ and SINR.")
                OnboardingPoint(icon: "map",
                                title: "Analyze",
                                text: "Decode eNB/gNB IDs and frequencies, map coverage, estimate where cells are, and flag suspicious patterns such as forced 2G drops or spoofed cells.")
                OnboardingPoint(icon: "iphone",
                                title: "Private",
                                text: "Everything stays on this iPhone. Network lookups happen only if you add an OpenCellID key and look up a cell.")

                Button(action: onContinue) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(24)
        }
    }
}

private struct OnboardingPoint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
