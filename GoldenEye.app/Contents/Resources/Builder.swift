// GoldenEye: the app that builds and plays GoldenEye without Terminal, from
// either version of the game: the Xbox 360 (XBLA) one, which becomes
// GoldenEye.app, and the Nintendo 64 ROM, which becomes GoldenEye 64.app.
//
// The launcher script in Contents/MacOS compiles this file with the
// Xcode command line tools the first time it runs, then starts it with the
// app's own path as the only argument.
//
// What it does:
//   * finds the project folder (the folder this app sits in),
//   * lets you pick the game files for each version once and remembers them,
//   * runs macos/build-macos.sh (Xbox) or macos/build-n64.sh (N64), showing
//     progress in a progress bar,
//   * keeps the finished games inside itself (Contents/Games) and plays
//     them from here: while a game runs this window steps aside, and it comes
//     back when the game quits,
//   * checks GitHub for a newer version of the project and updates it.

import AppKit

// Settings are kept under the name earlier versions used, so chosen game
// files and the project folder are remembered across the rename.
let kSettings = UserDefaults(suiteName: "GoldenEyeBuilder") ?? .standard

let kRepoURL = "https://github.com/alextownleymakes/GoldenEye-Recomp-Mac.git"
let kBranch = "main"

// One playable version of the game: its game files, build script, app and
// the controls for it in the window. Only used on the main thread.
final class Version {
  enum Kind { case xbox, n64 }
  let kind: Kind
  let title: String       // section heading
  let shortName: String   // used in buttons and messages
  let appName: String     // the built game, kept in Contents/Games
  let script: String      // build script, relative to the project folder
  let pathKey: String     // remembered game files
  let folderKey: String   // remembered folder for the file picker
  let stages: [(String, Double, Double, String)]

  var path: String?
  var field: NSTextField!
  var chooseButton: NSButton!
  var buildButton: NSButton!
  var openButton: NSButton!

  init(kind: Kind) {
    self.kind = kind
    switch kind {
    case .xbox:
      title = "Xbox 360 version (Xbox Live Arcade)"
      shortName = "GoldenEye"
      appName = "GoldenEye.app"
      script = "macos/build-macos.sh"
      pathKey = "gamePath"
      folderKey = "lastGameFolder"
      // (keyword in the script's "==> " line, bar position, its share, status)
      stages = [
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
    case .n64:
      title = "Nintendo 64 version (ROM)"
      shortName = "GoldenEye 64"
      appName = "GoldenEye 64.app"
      script = "macos/build-n64.sh"
      pathKey = "n64RomPath"
      folderKey = "lastN64Folder"
      stages = [
        ("Checking build tools", 0, 2, "Checking the developer tools…"),
        ("Getting build tools", 2, 3, "Downloading build tools (first time only)…"),
        ("Checking your ROM", 5, 1, "Checking your ROM…"),
        ("Getting N64Recomp", 6, 4, "Downloading the N64 recompiler (first time only)…"),
        ("Building N64Recomp", 10, 10, "Building the N64 recompiler (first time only)…"),
        ("N64Recomp already built", 20, 0, "N64 recompiler ready."),
        ("Recompiling the game", 20, 4, "Converting the game to Mac code…"),
        ("Getting the N64 runtime", 24, 8, "Downloading the N64 runtime and graphics (first time only)…"),
        ("Building SDL", 32, 5, "Building window, sound and controller support (first time only)…"),
        ("Building GoldenEye 64", 37, 60, "Building GoldenEye 64 (the long part the first time)…"),
        ("Packaging GoldenEye 64", 97, 2, "Packaging GoldenEye 64…"),
        ("Done", 100, 0, "Done."),
      ]
    }
  }
}

@MainActor
final class Builder: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let bundleURL: URL
  let defaults = kSettings

  var window: NSWindow!
  var progress: NSProgressIndicator!
  var statusLabel: NSTextField!
  var logView: NSTextView!
  var updateLabel: NSTextField!
  var updateButton: NSButton!
  var cleanButton: NSButton!
  var locateButton: NSButton!

  let xbox = Version(kind: .xbox)
  let n64 = Version(kind: .n64)
  var versions: [Version] { [xbox, n64] }

