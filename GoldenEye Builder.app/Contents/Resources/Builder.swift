// GoldenEye Builder: the window that builds GoldenEye.app without Terminal.
//
// The launcher (Contents/MacOS/GoldenEye Builder) compiles this file with the
// Xcode command line tools the first time it runs, then starts it with the
// builder app's own path as the only argument.
//
// What it does:
//   * finds the project folder (the folder this app sits in),
//   * lets you pick your game files once and remembers where they were,
//   * runs macos/build-macos.sh, showing its progress in a progress bar,
//   * opens the finished GoldenEye.app,
//   * checks GitHub for a newer version of the project and updates it.

import AppKit

let kRepoURL = "https://github.com/alextownleymakes/GoldenEye-Recomp-Mac.git"
let kBranch = "main"

@MainActor
final class Builder: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let bundleURL: URL
  let defaults = UserDefaults.standard

  var window: NSWindow!
  var gameField: NSTextField!
  var chooseButton: NSButton!
  var buildButton: NSButton!
  var openButton: NSButton!
  var finderButton: NSButton!
  var progress: NSProgressIndicator!
  var statusLabel: NSTextField!
  var logView: NSTextView!
  var updateLabel: NSTextField!
  var updateButton: NSButton!

  var root: URL?
  var gamePath: String?
  var task: Process?
  var stageBase = 0.0
  var stageSpan = 0.0
  var pending = ""
  var errorText = ""
  var inError = false
  var logFile: FileHandle?
  var updateKind = ""  // "", "pull" or "checkout"

  nonisolated init(bundle: URL) {
    bundleURL = bundle
  }

  // MARK: - Startup

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    buildWindow()
    NSApp.activate(ignoringOtherApps: true)

    guard let r = findProject() else {
      NSApp.terminate(nil)
      return
    }
    root = r
    // Clear the download quarantine on this app so macOS stops running it
    // from a temporary copy (and stops asking) on later launches.
    runQuietly("/usr/bin/xattr", ["-dr", "com.apple.quarantine", r.appendingPathComponent("GoldenEye Builder.app").path])

    if let saved = defaults.string(forKey: "gamePath"), FileManager.default.fileExists(atPath: saved) {
      gamePath = saved
    }
    refreshGameField()
    refreshOpenButtons()

    if defaults.bool(forKey: "justUpdated") {
      defaults.set(false, forKey: "justUpdated")
      setStatus("Updated to the latest version. Click Build to rebuild GoldenEye with the changes.")
    } else if FileManager.default.fileExists(atPath: gameAppURL().path) {
      setStatus("GoldenEye is built. Open it, or click Build to rebuild.")
    } else {
      setStatus("Choose your game files, then click Build.")
    }
    checkForUpdates()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func isProject(_ u: URL) -> Bool {
    FileManager.default.fileExists(atPath: u.appendingPathComponent("macos/build-macos.sh").path)
  }

  // The project folder: the one this app is in. If macOS is running the app
  // from a temporary copy (a fresh download), use the remembered folder, or
  // ask once.
  func findProject() -> URL? {
    let parent = bundleURL.deletingLastPathComponent()
    if isProject(parent) {
      defaults.set(parent.path, forKey: "projectPath")
      return parent
    }
    if let saved = defaults.string(forKey: "projectPath") {
      let u = URL(fileURLWithPath: saved)
      if isProject(u) { return u }
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select the GoldenEye-Recomp-Mac folder (the one GoldenEye Builder came in)."
    panel.prompt = "Use This Folder"
    while panel.runModal() == .OK, let u = panel.url {
      if isProject(u) {
        defaults.set(u.path, forKey: "projectPath")
        return u
      }
      alert("That isn't the GoldenEye project folder", "Choose the folder that contains GoldenEye Builder and the macos folder.")
    }
    return nil
  }

  // MARK: - Window

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit GoldenEye Builder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    NSApp.mainMenu = main
  }

  func label(_ s: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    return l
  }

  func button(_ title: String, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .rounded
    return b
  }

  func buildWindow() {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "GoldenEye Builder"
    window.minSize = NSSize(width: 560, height: 420)
    window.delegate = self
    window.center()

    let title = label("GoldenEye 007 for Mac", size: 20, bold: true)
    let intro = label("This builds GoldenEye.app from your own copy of the game (the Xbox Live Arcade "
                      + "version). The first build downloads and compiles the recompiler and takes "
                      + "a while (often 30 to 60 minutes); later builds are much faster.")
    intro.textColor = .secondaryLabelColor

    let gameTitle = label("Game files:", bold: true)
    gameField = NSTextField(labelWithString: "")
    gameField.lineBreakMode = .byTruncatingMiddle
    gameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    gameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    chooseButton = button("Choose…", #selector(chooseGame))
    let gameRow = NSStackView(views: [gameTitle, gameField!, chooseButton!])
    gameRow.orientation = .horizontal
    gameRow.spacing = 8

    buildButton = button("Build GoldenEye", #selector(build))
    buildButton.keyEquivalent = "\r"
    openButton = button("Open GoldenEye", #selector(openGame))
    finderButton = button("Show in Finder", #selector(showInFinder))
    let actionRow = NSStackView(views: [buildButton!, openButton!, finderButton!])
    actionRow.orientation = .horizontal
    actionRow.spacing = 8

    progress = NSProgressIndicator()
    progress.isIndeterminate = false
    progress.minValue = 0
    progress.maxValue = 100
    progress.doubleValue = 0
    progress.style = .bar

    statusLabel = label("")

    let scroll = NSTextView.scrollableTextView()
    logView = scroll.documentView as? NSTextView
    logView.isEditable = false
    logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    logView.textColor = .secondaryLabelColor
    scroll.borderType = .bezelBorder

    updateLabel = label("Checking for updates…", size: 11)
    updateLabel.textColor = .secondaryLabelColor
    updateButton = button("Update", #selector(applyUpdate))
    updateButton.isHidden = true
    let updateRow = NSStackView(views: [updateLabel!, updateButton!])
    updateRow.orientation = .horizontal
    updateRow.spacing = 8

    let stack = NSStackView(views: [title, intro, gameRow, actionRow, progress!, statusLabel!, scroll, updateRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(stack)
    let cv = window.contentView!
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
      stack.topAnchor.constraint(equalTo: cv.topAnchor),
      stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
    ])
    for v in [intro, gameRow, progress!, statusLabel!, scroll, updateRow] as [NSView] {
      v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.makeKeyAndOrderFront(nil)
  }

  func setStatus(_ s: String) { statusLabel.stringValue = s }

  func gameAppURL() -> URL { root!.appendingPathComponent("GoldenEye.app") }

  func refreshGameField() {
    if let g = gamePath {
      gameField.stringValue = g
      gameField.textColor = .labelColor
    } else if let r = root, FileManager.default.fileExists(atPath: r.appendingPathComponent("assets/default.xex").path) {
      gameField.stringValue = "Already in the project's assets folder"
      gameField.textColor = .secondaryLabelColor
    } else {
      gameField.stringValue = "Not chosen yet"
      gameField.textColor = .secondaryLabelColor
    }
  }

  func refreshOpenButtons() {
    let built = root != nil && FileManager.default.fileExists(atPath: gameAppURL().path)
    openButton.isEnabled = built && task == nil
    finderButton.isEnabled = built
  }

  func setBusy(_ busy: Bool) {
    buildButton.isEnabled = !busy
    chooseButton.isEnabled = !busy
    updateButton.isEnabled = !busy
    refreshOpenButtons()
  }

  // MARK: - Game files

  func gameProblem(_ u: URL) -> String? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return "It no longer exists." }
    if isDir.boolValue {
      if fm.fileExists(atPath: u.appendingPathComponent("default.xex").path) { return nil }
      if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
        for case let f as URL in e {
          if isPackage(f) { return nil }
        }
      }
      return "That folder has no default.xex and no Xbox Live Arcade package in it."
    }
    if u.lastPathComponent == "default.xex" || isPackage(u) { return nil }
    return "That file isn't the game. Choose the Xbox Live Arcade download (the file with no extension) or default.xex."
  }

  func isPackage(_ u: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: u) else { return false }
    defer { try? h.close() }
    let magic = h.readData(ofLength: 4)
    guard magic.count == 4, let s = String(data: magic, encoding: .ascii) else { return false }
    return s == "LIVE" || s == "PIRS" || s == "CON "
  }

  @objc func chooseGame() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose your GoldenEye 007 Xbox Live Arcade download (the file with no extension), "
      + "or a folder containing default.xex."
    panel.prompt = "Choose"
    if let g = gamePath {
      panel.directoryURL = URL(fileURLWithPath: g).deletingLastPathComponent()
    } else if let last = defaults.string(forKey: "lastGameFolder") {
      panel.directoryURL = URL(fileURLWithPath: last)
    }
    guard panel.runModal() == .OK, let u = panel.url else { return }
    defaults.set(u.deletingLastPathComponent().path, forKey: "lastGameFolder")
    if let problem = gameProblem(u) {
      alert("Those aren't the game files", problem)
      return
    }
    gamePath = u.path
    defaults.set(u.path, forKey: "gamePath")
    refreshGameField()
    setStatus("Ready. Click Build GoldenEye.")
  }

  // MARK: - Build

  // (keyword in the script's "==> " step line, progress at its start, its
  // share of the bar, what to show)
  let stages: [(String, Double, Double, String)] = [
    ("Checking build tools", 0, 2, "Checking the developer tools…"),
    ("Getting build tools", 2, 4, "Downloading build tools (first time only)…"),
    ("Checking game files", 6, 1, "Checking your game files…"),
    ("Getting ReXGlue SDK", 7, 6, "Downloading the recompiler (first time only)…"),
    ("Building ReXGlue SDK", 13, 42, "Building the recompiler (first time only; this is the long part)…"),
    ("ReXGlue SDK already built", 55, 0, "Recompiler ready."),
    ("Unpacking game package", 55, 3, "Unpacking your game files…"),
    ("Recompiling default.xex", 58, 4, "Converting the game to Mac code…"),
    ("Building GoldenEye.app", 62, 35, "Building GoldenEye…"),
    ("Packaging GoldenEye.app", 97, 2, "Packaging GoldenEye.app…"),
    ("Done", 100, 0, "Done."),
  ]

  @objc func build() {
    guard let r = root, task == nil else { return }
    if gamePath == nil && !FileManager.default.fileExists(atPath: r.appendingPathComponent("assets/default.xex").path) {
      chooseGame()
      if gamePath == nil { return }
    }
    if let g = gamePath, let problem = gameProblem(URL(fileURLWithPath: g)) {
      alert("Your game files moved", problem + "\n\nChoose them again.")
      gamePath = nil
      defaults.removeObject(forKey: "gamePath")
      refreshGameField()
      return
    }

    logView.string = ""
    errorText = ""
    inError = false
    pending = ""
    progress.doubleValue = 0
    stageBase = 0
    stageSpan = 0
    setStatus("Starting…")

    let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoldenEye")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("builder.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    logFile = try? FileHandle(forWritingTo: logURL)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    var args = [r.appendingPathComponent("macos/build-macos.sh").path]
    if let g = gamePath { args.append(g) }
    p.arguments = args
    p.currentDirectoryURL = r
    var env = ProcessInfo.processInfo.environment
    env["GE_NONINTERACTIVE"] = "1"
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { return }
      let s = String(decoding: d, as: UTF8.self)
      Task { @MainActor in self?.consume(s) }
    }
    p.terminationHandler = { [weak self] pr in
      let code = pr.terminationStatus
      pr.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
      Task { @MainActor in self?.finished(code) }
    }
    do {
      try p.run()
    } catch {
      alert("Couldn't start the build", error.localizedDescription)
      return
    }
    task = p
    setBusy(true)
    NSApp.dockTile.badgeLabel = "…"
  }

  func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
  }

  func consume(_ chunk: String) {
    pending += chunk
    var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
    pending = lines.removeLast()
    for raw in lines {
      let line = stripANSI(raw)
      if line.isEmpty { continue }
      appendLog(line)
      handle(line)
    }
  }

  func appendLog(_ line: String) {
    if let data = (line + "\n").data(using: .utf8) { logFile?.write(data) }
    guard let storage = logView.textStorage else { return }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    storage.append(NSAttributedString(string: line + "\n", attributes: attrs))
    if storage.length > 300_000 {
      storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 200_000))
    }
    logView.scrollToEndOfDocument(nil)
  }

  func handle(_ line: String) {
    if line.hasPrefix("Error:") {
      inError = true
      errorText = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      return
    }
    if inError {
      errorText += "\n" + line.trimmingCharacters(in: .whitespaces)
      return
    }
    if line.hasPrefix("==> ") {
      let step = String(line.dropFirst(4))
      for s in stages where step.hasPrefix(s.0) {
        stageBase = s.1
        stageSpan = s.2
        progress.doubleValue = s.1
        setStatus(s.3)
        break
      }
      return
    }
    // Ninja's "[12/345] ..." lines move the bar within a build step.
    if stageSpan > 0, line.hasPrefix("["), let close = line.firstIndex(of: "]") {
      let inner = line[line.index(after: line.startIndex)..<close].split(separator: "/")
      if inner.count == 2, let a = Double(inner[0]), let b = Double(inner[1]), b > 0 {
        progress.doubleValue = stageBase + stageSpan * min(1, a / b)
      }
    }
  }

  func finished(_ code: Int32) {
    if !pending.isEmpty {
      let line = stripANSI(pending)
      pending = ""
      appendLog(line)
      handle(line)
    }
    try? logFile?.close()
    logFile = nil
    task = nil
    setBusy(false)
    NSApp.dockTile.badgeLabel = nil
    if code == 0 {
      progress.doubleValue = 100
      setStatus("GoldenEye is ready. It's in the project folder as GoldenEye.app; you can move it to Applications.")
      refreshGameField()
      refreshOpenButtons()
      NSApp.requestUserAttention(.informationalRequest)
      let a = NSAlert()
      a.messageText = "GoldenEye is built"
      a.informativeText = "GoldenEye.app is in the project folder. You can move it to your Applications folder."
      a.addButton(withTitle: "Open GoldenEye")
      a.addButton(withTitle: "Later")
      if a.runModal() == .alertFirstButtonReturn { openGame() }
    } else if code == 15 || code == 143 {
      setStatus("Build stopped.")
    } else {
      setStatus("The build didn't finish.")
      NSApp.requestUserAttention(.criticalRequest)
      let detail = errorText.isEmpty ? lastLines(12) : errorText
      alert("The build didn't finish", detail + "\n\nThe full log is saved in your Library/Logs/GoldenEye folder as builder.log.")
    }
  }

  func lastLines(_ n: Int) -> String {
    let lines = logView.string.split(separator: "\n")
    return lines.suffix(n).joined(separator: "\n")
  }

  @objc func openGame() {
    NSWorkspace.shared.openApplication(at: gameAppURL(), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
  }

  @objc func showInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([gameAppURL()])
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let p = task, p.isRunning else { return true }
    let a = NSAlert()
    a.messageText = "Stop the build?"
    a.informativeText = "GoldenEye is still being built. If you quit now, the next build picks up where this one left off."
    a.addButton(withTitle: "Keep Building")
    a.addButton(withTitle: "Stop and Quit")
    if a.runModal() == .alertSecondButtonReturn {
      runQuietly("/usr/bin/pkill", ["-TERM", "-P", String(p.processIdentifier)])
      p.terminate()
      return true
    }
    return false
  }

  // MARK: - Updates

  @discardableResult
  nonisolated static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func runQuietly(_ exe: String, _ args: [String]) {
    DispatchQueue.global(qos: .utility).async { _ = Builder.run(exe, args) }
  }

  nonisolated static func git(_ root: String, _ args: [String]) -> (Int32, String) {
    run("/usr/bin/git", ["-C", root] + args)
  }

  nonisolated static func checkoutKey(_ root: String) -> String { "needsCheckout:" + root }

  func checkForUpdates() {
    updateLabel.stringValue = "Checking for updates…"
    updateButton.isHidden = true
    let rootPath = root!.path
    DispatchQueue.global(qos: .utility).async {
      let result = Builder.updateStatus(rootPath)
      Task { @MainActor in
        self.updateKind = result.0
        self.updateLabel.stringValue = result.1
        self.updateButton.isHidden = result.0.isEmpty
      }
    }
  }

  // ("" | "pull" | "checkout", message)
  nonisolated static func updateStatus(_ root: String) -> (String, String) {
    let fm = FileManager.default
    let defaults = UserDefaults.standard
    let git = { (args: [String]) -> (Int32, String) in Builder.git(root, args) }
    let checkoutKey = Builder.checkoutKey(root)
    if !fm.fileExists(atPath: root + "/.git") {
      // Downloaded as a ZIP: link this folder to the GitHub project once.
      // The index is set to the latest version without touching any files;
      // the files that differ are what an update would change.
      if git(["init", "-q"]).0 != 0 { return ("", "Updates unavailable (couldn't set up git).") }
      _ = git(["remote", "add", "origin", kRepoURL])
      if git(["fetch", "-q", "origin", kBranch]).0 != 0 {
        return ("", "Couldn't check for updates (no internet connection?).")
      }
      _ = git(["reset", "-q", "--mixed", "origin/" + kBranch])
      _ = git(["branch", "-q", "--set-upstream-to=origin/" + kBranch])
      let changed = git(["status", "--porcelain", "--untracked-files=no"]).1
      if changed.isEmpty { return ("", "Up to date.") }
      defaults.set(true, forKey: checkoutKey)
      return ("checkout", "A newer version is available.")
    }
    if defaults.bool(forKey: checkoutKey) {
      return ("checkout", "A newer version is available.")
    }
    if git(["remote", "get-url", "origin"]).0 != 0 {
      _ = git(["remote", "add", "origin", kRepoURL])
    }
    if git(["fetch", "-q", "origin", kBranch]).0 != 0 {
      return ("", "Couldn't check for updates (no internet connection?).")
    }
    let behind = git(["rev-list", "--count", "HEAD..origin/" + kBranch]).1
    if let n = Int(behind), n > 0 {
      return ("pull", n == 1 ? "1 update available." : "\(n) updates available.")
    }
    return ("", "Up to date.")
  }

  @objc func applyUpdate() {
    guard task == nil, let r = root else { return }
    let kind = updateKind
    let rootPath = r.path
    updateButton.isEnabled = false
    buildButton.isEnabled = false
    updateLabel.stringValue = "Updating…"
    DispatchQueue.global(qos: .userInitiated).async {
      let res = kind == "checkout"
        ? Builder.git(rootPath, ["checkout", "--", "."])
        : Builder.git(rootPath, ["pull", "--ff-only", "origin", kBranch])
      let ok = res.0 == 0
      let message = res.1
      Task { @MainActor in
        if ok {
          self.defaults.set(false, forKey: Builder.checkoutKey(rootPath))
          self.defaults.set(true, forKey: "justUpdated")
          let a = NSAlert()
          a.messageText = "Updated"
          a.informativeText = "GoldenEye Builder will restart. Then click Build to rebuild GoldenEye with the changes."
          a.runModal()
          let app = self.root!.appendingPathComponent("GoldenEye Builder.app")
          Builder.run("/usr/bin/open", ["-n", app.path])
          NSApp.terminate(nil)
        } else {
          self.updateButton.isEnabled = true
          self.buildButton.isEnabled = true
          self.updateLabel.stringValue = "Update failed."
          self.alert("Couldn't update automatically",
                     "Some files in the project folder were changed, so the update was left alone to "
                       + "avoid overwriting them. You can download the project again from GitHub instead.\n\n"
                       + message)
        }
      }
    }
  }

  // MARK: - Helpers

  func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
  }
}

let bundlePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : Bundle.main.bundlePath
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Builder(bundle: URL(fileURLWithPath: bundlePath))
app.delegate = delegate
app.run()
