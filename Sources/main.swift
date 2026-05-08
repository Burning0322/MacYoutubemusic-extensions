import AppKit
import Foundation

struct TrackState: Codable {
    var source: String
    var title: String
    var artist: String
    var albumArtUrl: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var lyricsLines: [String]
    var lyricsStatus: String?
    var updatedAt: Double
}

struct PlayerCommand: Codable {
    var id: Int
    var action: String
    var value: Double?
}

final class SharedState {
    private let lock = NSLock()
    private var state: TrackState?
    private var nextCommandId = 1
    private var pendingCommands: [PlayerCommand] = []

    func update(_ newState: TrackState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    func snapshot() -> TrackState? {
        lock.lock()
        let copy = state
        lock.unlock()
        return copy
    }

    func enqueueCommand(action: String, value: Double? = nil) {
        lock.lock()
        pendingCommands.append(PlayerCommand(id: nextCommandId, action: action, value: value))
        nextCommandId += 1
        lock.unlock()
    }

    func drainCommands() -> [PlayerCommand] {
        lock.lock()
        let commands = pendingCommands
        pendingCommands.removeAll()
        lock.unlock()
        return commands
    }
}

final class LocalHTTPServer {
    private let sharedState: SharedState
    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "ytmusic-island.http", qos: .userInitiated)

