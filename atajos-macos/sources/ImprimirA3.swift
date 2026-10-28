import AppKit
import PDFKit
import ImageIO

// Finder service: validate the complete selection, prepare one vector A3 job,
// then submit it once. Originals and global printer settings remain unchanged.
let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/ImprimirA3", isDirectory: true)
let fm = FileManager.default
let a3 = CGSize(width: 297 * 72 / 25.4, height: 420 * 72 / 25.4)
let margin: CGFloat = 18 // 6.35 mm; no cropping or distortion.

// Record starts and failures too: a missing shortcut and a rejected document
// must be distinguishable without submitting another print job.
func recordInvocation(_ status: String, message: String? = nil) {
    var record: [String: Any] = [
        "date": ISO8601DateFormatter().string(from: Date()),
        "status": status,
        "arguments": Array(CommandLine.arguments.dropFirst()),
        "pid": ProcessInfo.processInfo.processIdentifier
    ]
    if let message { record["message"] = message }
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: root.appendingPathComponent("ultima-invocacion.json"), options: .atomic)
    }
}

struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw Failure(output.isEmpty ? "No se pudo ejecutar \(executable)." : output) }
    return output
}

func alert(_ title: String, _ message: String, error: Bool = false) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let dialog = NSAlert()
    dialog.messageText = title
    dialog.informativeText = message
    dialog.alertStyle = error ? .warning : .informational
    dialog.addButton(withTitle: "Aceptar")
    app.activate(ignoringOtherApps: true)
    dialog.runModal()
}

enum Source {
    case pdf(URL, PDFDocument)
    case image(URL, CGImageSource)
}

func pageRect(_ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(origin: .zero, size: width > height ? CGSize(width: a3.height, height: a3.width) : a3)
}

