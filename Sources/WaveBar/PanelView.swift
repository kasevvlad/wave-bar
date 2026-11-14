import SwiftUI

private let accent = Color(red: 1.0, green: 0.82, blue: 0.25)

struct PanelView: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        ZStack {
            Backdrop(image: player.cover)
            Group {
                if player.isSignedIn {
                    PlayerContent()
                } else {
                    SignInContent()
                }
            }
            .padding(18)
        }
        .frame(width: 330)
        .environment(\.colorScheme, .dark)
    }
}

private struct Backdrop: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .saturation(1.4)
                    .opacity(0.65)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.25, green: 0.18, blue: 0.05), Color(white: 0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: image)
        .clipped()
    }
}

// MARK: Signed out

private struct SignInContent: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 96, height: 96)
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Wave Bar").font(.title2.bold())
                Text("Войдите в аккаунт Яндекса, чтобы слушать Мою волну и любимые треки прямо из строки меню.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: player.showLogin) {
                Text("Войти через Яндекс")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if let error = player.errorText {
                Text(error).font(.caption).foregroundStyle(.red.opacity(0.9))
            }

            Button("Выйти из приложения") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
    }
}

// MARK: Player

private struct PlayerContent: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(spacing: 16) {
            Header()
            Cover()
            TrackInfo()
            ProgressBar()
            Controls()
            VolumeBar()
            if let error = player.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct Header: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Player.Source.allCases) { source in
                    let selected = player.source == source
                    Button {
                        player.source = source
                    } label: {
                        Label(source.rawValue, systemImage: source == .wave ? "waveform" : "heart.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? .black : .secondary)
                            .background(selected ? accent : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.08), in: Capsule())

            Spacer()

            Menu {
                if let account = player.account {
                    Text(account.name)
                    Text(account.hasPlus ? "Яндекс Плюс активен" : "Без Яндекс Плюса")
                    Divider()
                }
                Button("Выйти из аккаунта", action: player.signOut)
                Button("Закрыть Wave Bar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct Cover: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.06))
            if let image = player.cover {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
            if player.isLoading {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.large)
            }
        }
        .frame(width: 294, height: 294)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .scaleEffect(player.isPlaying || player.current == nil ? 1 : 0.94)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .animation(.easeInOut(duration: 0.4), value: player.cover)
    }
}

private struct TrackInfo: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if let track = player.current {
                        Text(track.title)
                            + Text(track.version.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
                    } else {
                        Text(player.source == .wave ? "Моя волна" : "Мне нравится")
                    }
                }
                .font(.headline)
                .lineLimit(1)

                Text(player.current?.artistLine ?? "Нажмите ▶, чтобы начать")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: player.toggleLike) {
                Image(systemName: player.isCurrentLiked ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.isCurrentLiked ? accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
            .help(player.isCurrentLiked ? "Убрать из «Мне нравится»" : "Добавить в «Мне нравится»")
        }
    }
}

private struct ProgressBar: View {
    @EnvironmentObject private var player: Player
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        let total = max(player.duration, 1)
        let value = dragValue ?? player.position
        VStack(spacing: 6) {
            GeometryReader { geo in
                let fraction = min(max(value / total, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: geo.size.width * fraction)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: geo.size.width * fraction - 6)
                        .opacity(hovering || dragValue != nil ? 1 : 0)
                }
                .frame(height: hovering || dragValue != nil ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in dragValue = min(max(g.location.x / geo.size.width, 0), 1) * total }
                        .onEnded { _ in
                            if let dragValue { player.seek(to: dragValue) }
                            dragValue = nil
                        }
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 14)
            .disabled(player.current == nil)

            HStack {
                Text(Self.format(value))
                Spacer()
                Text("-" + Self.format(max(player.duration - value, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Controls: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 34) {
            ControlButton(symbol: "backward.fill", size: 22, action: player.previous)
                .disabled(player.current == nil)
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: player.isPlaying ? 0 : 2)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.space, modifiers: [])
            ControlButton(symbol: "forward.fill", size: 22, action: player.next)
                .disabled(player.current == nil)
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct VolumeBar: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .tint(.white)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}