  var root: URL?
  var task: Process?
  var building: Version?
  var stageBase = 0.0
  var stageSpan = 0.0
  var pending = ""
  var errorText = ""
  var inError = false
  var logFile: FileHandle?
  var updateKind = ""  // "", "pull" or "checkout"
  var playing: Version?   // the game running right now, if any
  var playingPID: pid_t = 0

  nonisolated init(bundle: URL) {
    bundleURL = bundle
  }

  // MARK: - Startup

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    buildWindow()
    NSApp.activate(ignoringOtherApps: true)

    // The built games don't need the project folder; only building and
    // updates do. Without it, this window still plays them.
    root = findProject()
    if root != nil {
      if relocate() { return }
      if syncFromProject() { return }
      adoptOldBuilds()
    }
    watchForGameExit()
    // Clear the download quarantine on this app so macOS stops running it
    // from a temporary copy (and stops asking) on later launches.
    runQuietly("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appBundle().path])

    for v in versions {
      if let saved = defaults.string(forKey: v.pathKey), FileManager.default.fileExists(atPath: saved) {
        v.path = saved
      }
      refreshField(v)
    }
    refreshButtons()

    if root == nil {
      let built = versions.filter { isBuilt($0) }.map { $0.shortName }
      setStatus(built.isEmpty
        ? "The project folder isn't on this Mac. Download it, or locate it, to build the games."
        : built.joined(separator: " and ") + (built.count == 1 ? " is" : " are")
          + " ready to play. Building and updates need the project folder.")
      showNoProject()
      return
    }
    if defaults.bool(forKey: "justUpdated") {
      defaults.set(false, forKey: "justUpdated")
      setStatus("Updated to the latest version. Build again to get the changes.")
    } else {
      let built = versions.filter { isBuilt($0) }.map { $0.shortName }
      setStatus(built.isEmpty
        ? "Choose game files for the version you want, then click its Build button."
        : built.joined(separator: " and ") + (built.count == 1 ? " is" : " are") + " built. Click Play, or build again.")
    }
    checkForUpdates()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func isProject(_ u: URL) -> Bool {
    FileManager.default.fileExists(atPath: u.appendingPathComponent("macos/build-macos.sh").path)
  }

  // The project folder: in Application Support once moved there, else the one
  // this app is in, else the remembered one. nil if none (Locate… finds it).
  func findProject() -> URL? {
    if isProject(projectHome()) {
      defaults.set(projectHome().path, forKey: "projectPath")
      return projectHome()
    }
    let parent = bundleURL.deletingLastPathComponent()
    if isProject(parent) {
      defaults.set(parent.path, forKey: "projectPath")
      return parent
    }
    if let saved = defaults.string(forKey: "projectPath") {
      let u = URL(fileURLWithPath: saved)
      if isProject(u) { return u }
    }
    return nil
  }

  // MARK: - Window

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit GoldenEye", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

  func button(_ title: String, _ action: Selector, _ tag: Int) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .rounded
    b.tag = tag
    return b
  }

