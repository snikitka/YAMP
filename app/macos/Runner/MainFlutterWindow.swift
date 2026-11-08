import Cocoa
import FlutterMacOS
import MediaPlayer

class MainFlutterWindow: NSWindow {
  private static let normalMin = NSSize(width: 900, height: 600)
  private static let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

  private var media: MediaControls?
  private var desktop: FlutterMethodChannel?
  private var normalFrame: NSRect?
  private var compactFrame: NSRect?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "YAMP"
    self.minSize = MainFlutterWindow.normalMin
    self.setContentSize(NSSize(width: 1240, height: 820))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    let messenger = flutterViewController.engine.binaryMessenger
    media = MediaControls(messenger: messenger)
    desktop = FlutterMethodChannel(name: "yamp/desktop", binaryMessenger: messenger)
    desktop?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "compact":
        if args["on"] as? Bool ?? false {
          self.enterCompact(width: args["width"] as? Int ?? 380, height: args["height"] as? Int ?? 168)
        } else {
          self.leaveCompact()
        }
      case "pin":
        self.level = (args["on"] as? Bool ?? false) ? .floating : .normal
      case "drag":
        if self.normalFrame != nil, NSEvent.pressedMouseButtons & 1 != 0, let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
      case "resize":
        break
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }

    super.awakeFromNib()
  }

  private func enterCompact(width: Int, height: Int) {
    let size = NSSize(width: width, height: height)
    if normalFrame == nil {
      normalFrame = frame
      styleMask.insert(.fullSizeContentView)
      titlebarAppearsTransparent = true
      titleVisibility = .hidden
      for kind in MainFlutterWindow.buttons {
        standardWindowButton(kind)?.isHidden = true
      }
    }
    contentMinSize = size
    contentMaxSize = NSSize(width: size.width * 2, height: size.height * 2.5)
    if let saved = compactFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
      setFrame(saved, display: true)
      return
    }
    var target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
    let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    target.origin = NSPoint(x: area.maxX - target.width - 24, y: area.minY + 24)
    setFrame(target, display: true)
  }

  private func leaveCompact() {
    guard let normal = normalFrame else { return }
    compactFrame = frame
    normalFrame = nil
    level = .normal
    for kind in MainFlutterWindow.buttons {
      standardWindowButton(kind)?.isHidden = false
    }
    titleVisibility = .visible
    titlebarAppearsTransparent = false
    styleMask.remove(.fullSizeContentView)
    contentMaxSize = MainFlutterWindow.unlimited
    maxSize = MainFlutterWindow.unlimited
    minSize = MainFlutterWindow.normalMin
    setFrame(normal, display: true)
  }
}

final class MediaControls {
  private let channel: FlutterMethodChannel
  private var playing = false
  private var info: [String: Any] = [:]
  private var artURL = ""
  private var artwork: MPMediaItemArtwork?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "yamp/media", binaryMessenger: messenger)
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.addTarget { [weak self] _ in self?.send("play") ?? .commandFailed }
    commands.pauseCommand.addTarget { [weak self] _ in self?.send("pause") ?? .commandFailed }
    commands.stopCommand.addTarget { [weak self] _ in self?.send("pause") ?? .commandFailed }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return self.send(self.playing ? "pause" : "play")
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in self?.send("next") ?? .commandFailed }
    commands.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous") ?? .commandFailed }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      return self.send("seek", Int(event.positionTime * 1000))
    }
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        if let state = call.arguments as? [String: Any] {
          self?.update(state)
        }
      case "stop":
        self?.stop()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
  }

  private func send(_ method: String, _ arguments: Any? = nil) -> MPRemoteCommandHandlerStatus {
    channel.invokeMethod(method, arguments: arguments)
    return .success
  }

  private func seconds(_ value: Any?) -> Double {
    return ((value as? NSNumber)?.doubleValue ?? 0) / 1000
  }

  private func update(_ state: [String: Any]) {
    playing = state["playing"] as? Bool ?? false
    var next: [String: Any] = [
      MPMediaItemPropertyTitle: state["title"] as? String ?? "",
      MPMediaItemPropertyArtist: state["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: state["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: seconds(state["duration"]),
      MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds(state["position"]),
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    let url = state["art"] as? String ?? ""
    if url != artURL {
      artURL = url
      artwork = nil
      load(url)
    }
    if let artwork {
      next[MPMediaItemPropertyArtwork] = artwork
    }
    info = next
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = next
    center.playbackState = playing ? .playing : .paused
  }

  private func load(_ url: String) {
    guard let address = URL(string: url), !url.isEmpty else { return }
    URLSession.shared.dataTask(with: address) { [weak self] data, _, _ in
      guard let data, let image = NSImage(data: data) else { return }
      DispatchQueue.main.async {
        guard let self, self.artURL == url, !self.info.isEmpty else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = artwork
        self.info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
      }
    }.resume()
  }

  private func stop() {
    playing = false
    info = [:]
    artURL = ""
    artwork = nil
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }
}
