import SwiftUI
import AVFoundation
import Combine

// MARK: - Models
struct AListFile: Identifiable, Codable {
    var id: String { name + String(size) }
    let name: String
    let size: Int64
    let is_dir: Bool
    let modified: String
    let sign: String?
    let thumb: String?
    
    var isAudio: Bool {
        let ext = name.lowercased()
        return ext.hasSuffix(".mp3") || ext.hasSuffix(".m4a") || ext.hasSuffix(".flac") || ext.hasSuffix(".wav")
    }
    
    var isLrc: Bool {
        name.lowercased().hasSuffix(".lrc")
    }
}

struct LrcLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let content: String
}

// MARK: - AList API Client
class AListClient: ObservableObject {
    @Published var serverUrl = ""
    @Published var token = ""
    @Published var currentPath = "/"
    @Published var files: [AListFile] = []
    @Published var isLoading = false
    
    func fetchFiles(path: String) async {
        guard !serverUrl.isEmpty else { return }
        let cleanUrl = serverUrl.trimmingCharacters(in: .whitespaces).appending("/api/fs/list")
        guard let url = URL(string: cleanUrl) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.addValue(token, forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = ["path": path]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        DispatchQueue.main.async { self.isLoading = true }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let content = dataObj["content"] as? [[String: Any]] {
                let decodedFiles = content.compactMap { dict -> AListFile? in
                    guard let name = dict["name"] as? String else { return nil }
                    return AListFile(
                        name: name,
                        size: dict["size"] as? Int64 ?? 0,
                        is_dir: dict["is_dir"] as? Bool ?? false,
                        modified: dict["modified"] as? String ?? "",
                        sign: dict["sign"] as? String,
                        thumb: dict["thumb"] as? String
                    )
                }
                DispatchQueue.main.async {
                    self.files = decodedFiles
                    self.currentPath = path
                    self.isLoading = false
                }
            }
        } catch {
            print("Fetch error: \(error)")
            DispatchQueue.main.async { self.isLoading = false }
        }
    }
    
