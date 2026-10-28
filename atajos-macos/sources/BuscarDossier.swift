import AppKit
import Foundation

private struct Dossier {
    let url: URL
    let name: String
    let context: String
    let normalized: String
    let words: [String]
}

private func normalize(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CH"))
    return folded.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func distance(_ a: String, _ b: String, limit: Int = 2) -> Int {
    let x = Array(a), y = Array(b)
    if abs(x.count - y.count) > limit { return limit + 1 }
    var previous = Array(0...y.count)
    for (i, letter) in x.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: y.count)
        for j in y.indices {
            current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (letter == y[j] ? 0 : 1))
        }
        if (current.min() ?? 0) > limit { return limit + 1 }
        previous = current
    }
    return previous[y.count]
}

private func score(_ query: String, in dossier: Dossier, popularity: [String: Int]) -> Int? {
    let terms = query.split(separator: " ").map(String.init)
    guard !terms.isEmpty else { return nil }
    var total = 0
    let name = normalize(dossier.name)
    for term in terms {
        if dossier.words.contains(term) { total += name.contains(term) ? 100 : 70; continue }
        if dossier.words.contains(where: { $0.hasPrefix(term) }) { total += 85; continue }
        if dossier.normalized.contains(term) { total += 65; continue }
        guard term.count >= 4 else { return nil }
        var bestWord = ""
        var bestEdits = 3
        for word in dossier.words {
            let edits = distance(term, word)
            if edits < bestEdits || (edits == bestEdits && (popularity[word] ?? 0) > (popularity[bestWord] ?? 0)) {
                bestWord = word
                bestEdits = edits
            }
        }
        if bestEdits == 1 { total += 43 + min(30, (popularity[bestWord] ?? 0) * 2) }
        else if bestEdits == 2 && term.count >= 6 { total += 20 + min(20, popularity[bestWord] ?? 0) }
        else { return nil }
    }
    if name.hasPrefix(query) { total += 40 }
    if name.split(separator: " ").first == Substring(query) { total += 35 }
    return total
}

