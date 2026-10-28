import AppKit
import ImageIO
import Darwin

// Draw directly at the selected paper's printable size, including enlargement.
final class CapturePrintView: NSView {
    let image: NSImage
    let fillPage: Bool

    init(image: NSImage, fillPage: Bool) {
        self.image = image
        self.fillPage = fillPage
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }

    func printableSize() -> NSSize {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        return NSSize(width: max(1, info.paperSize.width-info.leftMargin-info.rightMargin),
                      height: max(1, info.paperSize.height-info.topMargin-info.bottomMargin))
    }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        setFrameSize(printableSize())
        return true
    }
    override func rectForPage(_ page: Int) -> NSRect {
        setFrameSize(printableSize())
        return bounds
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        let sx = bounds.width/image.size.width, sy = bounds.height/image.size.height
        let scale = fillPage ? max(sx, sy) : min(sx, sy)
        let size = NSSize(width: image.size.width*scale, height: image.size.height*scale)
        let destination = NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// The helper watches only the screenshot destination. Existing files are ignored.
final class CapturePrinter: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let folder = URL(fileURLWithPath: "__HOME__/Desktop/captures", isDirectory: true)
    let settings = UserDefaults.standard
    var seen = Set<String>()
    var pending = [String: (URL, Date)]()
    var directoryWatcher: DispatchSourceFileSystemObject?
    var retry: DispatchWorkItem?
    let watchQueue = DispatchQueue(label: "captures.directory-events", qos: .userInteractive)
    var status: NSStatusItem!
    var enabledItem: NSMenuItem!
    var busy = false
    var currentWindow: NSWindow?
    var currentImage: NSImage?
    var currentImageView: NSImageView?
    var enabled = true
    var scanning = false
    var rescanRequested = false
    var scopedFolder: URL?
    var fillPage = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        enabled = settings.object(forKey: "enabled") == nil || settings.bool(forKey: "enabled")
        fillPage = settings.bool(forKey: "fillPage")
        buildMenu()
        if let bookmark = settings.data(forKey: "capturesBookmark") {
            var stale = false
            if let restored = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), restored.startAccessingSecurityScopedResource() {
                scopedFolder = restored
                startWatching()
                return
            }
        }
        selectFolder()
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Carpeta de capturas"
        panel.message = "Selecciona captures para mostrar cada nueva captura en una única ventana con botón Imprimir."
        panel.prompt = "Usar captures"
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let selected = panel.url,
                  selected.standardizedFileURL.path == self.folder.standardizedFileURL.path else { return }
            self.scopedFolder = selected
            _ = selected.startAccessingSecurityScopedResource()
            if let data = try? selected.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                self.settings.set(data, forKey: "capturesBookmark")
            }
            self.startWatching()
        }
    }

    func startWatching() {
        DispatchQueue.global(qos: .userInitiated).async {
            let baseline = Set(self.files().map(\.lastPathComponent))
            DispatchQueue.main.async {
                self.seen = baseline
                let fd = open(self.folder.path, O_EVTONLY)
                guard fd >= 0 else { NSLog("Unable to watch screenshot directory"); return }
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: self.watchQueue)
                watcher.setEventHandler { [weak self] in
                    DispatchQueue.main.async { self?.scan() }
                }
                watcher.setCancelHandler { close(fd) }
                self.directoryWatcher = watcher
                watcher.resume()
                self.scan()
                NSLog("Immediate capture preview ready; filesystem events, no polling delay")
            }
        }
    }

    func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
    }

    func isCapture(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic", "tiff", "tif"].contains(url.pathExtension.lowercased()) else { return false }
        let name = url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CH"))
        return ["capture d’ecran ", "capture d'ecran ", "screenshot ", "screen shot ", "captura de pantalla ", "bildschirmfoto "].contains(where: name.hasPrefix)
    }

    func scan() {
        guard !scanning else { rescanRequested = true; return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let current = self.files()
            DispatchQueue.main.async {
                self.process(current)
                self.scanning = false
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scan()
                }
            }
        }
    }

    func process(_ current: [URL]) {
        for file in current where !seen.contains(file.lastPathComponent) {
            let name = file.lastPathComponent
            guard enabled && isCapture(file) else { seen.insert(name); continue }
            if pending[name] == nil { pending[name] = (file, Date()) }
        }
        displayReadyCaptures()
    }

    func displayReadyCaptures() {
        retry?.cancel()
        var newest: (URL, NSImage, Date)?
        for (name, item) in pending {
            let (file, discovered) = item
            if Date().timeIntervalSince(discovered) > 10 {
                pending.removeValue(forKey: name)
                seen.insert(name)
                continue
            }
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            seen.insert(name)
            pending.removeValue(forKey: name)
            let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? discovered
            if newest == nil || modified >= newest!.2 { newest = (file, image, modified) }
        }
        if let (file, image, modified) = newest {
            showCapture(file, image: image)
            NSLog("Capture visible %.0f ms after file write", Date().timeIntervalSince(modified) * 1000)
        }
        if !pending.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.displayReadyCaptures() }
            retry = work
            // Retry only files still being written, not the whole directory.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter Captures Imprimer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem(title: "Fichier", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Fichier")
        let printItem = NSMenuItem(title: "Imprimer…", action: #selector(printCurrent), keyEquivalent: "p")
        printItem.target = self
        fileMenu.addItem(printItem)
        let a3Item = NSMenuItem(title: "Imprimir en A3…", action: #selector(printCurrentA3), keyEquivalent: "9")
        a3Item.keyEquivalentModifierMask = [.command, .shift]
        a3Item.target = self
        fileMenu.addItem(a3Item)
        fileMenu.addItem(withTitle: "Fermer", action: #selector(closeWindow), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem(title: "Edición", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edición")
        let copyItem = NSMenuItem(title: "Copiar captura", action: #selector(copyCurrent), keyEquivalent: "c")
        copyItem.target = self
        editMenu.addItem(copyItem)
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Impression après capture")
        status.button?.toolTip = "Vista previa de capturas"
        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "Mostrar capturas al instante", action: #selector(toggle), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(withTitle: "Ouvrir le dossier captures", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
    }

    @objc func toggle() {
        enabled.toggle()
        settings.set(enabled, forKey: "enabled")
        enabledItem.state = enabled ? .on : .off
        if !enabled { pending.removeAll() }
    }
    @objc func openFolder() { NSWorkspace.shared.open(folder) }
    @objc func closeWindow() { currentWindow?.close() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copyCurrent) {
            return currentImage != nil && currentWindow?.isKeyWindow == true && !busy
        }
        return true
    }
    @objc func copyCurrent() {
        guard !busy, let image = currentImage else { return }
        let item = NSPasteboardItem()
        if let url = currentWindow?.representedURL,
           url.pathExtension.lowercased() == "png",
           let originalPNG = try? Data(contentsOf: url) {
            item.setData(originalPNG, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if item.data(forType: .png) == nil,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        guard !item.types.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return }
        currentWindow?.title = "Captura copiada — ⌘P normal · ⌘⇧9 A3"
        let copiedURL = currentWindow?.representedURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.currentWindow?.representedURL == copiedURL else { return }
            self?.currentWindow?.title = "Captura — ⌘P normal · ⌘⇧9 A3"
        }
        NSLog("Current capture copied to clipboard as image")
    }
    @objc func changePrintFit(_ sender: NSPopUpButton) {
        fillPage = sender.indexOfSelectedItem == 1
        settings.set(fillPage, forKey: "fillPage")
    }
    @objc func printCurrent() {
        guard !busy, let image = currentImage else { return }
        busy = true
        printImage(image)
        busy = false
    }
    @objc func printCurrentA3() {
        guard !busy, let image = currentImage else { return }
        busy = true
        printImage(image, a3: true)
        busy = false
    }

    func showCapture(_ url: URL, image: NSImage) {
        currentImage = image
        if currentWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 850, height: 350)
            window.title = "Captura — ⌘P normal · ⌘⇧9 A3"
            let view = NSImageView(frame: NSRect(x: 15, y: 65, width: 820, height: 570))
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(view)
            let button = NSButton(title: "Imprimir… (⌘P)", target: self, action: #selector(printCurrent))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 520, y: 16, width: 125, height: 34)
            button.autoresizingMask = [.minXMargin]
            window.contentView?.addSubview(button)
            let a3Button = NSButton(title: "Imprimir A3… (⌘⇧9)", target: self, action: #selector(printCurrentA3))
            a3Button.bezelStyle = .rounded
            a3Button.frame = NSRect(x: 655, y: 16, width: 180, height: 34)
            a3Button.autoresizingMask = [.minXMargin]
            a3Button.setAccessibilityLabel("Imprimir captura en A3")
            window.contentView?.addSubview(a3Button)
            let fit = NSPopUpButton(frame: NSRect(x: 18, y: 16, width: 300, height: 34), pullsDown: false)
            fit.addItems(withTitles: ["Imagen completa · máximo tamaño", "Llenar hoja · recorta bordes"])
            fit.selectItem(at: fillPage ? 1 : 0)
            fit.target = self
            fit.action = #selector(changePrintFit(_:))
            fit.setAccessibilityLabel("Ajuste de impresión")
            window.contentView?.addSubview(fit)
            let label = NSTextField(labelWithString: "Orientación automática")
            label.frame = NSRect(x: 327, y: 25, width: 180, height: 18)
            label.textColor = .secondaryLabelColor
            window.contentView?.addSubview(label)
            window.center()
            currentWindow = window
            currentImageView = view
        }
        currentWindow?.representedURL = url
        currentWindow?.title = "Captura — ⌘P normal · ⌘⇧9 A3"
        currentImageView?.image = image
        NSApp.activate(ignoringOtherApps: true)
        currentWindow?.makeKeyAndOrderFront(nil)
        NSLog("Updated single preview window; awaiting button or Command-P")
    }

    func printImage(_ image: NSImage, a3: Bool = false) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if a3 {
            if let printer = NSPrinter(name: "__A3_PRINTER__") { info.printer = printer }
            info.paperSize = NSSize(width: 841.89, height: 1190.55)
            info.paperName = NSPrinter.PaperName(rawValue: "A3")
        }
        info.orientation = image.size.width > image.size.height ? .landscape : .portrait
        info.scalingFactor = 1
        // Use the actual printer margins, rather than adding an artificial frame.
        let printable = info.imageablePageBounds
        info.leftMargin = max(0, printable.minX)
        info.bottomMargin = max(0, printable.minY)
        info.rightMargin = max(0, info.paperSize.width-printable.maxX)
        info.topMargin = max(0, info.paperSize.height-printable.maxY)
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let view = CapturePrintView(image: image, fillPage: fillPage)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = a3 ? "Capture d’écran — A3" : "Capture d’écran"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation])
        // A normal native print panel asks the user to choose paper and confirm.
        // The helper never submits an unattended job to the printer.
        let printed = operation.run()
        NSLog(printed ? "Print confirmed" : "Print dialog cancelled")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = CapturePrinter()
app.delegate = delegate
app.run()