    func getDownloadUrl(path: String) async -> String? {
        let cleanUrl = serverUrl.trimmingCharacters(in: .whitespaces).appending("/api/fs/get")
        guard let url = URL(string: cleanUrl) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.addValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path])
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let rawUrl = dataObj["raw_url"] as? String {
                return rawUrl
            }
        } catch { return nil }
        return nil
    }
}

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    private var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lyrics: [LrcLine] = []
    @Published var currentTrackName = ""
    @Published var currentLrcIndex: Int = 0
    
    private var timer: AnyCancellable?
    
    func play(urlStr: String, trackName: String, lrcContent: String?) {
        guard let url = URL(string: urlStr) else { return }
        currentTrackName = trackName
        
        // 解析歌词
        if let lrc = lrcContent {
            self.lyrics = parseLrc(lrc)
        } else {
            self.lyrics = []
        }
        
        player = AVPlayer(url: url)
        player?.play()
        isPlaying = true
        
        timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            self.currentTime = player.currentTime().seconds
            self.duration = player.currentItem?.duration.seconds ?? 0
            self.updateLrcIndex()
        }
    }
    
    func togglePlay() {
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }
    
    private func updateLrcIndex() {
        guard !lyrics.isEmpty else { return }
        let index = lyrics.lastIndex(where: { $0.time <= currentTime }) ?? 0
        if currentLrcIndex != index {
            currentLrcIndex = index
        }
    }
    
    private func parseLrc(_ lrc: String) -> [LrcLine] {
        var lines: [LrcLine] = []
        let pattern = "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\](.*)"
        let regex = try? NSRegularExpression(pattern: pattern)
        
        lrc.enumerateLines { line, _ in
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex?.firstMatch(in: line, options: [], range: nsRange) {
                let min = Double((line as NSString).substring(with: match.range(at: 1))) ?? 0
                let sec = Double((line as NSString).substring(with: match.range(at: 2))) ?? 0
                let content = (line as NSString).substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                lines.append(LrcLine(time: min * 60 + sec, content: content))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject var client = AListClient()
    @StateObject var playerManager = PlayerManager()
    @State private var showingSettings = false
    @State private var showingPlayer = false
    
    var body: some View {
        NavigationView {
            List {
                if client.currentPath != "/" {
                    Button(action: {
                        let parent = (client.currentPath as NSString).deletingLastPathComponent
                        Task { await client.fetchFiles(path: parent) }
                    }) {
                        Label(".. 返回上级", systemImage: "arrow.up.doc")
                    }
                }
                
                ForEach(client.files) { file in
                    if file.is_dir {
                        Button(action: {
                            Task { await client.fetchFiles(path: client.currentPath + "/" + file.name) }
                        }) {
                            Label(file.name, systemImage: "folder.fill").foregroundColor(.yellow)
                        }
                    } else if file.isAudio {
                        Button(action: {
                            handleAudioTap(file)
                        }) {
                            HStack {
                                Label(file.name, systemImage: "music.note").foregroundColor(.primary)
                                Spacer()
                                if playerManager.currentTrackName == file.name {
                                    Image(systemName: "waveform").foregroundColor(.blue)
                                }
                            }
                        }
                    } else {
                        Label(file.name, systemImage: "doc").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("AList 播放器")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "server.rack")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !playerManager.currentTrackName.isEmpty {
                        Button(action: { showingPlayer = true }) {
                            Image(systemName: "play.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(client: client) }
            .sheet(isPresented: $showingPlayer) { PlayerView(playerManager: playerManager) }
            .onAppear { if client.serverUrl.isEmpty { showingSettings = true } }
        }
    }
    
    func handleAudioTap(_ file: AListFile) {
        Task {
            guard let audioUrl = await client.getDownloadUrl(path: client.currentPath + "/" + file.name) else { return }
            
            // 自动匹配歌词：寻找同名 .lrc 文件
            let baseName = (file.name as NSString).deletingPathExtension
            let lrcFile = client.files.first(where: { ( ($0.name as NSString).deletingPathExtension == baseName ) && $0.isLrc })
            
            var lrcContent: String? = nil
            if let lrcFile = lrcFile {
                if let lrcUrlStr = await client.getDownloadUrl(path: client.currentPath + "/" + lrcFile.name),
                   let lrcUrl = URL(string: lrcUrlStr) {
                    lrcContent = try? String(contentsOf: lrcUrl)
                }
            }
            
            playerManager.play(urlStr: audioUrl, trackName: file.name, lrcContent: lrcContent)
            showingPlayer = true
        }
    }
}

struct SettingsView: View {
    @ObservedObject var client: AListClient
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器配置")) {
                    TextField("服务器地址 (如 http://192.168.1.5:5244)", text: $client.serverUrl)
                    TextField("AList Token (可选)", text: $client.token)
                }
                Button("保存并连接") {
                    Task {
                        await client.fetchFiles(path: "/")
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

struct PlayerView: View {
    @ObservedObject var playerManager: PlayerManager
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 20) {
            Capsule().frame(width: 40, height: 6).foregroundColor(.secondary).padding()
            
            Text(playerManager.currentTrackName)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal)
            
            // 歌词显示区
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 15) {
                        if playerManager.lyrics.isEmpty {
                            Text("\n\n(无歌词)").foregroundColor(.secondary)
                        } else {
                            ForEach(0..<playerManager.lyrics.count, id: \.self) { index in
                                Text(playerManager.lyrics[index].content)
                                    .font(playerManager.currentLrcIndex == index ? .title3.bold() : .body)
                                    .foregroundColor(playerManager.currentLrcIndex == index ? .blue : .secondary)
                                    .multilineTextAlignment(.center)
                                    .id(index)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                .onChange(of: playerManager.currentLrcIndex) { newIndex in
                    withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
            
            // 控制区
            VStack {
                Slider(value: Binding(get: { playerManager.currentTime }, set: { _ in }), in: 0...(playerManager.duration > 0 ? playerManager.duration : 1))
                    .padding(.horizontal)
                
                HStack(spacing: 40) {
                    Button(action: {}) { Image(systemName: "backward.fill").font(.title) }
                    Button(action: { playerManager.togglePlay() }) {
                        Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 60))
                    }
                    Button(action: {}) { Image(systemName: "forward.fill").font(.title) }
                }
            }
            .padding(.bottom, 40)
        }
    }
}

@main
struct TrollAListPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
