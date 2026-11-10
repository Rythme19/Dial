import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct DialError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Kind: CaseIterable { case pdf, image, video, audio, general }

func kind(of url: URL) -> Kind? {
    switch url.pathExtension.lowercased() {
    case "pdf": return .pdf
    case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp": return .image
    case "mp4", "mov", "m4v", "mkv", "avi", "webm": return .video
    case "mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "ogg", "caf": return .audio
    default: return nil
    }
}

struct Action {
    let title: String
    let symbol: String
    let detail: String
    var minFiles = 1
    /// Kinds this action takes from a mixed selection; nil means only its category's kind.
    var accepts: Set<Kind>? = nil
    let run: ([URL]) throws -> [URL]
}

struct Category {
    let kind: Kind
    let title: String
    let symbol: String
    let actions: [Action]
}

/// The part of the selection an action works on. General takes everything; others take their kinds only,
/// so with report.pdf + clip.mp4 selected, PDF actions see the PDF and Video actions see the MP4.
func inputs(_ action: Action, in category: Category, from selection: [URL]) -> [URL] {
    if category.kind == .general { return selection }
    let ok = action.accepts ?? [category.kind]
    return selection.filter { kind(of: $0).map(ok.contains) ?? false }
}

func usable(_ action: Action, in category: Category, with selection: [URL]) -> Bool {
    let files = inputs(action, in: category, from: selection)
    return files.count >= action.minFiles && (category.kind == .general || files.contains { kind(of: $0) == category.kind })
}

func usableCategories(for selection: [URL]) -> [Category] {
    catalog.filter { c in c.actions.contains { usable($0, in: c, with: selection) } }
}

func usableActions(_ category: Category, for selection: [URL]) -> [Action] {
    category.actions.filter { usable($0, in: category, with: selection) }
}

// MARK: - Files

/// "name.ext" → "name 2.ext" until free. Dial never overwrites anything.
func unique(_ url: URL) -> URL {
    // attributesOfItem doesn't follow symlinks, so a dangling link counts as taken and is never written through.
    func taken(_ u: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: u.path)) != nil }
    guard taken(url) else { return url }
    let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    var n = 2
    while true {
        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        let candidate = dir.appendingPathComponent(name)
        if !taken(candidate) { return candidate }
        n += 1
    }
}

/// Output next to the source: report.pdf + "-small" → report-small.pdf
func sibling(_ src: URL, _ suffix: String = "", ext: String? = nil) -> URL {
    let name = src.deletingPathExtension().lastPathComponent + suffix + "." + (ext ?? src.pathExtension)
    return unique(src.deletingLastPathComponent().appendingPathComponent(name))
}

// MARK: - External tools

func tool(_ name: String) throws -> String {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    let formula = ["gs": "ghostscript", "cwebp": "webp"][name] ?? name
    throw DialError("\(name) isn't installed. Run: brew install \(formula)")
}

func sh(_ name: String, _ args: [String], cwd: URL? = nil) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: try tool(name))
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()  // drain before wait, or a chatty tool deadlocks
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw DialError("\(name) failed: " + String((String(data: data, encoding: .utf8) ?? "").suffix(300)))
    }
}

func ffmpeg(_ src: URL, _ args: [String], _ dst: URL) throws -> URL {
    // Local files only: a playlist disguised as a video can't make ffmpeg reach the network.
    try sh("ffmpeg", ["-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", "-i", src.path] + args + [dst.path])
    return dst
}

// MARK: - Images

/// Full-size decode with EXIF orientation applied, so re-encoding never rotates a photo.
func cgImage(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
        throw DialError("Can't read \(url.lastPathComponent)")
    }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h),
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        throw DialError("Can't decode \(url.lastPathComponent)")
    }
    return img
}

