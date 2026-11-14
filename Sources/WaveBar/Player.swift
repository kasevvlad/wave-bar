import AppKit
import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class Player: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case wave = "Моя волна"
        case liked = "Мне нравится"
        var id: String { rawValue }
    }

    @Published private(set) var account: Account?
    @Published private(set) var isSignedIn = false
    @Published private(set) var current: Track?
    @Published private(set) var cover: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var likedIDs: Set<String> = []
    @Published var errorText: String?
    @Published var source: Source {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: "source")
            resetQueue()
            if isSignedIn { Task { await startSource() } }
        }
    }
    @Published var volume: Float {
        didSet {
            avPlayer.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }

    private var api: YandexMusicAPI?
    private let avPlayer = AVPlayer()
    private var queue: [String] = []
    private var trackCache: [String: Track] = [:]
    private var index = -1
    private var likedOrder: [String] = []
    private var waveBatchID: String?
    private var loadID = UUID()
    private var isSeeking = false
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        source = Source(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .wave
        volume = UserDefaults.standard.object(forKey: "volume") as? Float ?? 0.8
        avPlayer.volume = volume

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
            }
        }

        avPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.updateNowPlaying()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.avPlayer.currentItem else { return }
                Task { await self.advance(finished: true) }
            }
            .store(in: &cancellables)

        setupRemoteCommands()

        if let token = TokenStore.load() {
            Task { await signIn(token: token) }
        }
    }

    // MARK: Account

    func showLogin() {
        LoginWindow.shared.show { [weak self] token in
            Task { await self?.signIn(token: token) }
        }
    }

    func signIn(token: String) async {
        let api = YandexMusicAPI(token: token)
        do {
            let account = try await api.account()
            TokenStore.save(token)
            self.api = api
            self.account = account
            isSignedIn = true
            errorText = account.hasPlus ? nil : "Без Плюса доступны только 30-секундные фрагменты"
            await refreshLikes()
        } catch {
            if (error as? URLError) == nil {
                TokenStore.delete()
                isSignedIn = false
            }
            errorText = error.localizedDescription
        }
    }

    func signOut() {
        avPlayer.replaceCurrentItem(with: nil)
        TokenStore.delete()
        LoginWindow.clearCookies()
        api = nil
        account = nil
        isSignedIn = false
        current = nil
        cover = nil
        likedIDs = []
        likedOrder = []
        errorText = nil
        resetQueue()
        updateNowPlaying()
    }

    private func refreshLikes() async {
        guard let api, let uid = account?.uid else { return }
        if let ids = try? await api.likedTrackIDs(uid: uid) {
            likedOrder = ids
            likedIDs = Set(ids.map(Self.plainID))
        }
    }

    // MARK: Controls

    func togglePlay() {
        if current == nil || avPlayer.currentItem == nil {
            Task { await startSource() }
        } else if isPlaying {
            avPlayer.pause()
        } else {
            avPlayer.play()
        }
    }

    func next() {
        Task { await advance(finished: false) }
    }

    func previous() {
        if position > 3 || index <= 0 {
            seek(to: 0)
        } else {
            Task { await play(at: index - 1) }
        }
    }

    func seek(to seconds: Double) {
        isSeeking = true
        position = seconds
        avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlaying()
            }
        }
    }

    var isCurrentLiked: Bool {
        guard let current else { return false }
        return likedIDs.contains(current.id)
    }

    func toggleLike() {
        guard let api, let uid = account?.uid, let track = current else { return }
        let like = !likedIDs.contains(track.id)
        if like { likedIDs.insert(track.id) } else { likedIDs.remove(track.id) }
        Task {
            do {
                try await api.setLiked(like, trackID: track.fullID, uid: uid)
                if source == .wave {
                    await api.waveFeedback(like ? "like" : "unlike", track: track, batchID: waveBatchID)
                }
            } catch {
                if like { likedIDs.remove(track.id) } else { likedIDs.insert(track.id) }
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: Queue

    private func resetQueue() {
        loadID = UUID()
        queue = []
        index = -1
        waveBatchID = nil
    }

    private func startSource() async {
        guard let api else { return }
        resetQueue()
        isLoading = true
        defer { isLoading = false }
        do {
            switch source {
            case .wave:
                await api.waveFeedback("radioStarted", track: nil, batchID: nil)
                try await loadMoreWave()
            case .liked:
                if likedOrder.isEmpty { await refreshLikes() }
                queue = likedOrder
            }
            guard !queue.isEmpty else {
                errorText = source == .liked ? "В «Мне нравится» пока пусто" : "Волна ничего не вернула"
                return
            }
            await play(at: 0)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadMoreWave() async throws {
        guard let api else { return }
        let last = queue.last.flatMap { trackCache[$0] }?.fullID
        let batch = try await api.waveTracks(after: last)
        waveBatchID = batch.batchID ?? waveBatchID
        for track in batch.tracks where !queue.contains(track.fullID) {
            trackCache[track.fullID] = track
            queue.append(track.fullID)
        }
    }

    private func advance(finished: Bool) async {
        if source == .wave, let track = current, let api {
            await api.waveFeedback(finished ? "trackFinished" : "skip", track: track, batchID: waveBatchID, played: position)
        }
        if source == .wave, index + 2 >= queue.count {
            try? await loadMoreWave()
        }
        if index + 1 < queue.count {
            await play(at: index + 1)
        } else if source == .liked, !queue.isEmpty {
            await play(at: 0)
        }
    }

    private func track(for key: String) async throws -> Track {
        if let cached = trackCache[key] { return cached }
        guard let api, let start = queue.firstIndex(of: key) else {
            throw APIError(message: "Трек не найден")
        }
        let chunk = Array(queue[start..<min(start + 20, queue.count)]).filter { trackCache[$0] == nil }
        for track in try await api.tracks(ids: chunk) {
            trackCache[track.fullID] = track
            trackCache[track.id] = track
        }
        if let track = trackCache[key] ?? trackCache[Self.plainID(key)] { return track }
        throw APIError(message: "Трек не найден")
    }

    private func play(at newIndex: Int, attempts: Int = 0) async {
        guard let api, queue.indices.contains(newIndex) else { return }
        let id = UUID()
        loadID = id
        index = newIndex
        isLoading = true
        do {
            let track = try await track(for: queue[newIndex])
            guard loadID == id else { return }
            current = track
            duration = track.duration
            position = 0
            cover = nil
            loadCover(for: track)
            guard track.available != false else { throw APIError(message: "Трек недоступен") }

            let url = try await api.streamURL(trackID: track.fullID)
            guard loadID == id else { return }
            avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            avPlayer.play()
            isLoading = false
            if !(errorText?.hasPrefix("Без Плюса") ?? false) { errorText = nil }
            updateNowPlaying()
            if source == .wave {
                await api.waveFeedback("trackStarted", track: track, batchID: waveBatchID)
            }
        } catch {
            guard loadID == id else { return }
            isLoading = false
            errorText = error.localizedDescription
            if attempts < 3, newIndex + 1 < queue.count {
                await play(at: newIndex + 1, attempts: attempts + 1)
            }
        }
    }

    private func loadCover(for track: Track) {
        guard let url = track.coverURL(size: 600) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), current?.id == track.id else { return }
            cover = image
            updateNowPlaying()
        }
    }

    private static func plainID(_ key: String) -> String {
        String(key.split(separator: ":").first ?? Substring(key))
    }

    // MARK: Now Playing & media keys

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { self?.togglePlay() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.avPlayer.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let cover {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
