import SwiftUI

@main
struct NextTokenStudioApp: App {
    @State private var studio = AudioStudio()

    var body: some Scene {
        Window("Next Token Studio", id: "studio") {
            ContentView(studio: studio)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            SidebarCommands()
            CommandMenu("录音") {
                Button("开始录音") { Task { await studio.startRecording() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(studio.isBusy)
                Button(studio.isPaused ? "继续录音" : "暂停录音") { studio.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!studio.isRecording)
                Button("停止并保存") { studio.stopRecording() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!studio.isRecording)
            }
        }
    }
}