/// JPEG has no alpha: put transparent pixels on white instead of black.
func flattened(_ img: CGImage) -> CGImage {
    guard img.alphaInfo != .none, img.alphaInfo != .noneSkipLast, img.alphaInfo != .noneSkipFirst,
          let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return img }
    let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.setFillColor(.white)
    ctx.fill(rect)
    ctx.draw(img, in: rect)
    return ctx.makeImage() ?? img
}

/// Writes pixels only: EXIF, GPS and camera data are not carried over.
@discardableResult
func write(_ img: CGImage, to url: URL, as type: UTType, quality: Double = 0.9) throws -> URL {
    let pixels = type == .jpeg ? flattened(img) : img
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw DialError("Can't write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dst, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dst) else { throw DialError("Can't write \(url.lastPathComponent)") }
    return url
}

func convert(_ src: URL, to type: UTType, ext: String, suffix: String = "", maxPixel: Int? = nil, quality: Double = 0.9) throws -> URL {
    try write(cgImage(src, maxPixel: maxPixel), to: sibling(src, suffix, ext: ext), as: type, quality: quality)
}

/// Keeps the source format when ImageIO can write it, PNG otherwise (GIF, WebP sources).
func sameFormat(_ src: URL) -> (UTType, String) {
    switch src.pathExtension.lowercased() {
    case "jpg", "jpeg": return (.jpeg, "jpg")
    case "heic", "heif": return (.heic, "heic")
    case "tif", "tiff": return (.tiff, "tiff")
    default: return (.png, "png")
    }
}

// MARK: - PDF

func pdf(_ url: URL) throws -> PDFDocument {
    guard let doc = PDFDocument(url: url) else { throw DialError("Can't open \(url.lastPathComponent)") }
    if doc.isLocked { throw DialError("\(url.lastPathComponent) is password-protected") }
    return doc
}

func imagePage(_ url: URL) throws -> PDFPage {
    guard let img = NSImage(contentsOf: url), let page = PDFPage(image: img) else {
        throw DialError("Can't read \(url.lastPathComponent)")
    }
    return page
}

func save(_ doc: PDFDocument, _ url: URL) throws -> URL {
    guard doc.write(to: url) else { throw DialError("Can't write \(url.lastPathComponent)") }
    return url
}

func pagesToImages(_ src: URL, _ type: UTType, _ ext: String) throws -> [URL] {
    let doc = try pdf(src)
    return try (0..<doc.pageCount).map { i in
        let page = doc.page(at: i)!
        let box = page.bounds(for: .mediaBox)
        let size = NSSize(width: box.width * 2, height: box.height * 2)  // 144 dpi
        guard let img = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DialError("Can't render page \(i + 1)")
        }
        return try write(img, to: sibling(src, doc.pageCount > 1 ? "-\(i + 1)" : "", ext: ext), as: type)
    }
}

// MARK: - Catalog

let today: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}()