  // A shaded section for one version: heading, game files row and buttons.
  func section(_ v: Version, tag: Int, note: String) -> NSStackView {
    let heading = label(v.title, size: 14, bold: true)
    let info = label(note, size: 11)
    info.textColor = .secondaryLabelColor

    let filesTitle = label(v.kind == .xbox ? "Game files:" : "ROM:", bold: true)
    v.field = NSTextField(labelWithString: "")
    v.field.lineBreakMode = .byTruncatingMiddle
    v.field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    v.field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    v.chooseButton = button("Choose…", #selector(choose(_:)), tag)
    let filesRow = NSStackView(views: [filesTitle, v.field!, v.chooseButton!])
    filesRow.orientation = .horizontal
    filesRow.spacing = 8

    v.buildButton = button("Build " + v.shortName, #selector(build(_:)), tag)
    v.openButton = button("Play " + v.shortName, #selector(openGame(_:)), tag)
    let actionRow = NSStackView(views: [v.buildButton!, v.openButton!])
    actionRow.orientation = .horizontal
    actionRow.spacing = 8

    let box = NSStackView(views: [heading, info, filesRow, actionRow])
    box.orientation = .vertical
    box.alignment = .leading
    box.spacing = 8
    box.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
    box.layer?.cornerRadius = 8
    for w in [heading, info, filesRow] as [NSView] {
      w.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -28).isActive = true
    }
    return box
  }

  func buildWindow() {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "GoldenEye"
    window.minSize = NSSize(width: 580, height: 560)
    window.delegate = self
    window.center()

    let title = label("GoldenEye 007 for Mac", size: 20, bold: true)
    let intro = label("Build either version, or both, from your own copy of the game. Each one becomes "
                      + "playable right here: click Play. The first build of each downloads and compiles "
                      + "its recompiler, so it takes a while; later builds are much faster.")
    intro.textColor = .secondaryLabelColor

    let xboxBox = section(xbox, tag: 0,
      note: "Uses the Xbox Live Arcade download (the file with no extension) or a folder with default.xex. "
        + "Builds GoldenEye.app. First build: often 30 to 60 minutes.")
    let n64Box = section(n64, tag: 1,
      note: "Uses a GoldenEye 007 (USA) N64 ROM: .z64, .v64 or .n64. Builds GoldenEye 64.app. "
        + "First build: often 20 to 40 minutes.")

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
    updateButton = button("Update", #selector(applyUpdate), 0)
    updateButton.isHidden = true
    locateButton = button("Locate Project…", #selector(locateProject), 0)
    locateButton.isHidden = true
    cleanButton = button("Free Up Space", #selector(freeUpSpace), 0)
    cleanButton.toolTip = "Delete build leftovers (several GB). Built games stay playable; the next build takes longer."
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let updateRow = NSStackView(views: [updateLabel!, updateButton!, locateButton!, spacer, cleanButton!])
    updateRow.orientation = .horizontal
    updateRow.spacing = 8

    let stack = NSStackView(views: [title, intro, xboxBox, n64Box, progress!, statusLabel!, scroll, updateRow])
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
    for v in [intro, xboxBox, n64Box, progress!, statusLabel!, scroll, updateRow] as [NSView] {
      v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.makeKeyAndOrderFront(nil)
  }

  func setStatus(_ s: String) { statusLabel.stringValue = s }

  func version(_ sender: Any?) -> Version {
    (sender as? NSButton)?.tag == 1 ? n64 : xbox
  }

  // This app's bundle. When macOS runs a fresh download from a temporary
  // copy, bundleURL is that copy, so use the bundle in the project folder.
  func appBundle() -> URL {
    if !bundleURL.path.contains("/AppTranslocation/") || root == nil { return bundleURL }
    return projectApp() ?? root!.appendingPathComponent(bundleURL.lastPathComponent)
  }

  // The copy of this app that came with the project (updates land there).
  func projectApp() -> URL? {
    guard let r = root else { return nil }
    let named = r.appendingPathComponent("GoldenEye.app")
    if isThisApp(named) { return named }
    let items = (try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil)) ?? []
    return items.first(where: { $0.pathExtension == "app" && isThisApp($0) })
  }

  func isThisApp(_ u: URL) -> Bool {
    FileManager.default.fileExists(atPath: u.appendingPathComponent("Contents/Resources/Builder.swift").path)
  }

  // Where the project lives once the app has tidied itself up.
  func projectHome() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("GoldenEye/Project")
  }

  // First launch from a download: put this app in Applications and the rest
  // of the project (code, tools, builds) in Application Support, so the
  // downloaded folder can go. Returns true if it moved and is restarting.
  func relocate() -> Bool {
    let fm = FileManager.default
    let from = root!.standardizedFileURL
    let home = projectHome()
    if from.path == home.standardizedFileURL.path { return false }
    if defaults.string(forKey: "keepProjectAt") == from.path { return false }

    let a = NSAlert()
    a.messageText = "Move GoldenEye into Applications?"
    a.informativeText = "The app goes in Applications, and everything else it needs (code, tools, builds) "
      + "goes in your Library's Application Support folder. The folder you downloaded is then no longer needed."
    a.addButton(withTitle: "Move")
    a.addButton(withTitle: "Keep It Here")
    if a.runModal() != .alertFirstButtonReturn {
      defaults.set(from.path, forKey: "keepProjectAt")
      return false
    }

    if fm.fileExists(atPath: home.path) { try? fm.removeItem(at: home) }
    try? fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try fm.moveItem(at: from, to: home) } catch {
      alert("Couldn't move GoldenEye", error.localizedDescription + "\n\nIt will keep working from where it is.")
      return false
    }
    root = home
    defaults.set(home.path, forKey: "projectPath")
    if defaults.bool(forKey: Builder.checkoutKey(from.path)) {
      defaults.set(true, forKey: Builder.checkoutKey(home.path))
    }
    for v in versions {  // game files chosen from inside the old folder
      if let p = defaults.string(forKey: v.pathKey), p.hasPrefix(from.path + "/") {
        defaults.set(home.path + p.dropFirst(from.path.count), forKey: v.pathKey)
      }
    }

    // The app itself: /Applications, or ~/Applications if that isn't writable.
    guard let src = projectApp() else { return false }
    var apps = URL(fileURLWithPath: "/Applications")
    if !fm.isWritableFile(atPath: apps.path) {
      apps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
      try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
    }
    var dest = apps.appendingPathComponent("GoldenEye.app")
    if fm.fileExists(atPath: dest.path) && !isThisApp(dest) {
      dest = apps.appendingPathComponent("GoldenEye Builder.app")
    }
    if isThisApp(dest) { try? fm.removeItem(at: dest) }
    do { try fm.copyItem(at: src, to: dest) } catch {
      alert("Moved GoldenEye's files, but couldn't add the app to Applications",
            error.localizedDescription + "\n\nThe app is in " + src.path + ".")
      dest = src
    }
    _ = Builder.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
    Builder.run("/usr/bin/open", ["-n", dest.path])
    NSApp.terminate(nil)
    return true
  }

  // Built games live next to the settings, so any copy of this app (in the
  // project folder, in Applications, anywhere) plays the same ones.
  func gamesDir() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("GoldenEye/Games")
  }

  func appURL(_ v: Version) -> URL { gamesDir().appendingPathComponent(v.appName) }

  // When this copy lives outside the project folder, keep it in step with
  // the project's copy (which is what updates change). Returns true if it
  // updated itself and is restarting.
  func syncFromProject() -> Bool {
    let fm = FileManager.default
    let here = bundleURL.standardizedFileURL
    if here.path.contains("/AppTranslocation/") { return false }
    if here.deletingLastPathComponent().path == root!.standardizedFileURL.path { return false }
    // Moved out rather than copied: put the project's copy back from git.
    if projectApp() == nil, fm.fileExists(atPath: root!.appendingPathComponent(".git").path) {
      _ = Builder.git(root!.path, ["checkout", "--", "GoldenEye.app"])
    }
    guard let src = projectApp()?.standardizedFileURL, src.path != here.path else { return false }
    let parts = ["Contents/Resources/Builder.swift", "Contents/Resources/AppIcon.icns",
                 "Contents/Info.plist", "Contents/MacOS/GoldenEye Builder"]
    var changed = false
    for part in parts {
      let a = src.appendingPathComponent(part), b = here.appendingPathComponent(part)
      guard let new = fm.contents(atPath: a.path), fm.contents(atPath: b.path) != new else { continue }
      try? fm.removeItem(at: b)
      if (try? fm.copyItem(at: a, to: b)) != nil { changed = true }
    }
    guard changed else { return false }
    Builder.run("/usr/bin/open", ["-n", here.path])
    NSApp.terminate(nil)
    return true
  }

  // Earlier versions of the builder kept the games in the project folder,
  // then inside the app. Move them over so they don't need building again.
  func adoptOldBuilds() {
    let fm = FileManager.default
    var oldDirs = [root!, bundleURL.appendingPathComponent("Contents/Games")]
    if let p = projectApp() { oldDirs.append(p.appendingPathComponent("Contents/Games")) }
    for v in versions {
      for dir in oldDirs {
        let old = dir.appendingPathComponent(v.appName)
        guard fm.fileExists(atPath: old.path), !isThisApp(old), !fm.fileExists(atPath: appURL(v).path) else { continue }
        try? fm.createDirectory(at: gamesDir(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: appURL(v))
      }
    }
    for dir in oldDirs.dropFirst() where (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
      try? fm.removeItem(at: dir)
    }
  }

  func isBuilt(_ v: Version) -> Bool {
    FileManager.default.fileExists(atPath: appURL(v).path)
  }

  // Game files already in the project's assets folder (used when nothing
  // was chosen).
  func assetsGame(_ v: Version) -> String? {
    guard let r = root else { return nil }
    switch v.kind {
    case .xbox:
      let x = r.appendingPathComponent("assets/default.xex")
      return FileManager.default.fileExists(atPath: x.path) ? x.path : nil
    case .n64:
      return findROM(in: r.appendingPathComponent("assets/n64"))?.path
    }
  }

  func refreshField(_ v: Version) {
    if let g = v.path {
      v.field.stringValue = g
      v.field.textColor = .labelColor
    } else if assetsGame(v) != nil {
      v.field.stringValue = v.kind == .xbox ? "Already in the project's assets folder"
                                             : "Already in the project's assets/n64 folder"
      v.field.textColor = .secondaryLabelColor
    } else {
      v.field.stringValue = "Not chosen yet"
      v.field.textColor = .secondaryLabelColor
    }
  }

  func refreshButtons() {
    let busy = task != nil
    for v in versions {
      let built = isBuilt(v)
      v.buildButton.isEnabled = !busy && playing !== v && root != nil  // can't replace a running game
      v.chooseButton.isEnabled = !busy && root != nil
      v.openButton.isEnabled = built && building !== v && playing == nil
    }
    updateButton.isEnabled = !busy
    cleanButton.isEnabled = !busy && root != nil
    locateButton.isEnabled = !busy
  }

  func setBusy(_ busy: Bool) {
    refreshButtons()
    if busy {
      for v in versions {
        v.buildButton.isEnabled = false
        v.chooseButton.isEnabled = false
      }
      updateButton.isEnabled = false
      cleanButton.isEnabled = false
      locateButton.isEnabled = false
    }
  }

  // MARK: - Game files

  func gameProblem(_ v: Version, _ u: URL) -> String? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return "It no longer exists." }
    switch v.kind {
    case .xbox:
      if isDir.boolValue {
        if fm.fileExists(atPath: u.appendingPathComponent("default.xex").path) { return nil }
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
          for case let f as URL in e {
            if isPackage(f) { return nil }
          }
        }
        if findROM(in: u) != nil {
          return "That folder has an N64 ROM in it. Choose it in the Nintendo 64 section instead."
        }
        return "That folder has no default.xex and no Xbox Live Arcade package in it."
      }
      if u.lastPathComponent == "default.xex" || isPackage(u) { return nil }
      if romFormat(u) != nil {
        return "That's an N64 ROM. Choose it in the Nintendo 64 section instead."
      }
      return "That file isn't the Xbox game. Choose the Xbox Live Arcade download (the file with no extension) or default.xex."
    case .n64:
      let rom = isDir.boolValue ? findROM(in: u) : u
      guard let f = rom, romFormat(f) != nil else {
        if !isDir.boolValue && (u.lastPathComponent == "default.xex" || isPackage(u)) {
          return "That's the Xbox version. Choose it in the Xbox 360 section instead."
        }
        return isDir.boolValue ? "That folder has no N64 ROM in it."
                               : "That file isn't an N64 ROM. Choose a .z64, .v64 or .n64 file."
      }
      if let id = romID(f), !id.hasPrefix("NGE") {
        return "That ROM isn't GoldenEye 007."
      }
      if let id = romID(f), id != "NGEE" {
        return "That's GoldenEye 007, but not the US version. GoldenEye 64 needs the US (NTSC-U) ROM."
      }
      return nil
    }
  }

