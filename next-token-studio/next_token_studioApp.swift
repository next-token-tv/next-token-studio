import SwiftUI

@main
struct NextTokenStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioLifecycle.self) private var lifecycle
    @State private var studio = AudioStudio()

    var body: some Scene {
        Window("Next Token Studio", id: "studio") {
            ContentView(studio: studio)
                .frame(minWidth: 940, minHeight: 640)
                .onAppear { lifecycle.studio = studio }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            SidebarCommands()
            CommandMenu("录音") {
                Button("开始录音") { Task { await studio.startRecording() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(studio.isBusy || studio.workspace.root == nil)
                Button(studio.isPaused ? "继续录音" : "暂停录音") { studio.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!studio.isRecording || studio.isFinalizing)
                Button("停止并保存") { studio.stopRecording() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!studio.isRecording || studio.isFinalizing)
            }
        }
    }
}

@MainActor
final class StudioLifecycle: NSObject, NSApplicationDelegate {
    weak var studio: AudioStudio?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio, studio.isRecording else { return .terminateNow }
        if studio.isFinalizing {
            Task { sender.reply(toApplicationShouldTerminate: await studio.waitForRecordingSave()) }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "正在录音"
        alert.informativeText = "退出前需要停止并保存当前录音。"
        alert.addButton(withTitle: "继续录音")
        alert.addButton(withTitle: "停止保存并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        studio.stopRecording()
        Task { sender.reply(toApplicationShouldTerminate: await studio.waitForRecordingSave()) }
        return .terminateLater
    }
}