let catalog: [Category] = [
    Category(kind: .pdf, title: "PDF", symbol: "doc.text", actions: [
        Action(title: "Merge", symbol: "arrow.triangle.merge", detail: "One PDF from the selection, images become pages",
               minFiles: 2, accepts: [.pdf, .image]) { files in
            let out = PDFDocument()
            for url in files {
                if kind(of: url) == .image {
                    out.insert(try imagePage(url), at: out.pageCount)
                } else {
                    let doc = try pdf(url)
                    for i in 0..<doc.pageCount { out.insert(doc.page(at: i)!.copy() as! PDFPage, at: out.pageCount) }
                }
            }
            let first = files.first { kind(of: $0) == .pdf } ?? files[0]
            return [try save(out, sibling(first, "-merged", ext: "pdf"))]
        },
        Action(title: "Split", symbol: "scissors", detail: "One PDF per page, in a new folder") { files in
            try files.map { url in
                let doc = try pdf(url)
                let base = url.deletingPathExtension().lastPathComponent
                let folder = unique(url.deletingLastPathComponent().appendingPathComponent(base + " pages"))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                for i in 0..<doc.pageCount {
                    let one = PDFDocument()
                    one.insert(doc.page(at: i)!.copy() as! PDFPage, at: 0)
                    _ = try save(one, folder.appendingPathComponent(base + "-\(i + 1).pdf"))
                }
                return folder
            }
        },
        Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller file, same layout and text") { files in
            try files.map { url in
                let dst = sibling(url, "-small")
                try sh("gs", ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6", "-dPDFSETTINGS=/ebook",
                              "-dSAFER", "-dNOPAUSE", "-dQUIET", "-dBATCH",
                              // gs reads "%" in the output name as a page-number pattern.
                              "-sOutputFile=" + dst.path.replacingOccurrences(of: "%", with: "%%"), url.path])
                let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                if size(dst) >= size(url) {
                    try? FileManager.default.removeItem(at: dst)
                    throw DialError("\(url.lastPathComponent) is already as small as it gets")
                }
                return dst
            }
        },
        Action(title: "Rotate", symbol: "rotate.right", detail: "Turn every page 90° clockwise") { files in
            try files.map { url in
                let doc = try pdf(url)
                for i in 0..<doc.pageCount { doc.page(at: i)!.rotation += 90 }
                return try save(doc, sibling(url, "-rotated"))
            }
        },
        Action(title: "To JPG", symbol: "j.square", detail: "Every page as a JPG image") { files in
            try files.flatMap { try pagesToImages($0, .jpeg, "jpg") }
        },
        Action(title: "To PNG", symbol: "p.square", detail: "Every page as a PNG image") { files in
            try files.flatMap { try pagesToImages($0, .png, "png") }
        },
        Action(title: "Text", symbol: "text.alignleft", detail: "Extract the text to a .txt file") { files in
            try files.map { url in
                let dst = sibling(url, ext: "txt")
                try (try pdf(url).string ?? "").write(to: dst, atomically: true, encoding: .utf8)
                return dst
            }
        },
    ]),
    Category(kind: .image, title: "Image", symbol: "photo", actions: [
        Action(title: "To JPG", symbol: "j.square", detail: "Convert to JPG") { try $0.map { try convert($0, to: .jpeg, ext: "jpg") } },
        Action(title: "To PNG", symbol: "p.square", detail: "Convert to PNG") { try $0.map { try convert($0, to: .png, ext: "png") } },
        Action(title: "To PDF", symbol: "doc.richtext", detail: "All selected images in one PDF") { files in
            let doc = PDFDocument()
            for url in files { doc.insert(try imagePage(url), at: doc.pageCount) }
            return [try save(doc, sibling(files[0], files.count > 1 ? "-combined" : "", ext: "pdf"))]
        },
        Action(title: "To WebP", symbol: "w.square", detail: "Convert to WebP for the web") { files in
            try files.map { url in
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try write(cgImage(url), to: tmp, as: .png)
                let dst = sibling(url, ext: "webp")
                try sh("cwebp", ["-quiet", "-q", "85", tmp.path, "-o", dst.path])
                return dst
            }
        },
        Action(title: "Half size", symbol: "minus.magnifyingglass", detail: "Half the width and height") { files in
            try files.map { url in
                let full = try cgImage(url)
                let (type, ext) = sameFormat(url)
                return try convert(url, to: type, ext: ext, suffix: "-half", maxPixel: max(full.width, full.height) / 2)
            }
        },
        Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller JPG, quality 70%") { files in
            try files.map { try convert($0, to: .jpeg, ext: "jpg", suffix: "-small", quality: 0.7) }
        },
        Action(title: "Strip info", symbol: "location.slash", detail: "Remove location and camera data") { files in
            try files.map { url in
                let (type, ext) = sameFormat(url)
                return try convert(url, to: type, ext: ext, suffix: "-clean", quality: 0.95)
            }
        },
    ]),
    Category(kind: .video, title: "Video", symbol: "film", actions: [
        Action(title: "To MP4", symbol: "film", detail: "H.264 MP4 that plays everywhere") { files in
            try files.map { try ffmpeg($0, ["-c:v", "libx264", "-crf", "22", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                                             "-c:a", "aac", "-movflags", "+faststart"], sibling($0, ext: "mp4")) }
        },
        Action(title: "To GIF", symbol: "g.square", detail: "Animated GIF, 480 px wide") { files in
            try files.map { try ffmpeg($0, ["-vf", "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"],
                                       sibling($0, ext: "gif")) }
        },
        Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller MP4, up to 1280 px wide") { files in
            try files.map { try ffmpeg($0, ["-vf", "scale='min(1280,iw)':-2", "-c:v", "libx264", "-crf", "28", "-preset", "veryfast",
                                             "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"], sibling($0, "-small", ext: "mp4")) }
        },
        Action(title: "Audio only", symbol: "waveform", detail: "Keep just the sound, as M4A") { files in
            try files.map { url in
                do {
                    return try ffmpeg(url, ["-vn", "-c:a", "aac", "-b:a", "192k"], sibling(url, ext: "m4a"))
                } catch let error as DialError where error.errorDescription?.contains("does not contain any stream") == true {
                    throw DialError("\(url.lastPathComponent) has no sound to extract")
                }
            }
        },
    ]),
    Category(kind: .audio, title: "Audio", symbol: "waveform", actions: [
        Action(title: "To MP3", symbol: "music.note", detail: "MP3, high quality") { files in
            try files.map { try ffmpeg($0, ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], sibling($0, ext: "mp3")) }
        },
        Action(title: "To M4A", symbol: "music.note.list", detail: "AAC in M4A, 192 kbps") { files in
            try files.map { try ffmpeg($0, ["-vn", "-c:a", "aac", "-b:a", "192k"], sibling($0, ext: "m4a")) }
        },
        Action(title: "To WAV", symbol: "waveform.path", detail: "Uncompressed WAV") { files in
            try files.map { try ffmpeg($0, ["-vn", "-c:a", "pcm_s16le"], sibling($0, ext: "wav")) }
        },
    ]),
    Category(kind: .general, title: "General", symbol: "bolt", actions: [
        Action(title: "Zip", symbol: "doc.zipper", detail: "Compress into a .zip archive") { files in
            if files.count == 1 {
                let dst = sibling(files[0], ext: "zip")
                try sh("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", files[0].path, dst.path])
                return [dst]
            }
            let dir = files[0].deletingLastPathComponent()
            guard files.allSatisfy({ $0.deletingLastPathComponent() == dir }) else {
                throw DialError("Zip several files from one folder at a time.")
            }
            let dst = unique(dir.appendingPathComponent("Archive.zip"))
            // "./" so a name like "-T" is a file to zip, not an option (zip drops the "./" when storing).
            // -y stores symlinks as links, so a link inside a folder can't pull in files from elsewhere.
            try sh("zip", ["-r", "-q", "-X", "-y", dst.path] + files.map { "./" + $0.lastPathComponent }, cwd: dir)
            return [dst]
        },
        Action(title: "Copy path", symbol: "doc.on.clipboard", detail: "Copy the full path to the clipboard") { files in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            return []
        },
        Action(title: "New folder", symbol: "folder.badge.plus", detail: "Move the selection into a new folder") { files in
            let folder = unique(files[0].deletingLastPathComponent().appendingPathComponent("New Folder With Items"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for url in files { try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
            return [folder]
        },
        Action(title: "Add date", symbol: "calendar", detail: "Rename with today's date") { files in
            try files.map { url in
                let ext = url.pathExtension
                let dst = unique(url.deletingLastPathComponent().appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + " " + today + (ext.isEmpty ? "" : "." + ext)))
                try FileManager.default.moveItem(at: url, to: dst)
                return dst
            }
        },
    ]),
]
