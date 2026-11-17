import SwiftUI

@main
struct SinRastroApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("SinRastro", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Actualizar lista") { model.reloadApps() }
                    .keyboardShortcut("r")
            }
        }
    }
}