func fitted(_ size: CGSize, in page: CGRect) -> CGRect {
    let area = page.insetBy(dx: margin, dy: margin)
    let scale = min(area.width / size.width, area.height / size.height)
    let width = size.width * scale
    let height = size.height * scale
    return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let cliDryRun = args.first == "--dry-run"
    let names = cliDryRun ? Array(args.dropFirst()) : args
    guard !names.isEmpty else { throw Failure("Selecciona uno o varios PDF o imágenes en Finder y pulsa ⌘*. No se ha impreso nada.") }
    let configData = try Data(contentsOf: root.appendingPathComponent("config.plist"))
    let config = try PropertyListSerialization.propertyList(from: configData, format: nil) as? [String: Any] ?? [:]
    let testing = cliDryRun || (config["TestMode"] as? Bool ?? false)
    let printer = config["Printer"] as? String ?? "__A3_PRINTER__"
    var seen = Set<String>()
    var sources: [Source] = []
    var inputs: [String] = []
    let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp"]
    for name in names {
        let url = URL(fileURLWithPath: name).standardizedFileURL
        guard seen.insert(url.path).inserted else { continue }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw Failure("No es un archivo accesible: \(url.lastPathComponent). No se ha enviado ningún trabajo.")
        }
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw Failure("PDF protegido o no válido: \(url.lastPathComponent). No se ha enviado ningún trabajo.")
            }
            sources.append(.pdf(url, pdf))
        } else if imageExtensions.contains(url.pathExtension.lowercased()), let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0 {
            sources.append(.image(url, image))
        } else {
            throw Failure("Formato no admitido: \(url.lastPathComponent). Esta acción admite PDF e imágenes. Exporta Word, Excel, Numbers y otros documentos a PDF primero. No se ha impreso nada.")
        }
        inputs.append(url.path)
    }
    let lock = root.appendingPathComponent("en-curso.lock", isDirectory: true)
    do { try fm.createDirectory(at: lock, withIntermediateDirectories: false) }
    catch { throw Failure("Ya hay una selección preparándose. Espera a que termine antes de pulsar el atajo otra vez.") }
    defer { try? fm.removeItem(at: lock) }
    let work = fm.temporaryDirectory.appendingPathComponent("ImprimirA3-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: false)
    var preserveTestOutput = false
    defer { if !preserveTestOutput { try? fm.removeItem(at: work) } }
    let output = work.appendingPathComponent("Seleccion-A3.pdf")
    guard let consumer = CGDataConsumer(url: output as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw Failure("No se pudo preparar el trabajo A3.")
    }
    var pages = 0
    for source in sources {
        switch source {
        case .pdf(let url, let pdf):
            for number in 0..<pdf.pageCount {
                guard let page = pdf.page(at: number) else { throw Failure("No se puede leer una página de \(url.lastPathComponent).") }
                let box = page.bounds(for: .cropBox)
                guard box.width > 0, box.height > 0 else { throw Failure("Página sin dimensiones válidas en \(url.lastPathComponent).") }
                let sideways = abs(page.rotation) % 180 == 90
                let size = sideways ? CGSize(width: box.height, height: box.width) : box.size
                var paper = pageRect(size.width, size.height)
                let data = NSData(bytes: &paper, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                context.saveGState()
                let destination = fitted(size, in: paper)
                context.translateBy(x: destination.minX, y: destination.minY)
                context.scaleBy(x: destination.width / size.width, y: destination.height / size.height)
                // PDFKit accounts for the source rotation and draws the visible
                // annotations (pipes, symbols, stamps, form appearances) too.
                page.displaysAnnotations = true
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
                context.endPDFPage()
                pages += 1
            }
        case .image(let url, let imageSource):
            // TIFFs can contain several pages; GIFs are treated as one still image.
            let count = ["tif", "tiff"].contains(url.pathExtension.lowercased()) ? CGImageSourceGetCount(imageSource) : 1
            for index in 0..<count {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 16000]
                guard let bitmap = CGImageSourceCreateThumbnailAtIndex(imageSource, index, options as CFDictionary) else {
                    throw Failure("No se puede leer la imagen \(url.lastPathComponent).")
                }
                let size = CGSize(width: bitmap.width, height: bitmap.height)
                var paper = pageRect(size.width, size.height)
                let data = NSData(bytes: &paper, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(bitmap, in: fitted(size, in: paper))
                context.endPDFPage()
                pages += 1
            }
        }
    }
    context.closePDF()
    guard let check = PDFDocument(url: output), check.pageCount == pages, pages > 0 else { throw Failure("La validación del trabajo A3 ha fallado. No se ha impreso nada.") }
    for index in 0..<check.pageCount {
        let box = check.page(at: index)!.bounds(for: .mediaBox)
        guard abs(min(box.width, box.height) - a3.width) < 0.1, abs(max(box.width, box.height) - a3.height) < 0.1 else { throw Failure("Una página no quedó en A3. No se ha impreso nada.") }
    }
    let options = ["-d", printer, "-n", "1", "-o", "media=A3", "-o", "sides=one-sided", "-o", "Duplex=None", "-o", "number-up=1", "-o", "fit-to-page", "-o", "job-sheets=none", "-t", "Selección A3 - \(inputs.count) archivos - \(pages) páginas", "--", output.path]
    var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "testMode": testing, "files": inputs, "fileCount": inputs.count, "pageCount": pages, "preparedPDF": output.path, "printer": printer, "lpArguments": options, "paper": "A3 297 x 420 mm", "sides": "one-sided"]
    if testing {
        preserveTestOutput = true
        report["result"] = "PRUEBA: ningún trabajo enviado a la impresora"
    } else {
        _ = try run("/usr/bin/lpstat", ["-p", printer])
        let supported = try run("/usr/bin/lpoptions", ["-p", printer, "-l"])
        guard supported.contains(" A3") else { throw Failure("La impresora configurada no anuncia papel A3. No se ha impreso nada.") }
        report["result"] = try run("/usr/bin/lp", options)
    }
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: root.appendingPathComponent("ultima-ejecucion.json"), options: .atomic)
    if testing {
        print(String(data: json, encoding: .utf8)!)
        if !cliDryRun { alert("Prueba de Imprimir en A3 correcta", "\(inputs.count) archivos · \(pages) páginas A3\n\nBrother MFC-J6935DW · Una cara · Sin recortar\n\nNo se ha enviado nada a la impresora.") }
    }
}

recordInvocation("started")
do {
    try main()
    recordInvocation("completed")
}
catch {
    recordInvocation("failed", message: error.localizedDescription)
    fputs("\(error.localizedDescription)\n", stderr)
    if !CommandLine.arguments.contains("--dry-run") { alert("No se pudo imprimir en A3", error.localizedDescription, error: true) }
    exit(1)
}