    init(sharedState: SharedState) {
        self.sharedState = sharedState
    }

    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    private func run() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            fputs("Failed to create socket\n", stderr)
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(47833).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            fputs("Failed to bind 127.0.0.1:47833. Is another copy running?\n", stderr)
            close(serverSocket)
            return
        }

        guard listen(serverSocket, SOMAXCONN) == 0 else {
            fputs("Failed to listen on 127.0.0.1:47833\n", stderr)
            close(serverSocket)
            return
        }

        while true {
            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientLen)
                }
            }
            if client >= 0 {
                handle(client)
                close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let expectedLength = contentLength(from: headers)
                let bodyStart = headerEnd.upperBound
                if data.count - bodyStart >= expectedLength { break }
            }
            if data.count > 1_000_000 { break }
        }

        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            respond(client, code: "400 Bad Request", body: "bad request")
            return
        }

        let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""

        if requestLine.hasPrefix("OPTIONS ") {
            respond(client, code: "204 No Content", body: "")
            return
        }

        if requestLine.hasPrefix("GET /commands ") {
            let commands = sharedState.drainCommands()
            let data = (try? JSONEncoder().encode(commands)) ?? Data("[]".utf8)
            let body = String(data: data, encoding: .utf8) ?? "[]"
            respond(client, code: "200 OK", body: body)
            return
        }

        guard requestLine.hasPrefix("POST /state ") else {
            respond(client, code: "404 Not Found", body: "not found")
            return
        }

        let body = data[headerEnd.upperBound...]
        do {
            let incoming = try JSONDecoder().decode(TrackState.self, from: body)
            sharedState.update(incoming)
            respond(client, code: "200 OK", body: "{\"ok\":true}")
        } catch {
            respond(client, code: "400 Bad Request", body: "{\"ok\":false}")
        }
    }

    private func contentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1]) ?? 0
            }
        }
        return 0
    }

    private func respond(_ client: Int32, code: String, body: String) {
        let response = """
        HTTP/1.1 \(code)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }
}

final class IslandWindow: NSWindow {
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private let originDefaultsKey = "YTMusicIslandWindowOrigin"

    init(contentView: NSView) {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 112)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - dragStartMouseLocation.x
        let deltaY = currentMouseLocation.y - dragStartMouseLocation.y
        let newOrigin = NSPoint(x: dragStartOrigin.x + deltaX, y: dragStartOrigin.y + deltaY)
        setFrameOrigin(newOrigin)
        UserDefaults.standard.set(["x": newOrigin.x, "y": newOrigin.y], forKey: originDefaultsKey)
    }
}

protocol IslandViewDelegate: AnyObject {
    func islandViewDidRequestCommand(_ action: String, value: Double?)
}

final class IslandView: NSView {
    weak var delegate: IslandViewDelegate?
    var state: TrackState?
    var albumImage: NSImage?
    private var lastAlbumUrl: String = ""
    private var phase: CGFloat = 0
    private var buttonRects: [String: NSRect] = [:]

    override var isFlipped: Bool { true }

    func tick() {
        phase += 0.08
        needsDisplay = true
    }

    func update(state: TrackState?) {
        self.state = state
        loadAlbumIfNeeded(state?.albumArtUrl ?? "")
        needsDisplay = true
    }

    private func loadAlbumIfNeeded(_ urlString: String) {
        guard !urlString.isEmpty, urlString != lastAlbumUrl, let url = URL(string: urlString) else { return }
        lastAlbumUrl = urlString
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.albumImage = image
                self?.needsDisplay = true
            }
        }.resume()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let visibleState = state
        let active = visibleState != nil
        let rect = active ? bounds.insetBy(dx: 0, dy: 0) : centeredSmallRect()
        drawIsland(in: rect, active: active)

        guard let state = visibleState else {
            drawIdle(in: rect)
            return
        }

        if active {
            drawExpanded(state: state, in: rect)
        } else {
            drawCompact(state: state, in: rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (action, rect) in buttonRects where rect.contains(point) {
            switch action {
            case "seekBackward":
                delegate?.islandViewDidRequestCommand("seek", value: -10)
            case "seekForward":
                delegate?.islandViewDidRequestCommand("seek", value: 10)
            default:
                delegate?.islandViewDidRequestCommand(action, value: nil)
            }
            return
        }
        window?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        window?.mouseDragged(with: event)
    }

    private func centeredSmallRect() -> NSRect {
        NSRect(x: (bounds.width - 230) / 2, y: 22, width: 230, height: 54)
    }

    private func drawIsland(in rect: NSRect, active: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 0.015, alpha: active ? 0.96 : 0.88).setFill()
        path.fill()

        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()
    }

    private func drawIdle(in rect: NSRect) {
        let text = "Waiting for YouTube Music"
        drawText(text, in: rect.insetBy(dx: 24, dy: 16), font: .systemFont(ofSize: 13, weight: .medium), color: NSColor.white.withAlphaComponent(0.72))
    }

    private func drawCompact(state: TrackState, in rect: NSRect) {
        drawArtwork(in: NSRect(x: rect.minX + 8, y: rect.minY + 8, width: 38, height: 38))
        drawText(clean(state.title), in: NSRect(x: rect.minX + 56, y: rect.minY + 10, width: rect.width - 76, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        drawText("Paused", in: NSRect(x: rect.minX + 56, y: rect.minY + 29, width: rect.width - 76, height: 16), font: .systemFont(ofSize: 11, weight: .regular), color: NSColor.white.withAlphaComponent(0.52))
    }

    private func drawExpanded(state: TrackState, in rect: NSRect) {
        buttonRects.removeAll()
        drawArtwork(in: NSRect(x: rect.minX + 14, y: rect.minY + 14, width: 70, height: 70))
        drawText(clean(state.title), in: NSRect(x: 98, y: 16, width: 220, height: 20), font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
        drawText(clean(state.artist), in: NSRect(x: 98, y: 38, width: 220, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: NSColor.white.withAlphaComponent(0.58))
        drawProgress(state: state, in: NSRect(x: 98, y: 60, width: 190, height: 5))
        drawControls(isPlaying: state.isPlaying, y: 72)
        drawWaveform(in: NSRect(x: 342, y: 20, width: 58, height: 46))

        let lyric = currentLyric(for: state)
        drawText(lyric, in: NSRect(x: 98, y: 96, width: 292, height: 14), font: .systemFont(ofSize: 11, weight: .medium), color: NSColor(calibratedRed: 0.70, green: 0.88, blue: 1.0, alpha: 0.92))
    }

    private func drawControls(isPlaying: Bool, y: CGFloat) {
        let specs: [(String, String, CGFloat)] = [
            ("previous", "⏮", 98),
            ("seekBackward", "-10", 132),
            ("playPause", isPlaying ? "⏸" : "▶", 166),
            ("seekForward", "+10", 200),
            ("next", "⏭", 234)
        ]

        for (action, symbol, x) in specs {
            let rect = NSRect(x: x, y: y, width: 26, height: 20)
            buttonRects[action] = rect.insetBy(dx: -4, dy: -4)
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1), xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(action == "playPause" ? 0.14 : 0.07).setFill()
            background.fill()
            drawText(symbol, in: rect, font: .systemFont(ofSize: 13, weight: .semibold), color: NSColor.white.withAlphaComponent(0.9), alignment: .center)
        }
    }

    private func drawArtwork(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let albumImage {
            albumImage.draw(in: rect)
        } else {
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setFill()
            rect.fill()
            let note = "♪"
            drawText(note, in: rect.insetBy(dx: 0, dy: 12), font: .systemFont(ofSize: 26, weight: .bold), color: NSColor.white.withAlphaComponent(0.66), alignment: .center)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawProgress(state: TrackState, in rect: NSRect) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.12).setFill()
        background.fill()

        let ratio = state.duration > 0 ? max(0, min(1, state.position / state.duration)) : 0
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        NSColor(calibratedRed: 0.16, green: 0.72, blue: 1, alpha: 0.95).setFill()
        fill.fill()
    }

    private func drawWaveform(in rect: NSRect) {
        let bars = 14
        let barWidth = rect.width / CGFloat(bars * 2)
        for index in 0..<bars {
            let x = rect.minX + CGFloat(index) * barWidth * 2
            let wave = sin(phase + CGFloat(index) * 0.72)
            let height = rect.height * (0.22 + 0.62 * (wave + 1) / 2)
            let y = rect.midY - height / 2
            let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            NSColor(calibratedRed: 0.20, green: 0.72, blue: 1.0, alpha: 0.35 + CGFloat(index % 4) * 0.10).setFill()
            path.fill()
        }
    }

    private func currentLyric(for state: TrackState) -> String {
        let lines = state.lyricsLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else {
            if state.lyricsStatus == "lyrics-tab-not-open" {
                return "Open YouTube Music Lyrics to show synced lines"
            }
            return "Lyrics are not available for this track"
        }
        guard state.duration > 0 else { return lines.first ?? "" }
        let index = Int((state.position / state.duration) * Double(lines.count))
        return lines[max(0, min(lines.count - 1, index))]
    }

    private func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "YouTube Music" : trimmed
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, IslandViewDelegate {
    private let sharedState = SharedState()
    private var server: LocalHTTPServer?
    private var window: IslandWindow?
    private let islandView = IslandView(frame: NSRect(x: 0, y: 0, width: 420, height: 112))
    private var timer: Timer?
    private var didInitialPosition = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        server = LocalHTTPServer(sharedState: sharedState)
        server?.start()

        islandView.delegate = self
        let window = IslandWindow(contentView: islandView)
        self.window = window
        positionWindow(width: 420, height: 112)
        window.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    func islandViewDidRequestCommand(_ action: String, value: Double?) {
        sharedState.enqueueCommand(action: action, value: value)
    }

    private func refreshUI() {
        let snapshot = sharedState.snapshot()
        let now = Date().timeIntervalSince1970
        let fresh = snapshot.flatMap { now - $0.updatedAt < 3.0 ? $0 : nil }
        islandView.update(state: fresh)
        islandView.tick()

        if fresh == nil {
            window?.alphaValue = 0.0
            return
        }

        let active = fresh != nil
        let width: CGFloat = active ? 420 : 260
        let height: CGFloat = active ? 112 : 76
        positionWindow(width: width, height: height)
        window?.alphaValue = 1.0
    }

    private func positionWindow(width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main, let window else { return }
        let visibleFrame = screen.visibleFrame

        if !didInitialPosition {
            if let saved = UserDefaults.standard.dictionary(forKey: "YTMusicIslandWindowOrigin"),
               let savedX = saved["x"] as? CGFloat,
               let savedY = saved["y"] as? CGFloat {
                window.setFrame(NSRect(x: savedX, y: savedY, width: width, height: height), display: true, animate: false)
            } else {
                let x = visibleFrame.midX - width / 2
                let y = visibleFrame.maxY - height - 12
                window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)
            }
            didInitialPosition = true
        } else if abs(window.frame.width - width) > 0.5 || abs(window.frame.height - height) > 0.5 {
            let frame = window.frame
            let x = frame.midX - width / 2
            let y = frame.maxY - height
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
        }

        islandView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
