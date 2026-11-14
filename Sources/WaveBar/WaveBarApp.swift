import SwiftUI

@main
struct WaveBarApp: App {
    @StateObject private var player = Player()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(player)
        } label: {
            MenuBarIcon(isPlaying: player.isPlaying)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "music.note")
    }
}
