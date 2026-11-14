import SwiftUI

@main
struct CellAnalyzerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.telephony.refresh()
            case .background:
                model.store.saveNow()
            default:
                break
            }
        }
    }
}