  func isPackage(_ u: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: u) else { return false }
    defer { try? h.close() }
    let magic = h.readData(ofLength: 4)
    guard magic.count == 4, let s = String(data: magic, encoding: .ascii) else { return false }
    return s == "LIVE" || s == "PIRS" || s == "CON "
  }

  // The first 0x40 bytes of an N64 ROM, in .z64 (big-endian) byte order, or
  // nil if it isn't one.
  func romHeader(_ u: URL) -> [UInt8]? {
    guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
    defer { try? h.close() }
    var b = [UInt8](h.readData(ofLength: 0x40))
    guard b.count == 0x40 else { return nil }
    switch (b[0], b[1], b[2], b[3]) {
    case (0x80, 0x37, 0x12, 0x40): break
    case (0x37, 0x80, 0x40, 0x12):  // .v64: byte pairs swapped
      for i in stride(from: 0, to: 0x40, by: 2) { b.swapAt(i, i + 1) }
    case (0x40, 0x12, 0x37, 0x80):  // .n64: little-endian words
      for i in stride(from: 0, to: 0x40, by: 4) { b.swapAt(i, i + 3); b.swapAt(i + 1, i + 2) }
    default: return nil
    }
    return b
  }

  func romFormat(_ u: URL) -> String? { romHeader(u) == nil ? nil : u.pathExtension }

  // Game ID from the ROM header ("NGEE" is GoldenEye 007, USA).
  func romID(_ u: URL) -> String? {
    guard let b = romHeader(u) else { return nil }
    return String(bytes: b[0x3B..<0x3F], encoding: .ascii)
  }

  func findROM(in folder: URL) -> URL? {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
    for case let f as URL in e {
      if e.level > 2 { e.skipDescendants(); continue }
      let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size >= 4 << 20, romHeader(f) != nil { return f }
    }
    return nil
  }

  @objc func choose(_ sender: Any?) {
    chooseFiles(version(sender))
  }

  func chooseFiles(_ v: Version) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    switch v.kind {
    case .xbox:
      panel.canChooseDirectories = true
      panel.message = "Xbox 360 version: choose your GoldenEye 007 Xbox Live Arcade download "
        + "(the file with no extension), or a folder containing default.xex."
    case .n64:
      panel.canChooseDirectories = false
      panel.message = "Nintendo 64 version: choose your GoldenEye 007 (USA) ROM (.z64, .v64 or .n64)."
    }
    panel.prompt = "Choose"
    if let g = v.path {
      panel.directoryURL = URL(fileURLWithPath: g).deletingLastPathComponent()
    } else if let last = defaults.string(forKey: v.folderKey) {
      panel.directoryURL = URL(fileURLWithPath: last)
    } else if v.kind == .n64, let r = root {
      panel.directoryURL = r.appendingPathComponent("assets/n64")
    }
    guard panel.runModal() == .OK, let u = panel.url else { return }
    defaults.set(u.deletingLastPathComponent().path, forKey: v.folderKey)
    if let problem = gameProblem(v, u) {
      alert(v.kind == .xbox ? "Those aren't the Xbox game files" : "That isn't the right ROM", problem)
      return
    }
    v.path = u.path
    defaults.set(u.path, forKey: v.pathKey)
    refreshField(v)
    setStatus("Ready. Click Build " + v.shortName + ".")
  }

  // MARK: - Build

  @objc func build(_ sender: Any?) {
    let v = version(sender)
    guard let r = root, task == nil else { return }
    if v.path == nil && assetsGame(v) == nil {
      chooseFiles(v)
      if v.path == nil { return }
    }
    if let g = v.path, let problem = gameProblem(v, URL(fileURLWithPath: g)) {
      alert(v.kind == .xbox ? "Your game files moved" : "Your ROM moved", problem + "\n\nChoose again.")
      v.path = nil
      defaults.removeObject(forKey: v.pathKey)
      refreshField(v)
      return
    }

    logView.string = ""
    errorText = ""
    inError = false
    pending = ""
    progress.doubleValue = 0
    stageBase = 0
    stageSpan = 0
    setStatus("Starting " + v.shortName + "…")

    let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoldenEye")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent(v.kind == .xbox ? "builder.log" : "builder-n64.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    logFile = try? FileHandle(forWritingTo: logURL)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    var args = [r.appendingPathComponent(v.script).path]
    if let g = v.path ?? (v.kind == .n64 ? assetsGame(v) : nil) { args.append(g) }
    p.arguments = args
    p.currentDirectoryURL = r
    var env = ProcessInfo.processInfo.environment
    env["GE_NONINTERACTIVE"] = "1"
    env["GE_APP_DIR"] = gamesDir().path
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
    building = v
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
      for s in building?.stages ?? [] where step.hasPrefix(s.0) {
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
    let v = building ?? xbox
    task = nil
    building = nil
    setBusy(false)
    NSApp.dockTile.badgeLabel = nil
    if code == 0 {
      progress.doubleValue = 100
      setStatus(v.shortName + " is ready. Click Play " + v.shortName + ".")
      refreshField(v)
      refreshButtons()
      if playing != nil { return }  // don't interrupt a game; the status says it's ready
      NSApp.requestUserAttention(.informationalRequest)
      let a = NSAlert()
      a.messageText = v.shortName + " is built"
      a.informativeText = "Play it now, or any time from here."
      a.addButton(withTitle: "Play " + v.shortName)
      a.addButton(withTitle: "Later")
      if a.runModal() == .alertFirstButtonReturn { launch(v) }
    } else if code == 15 || code == 143 {
      setStatus(v.shortName + " build stopped.")
    } else {
      setStatus(v.shortName + " didn't finish building.")
      NSApp.requestUserAttention(.criticalRequest)
      let detail = errorText.isEmpty ? lastLines(12) : errorText
      let log = v.kind == .xbox ? "builder.log" : "builder-n64.log"
      alert(v.shortName + " didn't finish building",
            detail + "\n\nThe full log is saved in your Library/Logs/GoldenEye folder as " + log + ".")
    }
  }

  func lastLines(_ n: Int) -> String {
    let lines = logView.string.split(separator: "\n")
    return lines.suffix(n).joined(separator: "\n")
  }

  @objc func openGame(_ sender: Any?) { launch(version(sender)) }

  // Start a game. This window and its Dock icon step aside while it runs,
  // and come back when the game quits.
  func launch(_ v: Version) {
    guard playing == nil, isBuilt(v) else { return }
    playing = v
    refreshButtons()
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: appURL(v), configuration: config) { [weak self] app, error in
      let pid = app?.processIdentifier ?? 0
      let message = error?.localizedDescription
      Task { @MainActor in self?.gameStarted(v, pid: pid, error: message) }
    }
  }

  func gameStarted(_ v: Version, pid: pid_t, error: String?) {
    guard pid > 0 else {
      playing = nil
      refreshButtons()
      alert("Couldn't start " + v.shortName, error ?? "")
      return
    }
    playingPID = pid
    window.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  func watchForGameExit() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let pid = app?.processIdentifier ?? 0
      Task { @MainActor in self?.gameExited(pid) }
    }
  }

  func gameExited(_ pid: pid_t) {
    guard playing != nil, pid == playingPID else { return }
    playing = nil
    playingPID = 0
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refreshButtons()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let p = task, p.isRunning else { return true }
    let a = NSAlert()
    a.messageText = "Stop the build?"
    a.informativeText = (building?.shortName ?? "GoldenEye")
      + " is still being built. If you quit now, the next build picks up where this one left off."
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
    guard let r = root else { return }
    updateLabel.stringValue = "Checking for updates…"
    updateButton.isHidden = true
    let rootPath = r.path
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
    let defaults = kSettings
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
    setBusy(true)
    updateLabel.stringValue = "Updating…"
    DispatchQueue.global(qos: .userInitiated).async {
      if !FileManager.default.fileExists(atPath: rootPath + "/GoldenEye.app/Contents/Resources/Builder.swift") {
        _ = Builder.git(rootPath, ["checkout", "--", "GoldenEye.app"])
      }
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
          a.informativeText = "GoldenEye will restart. Then build again to get the changes."
          a.runModal()
          let app = self.appBundle()
          Builder.run("/usr/bin/open", ["-n", app.path])
          NSApp.terminate(nil)
        } else {
          self.setBusy(false)
          self.updateLabel.stringValue = "Update failed."
          self.alert("Couldn't update automatically",
                     "Some files in the project folder were changed, so the update was left alone to "
                       + "avoid overwriting them. You can download the project again from GitHub instead.\n\n"
                       + message)
        }
      }
    }
  }

  // MARK: - Without the project folder

  func showNoProject() {
    updateLabel.stringValue = "No project folder: building and updates are off."
    updateButton.title = "Download Project"
    updateButton.action = #selector(downloadProject)
    updateButton.isHidden = false
    locateButton.isHidden = false
    cleanButton.isHidden = true
    refreshButtons()
  }

  func restart() {
    Builder.run("/usr/bin/open", ["-n", bundleURL.path])
    NSApp.terminate(nil)
  }

  @objc func locateProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select the GoldenEye-Recomp-Mac folder."
    panel.prompt = "Use This Folder"
    while panel.runModal() == .OK, let u = panel.url {
      if isProject(u) {
        defaults.set(u.path, forKey: "projectPath")
        restart()
        return
      }
      alert("That isn't the GoldenEye project folder", "Choose the folder that contains the macos folder.")
    }
  }

  // Get the project again (latest version only, not its history) into
  // Application Support, then restart with it.
  @objc func downloadProject() {
    guard task == nil else { return }
    let home = projectHome()
    setBusy(true)
    updateLabel.stringValue = "Downloading the project…"
    progress.isIndeterminate = true
    progress.startAnimation(nil)
    DispatchQueue.global(qos: .userInitiated).async {
      let fm = FileManager.default
      if fm.fileExists(atPath: home.path) { try? fm.removeItem(at: home) }
      try? fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
      let res = Builder.run("/usr/bin/git", ["clone", "-q", "--depth", "1", "--branch", kBranch, kRepoURL, home.path])
      Task { @MainActor in
        self.progress.stopAnimation(nil)
        self.progress.isIndeterminate = false
        if res.0 == 0 {
          self.defaults.set(home.path, forKey: "projectPath")
          self.restart()
        } else {
          self.setBusy(false)
          self.updateLabel.stringValue = "Download failed."
          self.alert("Couldn't download the project", "Check your internet connection and try again.\n\n" + res.1)
        }
      }
    }
  }

  // MARK: - Free up space

  // Build leftovers the next build makes again: the game builds, the
  // recompiled code, the SDK's build folder (its installed copy stays, so the
  // SDK isn't rebuilt) and SDL's sources (its installed copy stays). Built
  // games, game files, settings and downloaded tools stay.
  nonisolated static func cleanupTargets(_ root: String) -> [String] {
    var t = [root + "/out/build", root + "/out/n64", root + "/generated",
             root + "/macos/.deps/rexglue-sdk/out/build"]
    let deps = root + "/macos/.deps"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: deps)) ?? [] where name.hasPrefix("SDL2-") {
      t.append(deps + "/" + name)
    }
    return t.filter { FileManager.default.fileExists(atPath: $0) }
  }

  nonisolated static func diskSize(_ path: String) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
    else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
      if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
        total += Int64(v.totalFileAllocatedSize ?? 0)
      }
    }
    return total
  }

  @objc func freeUpSpace() {
    guard task == nil, let r = root else { return }
    let rootPath = r.path
    setBusy(true)
    setStatus("Working out how much space the build leftovers take…")
    DispatchQueue.global(qos: .userInitiated).async {
      let targets = Builder.cleanupTargets(rootPath)
      let size = targets.reduce(Int64(0)) { $0 + Builder.diskSize($1) }
      Task { @MainActor in self.confirmFreeUp(targets, size) }
    }
  }

  func confirmFreeUp(_ targets: [String], _ size: Int64) {
    setBusy(false)
    let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    if size < 20_000_000 {
      setStatus("Nothing to clean up.")
      return
    }
    let a = NSAlert()
    a.messageText = "Free up \(text)?"
    a.informativeText = "This deletes build leftovers in the project folder. The games you've built stay "
      + "playable, and your game files and settings are kept. The next build takes longer, because it "
      + "compiles the game again."
    a.addButton(withTitle: "Free Up Space")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else {
      setStatus("")
      return
    }
    setBusy(true)
    setStatus("Deleting build leftovers…")
    DispatchQueue.global(qos: .userInitiated).async {
      for t in targets { try? FileManager.default.removeItem(atPath: t) }
      Task { @MainActor in
        self.setBusy(false)
        self.setStatus("Freed \(text). Your built games are still here.")
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