private final class SearchApp: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let root = URL(fileURLWithPath: "__DOSSIER_ROOT__", isDirectory: true)
    private var dossiers: [Dossier] = []
    private var popularity: [String: Int] = [:]
    private var matches: [Dossier] = []
    private var ready = false
    private var refreshedOnce = false
    private var window: NSWindow!
    private var search: NSSearchField!
    private var table: NSTableView!
    private var status: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 490), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Buscar dossier TSI"
        window.center()
        window.delegate = self
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        search = NSSearchField(frame: NSRect(x: 22, y: 429, width: 546, height: 34))
        search.placeholderString = "Número o nombre del chantier (por ejemplo, Marly)"
        search.delegate = self
        search.autoresizingMask = [.width, .minYMargin]
        content.addSubview(search)

        let refresh = NSButton(frame: NSRect(x: 580, y: 429, width: 118, height: 34))
        refresh.title = "Actualizar lista"
        refresh.bezelStyle = .rounded
        refresh.target = self
        refresh.action = #selector(chooseFolder)
        refresh.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(refresh)

        status = NSTextField(labelWithString: "Preparando la lista de dossiers…")
        status.frame = NSRect(x: 22, y: 401, width: 676, height: 20)
        status.textColor = .secondaryLabelColor
        status.autoresizingMask = [.width, .minYMargin]
        content.addSubview(status)

        table = NSTableView(frame: .zero)
        table.headerView = nil
        table.rowHeight = 38
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dossier"))
        column.width = 675
        table.addTableColumn(column)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 20, width: 676, height: 370))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.indexDossiers() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil, search != nil else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    private func indexDossiers() {
        let folderPattern = try! NSRegularExpression(pattern: "^[0-9]{4,5}(?:\\D|$)")
        var found: [Dossier] = []
        let cache = URL(fileURLWithPath: "__HOME__/Library/Caches/ch.tsi.dossier-search.paths")
        if let data = try? Data(contentsOf: cache) {
            for path in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let url = URL(fileURLWithPath: String(path), isDirectory: true)
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard folderPattern.firstMatch(in: name, range: range) != nil else { continue }
                let relative = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path + "/", with: "")
                let text = normalize(name + " " + relative)
                found.append(Dossier(url: url, name: name, context: relative, normalized: text, words: text.split(separator: " ").map(String.init)))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dossiers = found
            self.popularity = found.flatMap(\.words).reduce(into: [String: Int]()) { counts, word in counts[word, default: 0] += 1 }
            self.ready = true
            self.updateResults()
            if !self.refreshedOnce {
                self.refreshedOnce = true
                self.refreshFromDisk(root: self.root, quiet: true)
            }
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Selecciona la carpeta Client de TSI-new para actualizar los dossiers."
        panel.prompt = "Elegir Client"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let selected = panel.url else { return }
            self?.refreshFromDisk(root: selected, quiet: false)
        }
    }

    private func refreshFromDisk(root selected: URL, quiet: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let manager = FileManager.default
            let pattern = try! NSRegularExpression(pattern: "^[0-9]{4,5}(?:\\D|$)")
            var paths: [String] = []
            func scan(_ folder: URL, depth: Int) {
                guard depth <= 6, let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
                for name in names where !name.hasPrefix(".") {
                    let child = folder.appendingPathComponent(name, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    let range = NSRange(name.startIndex..<name.endIndex, in: name)
                    if pattern.firstMatch(in: name, range: range) != nil { paths.append(child.path) }
                    else { scan(child, depth: depth + 1) }
                }
            }
            let granted = selected.startAccessingSecurityScopedResource()
            scan(selected, depth: 0)
            if granted { selected.stopAccessingSecurityScopedResource() }
            guard !paths.isEmpty else {
                if !quiet { DispatchQueue.main.async { self.status.stringValue = "No pude leer dossiers en esa carpeta." } }
                return
            }
            let cache = URL(fileURLWithPath: "__HOME__/Library/Caches/ch.tsi.dossier-search.paths")
            try? (paths.joined(separator: "\n") + "\n").write(to: cache, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { self.indexDossiers() }
        }
    }

    func controlTextDidChange(_ obj: Notification) { updateResults() }

    private func updateResults() {
        let query = normalize(search.stringValue)
        if !ready { status.stringValue = "Preparando la lista de dossiers…"; return }
        if query.isEmpty {
            matches = []
            status.stringValue = "Escribe un número, un nombre o una localidad. Pulsa ↵ para abrir el dossier seleccionado."
        } else {
            let exactNumbers = query.count >= 4 && query.allSatisfy(\.isNumber)
                ? dossiers.filter { $0.name.split(separator: " ").first == Substring(query) } : []
            if !exactNumbers.isEmpty {
                matches = exactNumbers
            } else {
                matches = dossiers.compactMap { dossier -> (Dossier, Int)? in
                    guard let rank = score(query, in: dossier, popularity: popularity) else { return nil }
                    return (dossier, rank)
                }.sorted { $0.1 == $1.1 ? $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending : $0.1 > $1.1 }
                    .prefix(40).map(\.0)
            }
            status.stringValue = matches.isEmpty ? "No encontré dossiers similares." : "\(matches.count) sugerencia(s) · usa ↑ ↓ y ↵, o haz doble clic"
        }
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if window.firstResponder !== search.currentEditor() {
            window.makeFirstResponder(search)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.lineBreakMode = .byTruncatingMiddle
        cell.font = NSFont.systemFont(ofSize: 14)
        let item = matches[row]
        cell.stringValue = "\(item.name)   ·   \(item.context)"
        return cell
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) { table.selectRowIndexes(IndexSet(integer: min(table.selectedRow + 1, matches.count - 1)), byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { table.selectRowIndexes(IndexSet(integer: max(table.selectedRow - 1, 0)), byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { NSApplication.shared.terminate(nil); return true }
        return false
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard matches.indices.contains(row) else { return }
        NSWorkspace.shared.open(matches[row].url)
        NSApplication.shared.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
private let delegate = SearchApp()
app.delegate = delegate
app.run()
