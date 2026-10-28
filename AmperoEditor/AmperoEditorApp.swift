import SwiftUI

@main
struct AmperoEditorApp: App {
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
