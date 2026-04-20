import SwiftUI

@main
struct OmiLocalMeetingsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HSplitView {
                LibraryView(model: model)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

                RecorderView(model: model)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

                SessionDetailView(model: model)
                    .frame(minWidth: 420, idealWidth: 520)
            }
            .frame(minWidth: 1200, minHeight: 760)
            .task {
                model.loadStoredSessions()
            }
        }
    }
}
