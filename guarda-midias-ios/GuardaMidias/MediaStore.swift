import CryptoKit
import Foundation
import Photos
import SwiftUI

struct MediaEntry: Identifiable {
    enum Source { case photo(PHAsset), file(URL) }
    let id: String
    let name: String
    let date: Date
    let source: Source
}

struct UploadReceipt: Decodable {
    let name: String
    let folder: String
    let size: Int64
    let sha256: String
    let duplicate: Bool
}

struct CableManifest: Codable {
    let id: String
    let assetID: String
    let name: String
    let fileName: String
    let size: Int64
    let sha256: String
}

struct CableReceipt: Decodable {
    let id: String
    let size: Int64
    let sha256: String
}

struct CableProgress: Decodable {
    let bytes: Int64
    let total: Int64
    let speed: Double
}

struct CableConnection: Decodable {
    let serverURL: String
    let accessCode: String
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

@MainActor
final class MediaStore: ObservableObject {
    @Published var entries: [MediaEntry] = []
    @Published var selected: Set<String> = []
    @Published var status = "Escolha o período e toque em Buscar fotos."
    @Published var isBusy = false
    @Published var backedUp: Set<String> = []
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://100.113.163.32:8765"
    @Published var accessCode = UserDefaults.standard.string(forKey: "accessCode") ?? ""
    @Published var minimumMB = 0
    @Published var hasSearched = false
    @Published var limitedPhotoAccess = false
    @Published var accessibleLibraryCount = 0
    @Published var photoCount = 0
    @Published var videoCount = 0
    @Published var importedFileCount = 0
    @Published var hasTransferAttempt = false
    @Published var transferPhase = ""
    @Published var transferProgress = 0.0
    @Published var transferSpeed = 0.0
    @Published var transferSecondsRemaining: TimeInterval? = nil
    @Published var transferFileIndex = 0
    @Published var transferFileCount = 0
    @Published var transferCompletedCount = 0
    @Published var totalSecondsRemaining: TimeInterval? = nil
    @Published var cableQueueCount = 0
    @Published var cableVerifiedIDs: Set<String> = []
    @Published var pauseRequested = false
    @Published var stopRequested = false
    @Published var switchToInternetRequested = false
    private var transferStartedAt = Date()
    private var totalStartedAt = Date()
    private var cableMonitorRunning = false
    private var cableVerifiedHashes: [String: String] = [:]

    private var cableFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CableQueue", isDirectory: true)
    }

    func togglePause() {
        pauseRequested.toggle()
        status = pauseRequested ? "Pausando após o arquivo atual…" : "Continuando transferência…"
    }

    func requestStop() {
        stopRequested = true
        pauseRequested = false
        status = "Parando após o arquivo atual. Os arquivos já copiados serão mantidos."
    }

    func requestSwitchToInternet() {
        switchToInternetRequested = true
        pauseRequested = false
        status = "Mudando para rede após o arquivo atual…"
    }

    private func continueAtFileBoundary() async -> Bool {
        while pauseRequested && !stopRequested && !switchToInternetRequested {
            transferPhase = "Pausado após o arquivo anterior"
            try? await Task.sleep(for: .milliseconds(300))
        }
        return !stopRequested && !switchToInternetRequested
    }

    private func queuedCableAssetIDs() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: cableFolder,
            includingPropertiesForKeys: nil)) ?? []
        var ids: Set<String> = []
        for file in files where file.pathExtension == "json"
                && !file.lastPathComponent.hasSuffix(".receipt.json")
                && !file.lastPathComponent.hasSuffix(".progress.json") {
            if let data = try? Data(contentsOf: file),
               let manifest = try? JSONDecoder().decode(CableManifest.self, from: data) {
                ids.insert(manifest.assetID)
            }
        }
        return ids
    }

    func saveConnection() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(accessCode, forKey: "accessCode")
    }

    @discardableResult
    func loadConnectionFromCable(force: Bool = false) -> Bool {
        if !force && !accessCode.isEmpty { return false }
        let configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuardaMidiasConnection.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(CableConnection.self, from: data),
              let url = URL(string: config.serverURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              config.accessCode.count == 10, config.accessCode.allSatisfy(\.isNumber) else { return false }
        serverURL = config.serverURL
        accessCode = config.accessCode
        saveConnection()
        return true
    }

    func clearSearch() {
        entries = []
        selected = []
        hasSearched = false
        photoCount = 0
        videoCount = 0
        importedFileCount = 0
        status = "Período alterado. Toque em Buscar fotos e vídeos novamente."
    }

    func testConnection() async {
        loadConnectionFromCable()
        guard let base = URL(string: serverURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              !accessCode.isEmpty else {
            status = "Informe o endereço do computador e o código de acesso."
            return
        }
        saveConnection()
        isBusy = true
        status = "Testando conexão com o computador…"
        defer { isBusy = false }
        do {
            var request = URLRequest(url: base.appendingPathComponent("api/files"))
            request.setValue(accessCode, forHTTPHeaderField: "x-media-token")
            request.timeoutInterval = 15
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = "O computador respondeu de forma inesperada."
                return
            }
            switch http.statusCode {
            case 200: status = "Conectado ao computador. Pode enviar uma foto de teste."
            case 401: status = "Código de acesso incorreto. Confira o atalho no PC."
            default: status = "O computador respondeu com erro \(http.statusCode)."
            }
        } catch {
            status = "Não conectou: \(error.localizedDescription). Confira Tailscale e endereço."
        }
    }

    func find(from start: Date, through end: Date) async {
        isBusy = true
        status = "Procurando fotos no período…"
        defer { isBusy = false }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        limitedPhotoAccess = auth == .limited
        var found: [MediaEntry] = []
        var images = 0
        var videos = 0
        var imported = 0
        if auth == .authorized || auth == .limited {
            accessibleLibraryCount = PHAsset.fetchAssets(with: nil).count
            let options = PHFetchOptions()
            let calendar = Calendar.current
            let first = calendar.startOfDay(for: start)
            let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", first as NSDate, afterLast as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)
            result.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                if asset.mediaType == .image { images += 1 } else { videos += 1 }
                let resources = PHAssetResource.assetResources(for: asset)
                let resource = resources.first(where: { $0.type == .photo || $0.type == .video })
                    ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
                found.append(MediaEntry(id: asset.localIdentifier,
                                        name: resource?.originalFilename ?? "Mídia",
                                        date: asset.creationDate ?? first,
                                        source: .photo(asset)))
            }
        } else {
            accessibleLibraryCount = 0
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "tif", "tiff", "mp4", "mov", "m4v", "avi"]
            let calendar = Calendar.current
            for file in files where extensions.contains(file.pathExtension.lowercased()) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date >= calendar.startOfDay(for: start), date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end) {
                    found.append(MediaEntry(id: file.path, name: file.lastPathComponent, date: date, source: .file(file)))
                    imported += 1
                }
            }
        }
        entries = found.sorted { $0.date > $1.date }
        photoCount = images
        videoCount = videos
        importedFileCount = imported
        hasSearched = true
        selected = []
        status = "Busca concluída. Selecione as mídias desejadas antes de guardar."
    }

    func sendSelected(deleteAfterBackup: Bool = false, skippingQueued: Bool = false) async {
        pauseRequested = false
        stopRequested = false
        switchToInternetRequested = false
        loadConnectionFromCable()
        hasTransferAttempt = true
        transferProgress = 0
        transferSpeed = 0
        transferSecondsRemaining = nil
        totalSecondsRemaining = nil
        transferCompletedCount = 0
        totalStartedAt = Date()
        transferPhase = "Conferindo conexão…"
        guard let base = URL(string: serverURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              !accessCode.isEmpty else {
            status = "Confira o endereço do computador e o código de acesso."
            transferPhase = "Falta endereço ou código de acesso"
            return
        }
        saveConnection()
        isBusy = true
        defer { isBusy = false }
        let alreadyQueued: Set<String> = skippingQueued ? queuedCableAssetIDs() : []
        let chosen = entries.filter {
            selected.contains($0.id) && (deleteAfterBackup || !backedUp.contains($0.id))
                && !alreadyQueued.contains($0.id)
        }
        transferFileCount = chosen.count
        var success = 0
        var skipped = 0
        var failed = 0
        var retainedComplex = 0
        var verifiedForRemoval: [MediaEntry] = []
        for (index, entry) in chosen.enumerated() {
            guard await continueAtFileBoundary() else { break }
            transferFileIndex = index + 1
            transferProgress = 0
            transferSpeed = 0
            transferSecondsRemaining = nil
            transferPhase = "Preparando original: \(entry.name)"
            status = "Verificando \(index + 1) de \(chosen.count): \(entry.name)"
            do {
                let (file, temporary) = try await materialize(entry)
                defer { if temporary { try? FileManager.default.removeItem(at: file) } }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size < Int64(minimumMB) * 1_000_000 {
                    skipped += 1
                    transferPhase = "Ignorado: menor que \(minimumMB) MB"
                    updateTotalEstimate(completed: index + 1, total: chosen.count)
                    continue
                }
                let localHash = try sha256(file)
                var components = URLComponents(url: base.appendingPathComponent("api/upload"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "name", value: entry.name)]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "PUT"
                request.setValue(accessCode, forHTTPHeaderField: "x-media-token")
                request.timeoutInterval = 3600
                transferStartedAt = Date()
                transferPhase = "Enviando: \(entry.name)"
                let delegate = UploadProgressDelegate { [weak self] sent, expected in
                    Task { @MainActor [weak self] in
                        self?.updateUploadProgress(sent: sent, expected: expected > 0 ? expected : size)
                    }
                }
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate)
                transferProgress = 1
                transferPhase = "Conferindo cópia no computador…"
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "GuardaMidias", code: 1, userInfo: [NSLocalizedDescriptionKey: "Computador recusou o arquivo"])
                }
                let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
                guard receipt.sha256 == localHash, receipt.size == size else {
                    throw NSError(domain: "GuardaMidias", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cópia não conferiu com o original"])
                }
                backedUp.insert(entry.id)
                success += 1
                if deleteAfterBackup {
                    try await verifySavedCopy(receipt, at: base)
                    switch entry.source {
                    case .file:
                        verifiedForRemoval.append(entry)
                    case .photo(let asset):
                        // A single uploaded resource cannot preserve all parts of a Live Photo or edited asset.
                        let resources = PHAssetResource.assetResources(for: asset)
                        if resources.count == 1 && !asset.mediaSubtypes.contains(.photoLive) {
                            verifiedForRemoval.append(entry)
                        } else {
                            retainedComplex += 1
                        }
                    }
                }
            } catch {
                failed += 1
                transferPhase = "Falha em \(entry.name)"
                status = "Falha em \(entry.name): \(error.localizedDescription)"
            }
            updateTotalEstimate(completed: index + 1, total: chosen.count)
        }
        if stopRequested {
            transferPhase = "Parado"
            status = "Envio parado. \(success) arquivo(s) conferido(s) no PC; os originais continuam no iPhone."
            return
        }
        if !deleteAfterBackup {
            status = "\(success) guardado(s) e conferido(s) no PC. \(skipped) abaixo de \(minimumMB) MB. \(failed) falha(s). Nada foi apagado do iPhone."
            transferPhase = failed == 0 ? "Envio concluído" : "Envio concluído com falhas"
            return
        }
        status = "Cópias conferidas. Aguardando confirmação do iPhone para apagar os originais…"
        let photos = verifiedForRemoval.compactMap { entry -> PHAsset? in
            if case .photo(let asset) = entry.source { return asset }
            return nil
        }
        var removed = 0
        var removalFailed = 0
        var removedIDs: Set<String> = []
        if !photos.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(photos as NSArray)
                }
                removed += photos.count
                removedIDs.formUnion(photos.map(\.localIdentifier))
            } catch {
                removalFailed += photos.count
                status = "A exclusão da fototeca não foi autorizada: \(error.localizedDescription)"
            }
        }
        for entry in verifiedForRemoval {
            if case .file(let url) = entry.source {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                    removedIDs.insert(entry.id)
                } catch {
                    removalFailed += 1
                }
            }
        }
        if removed > 0 {
            entries.removeAll { removedIDs.contains($0.id) }
            selected.subtract(removedIDs)
            photoCount = entries.reduce(0) { count, entry in
                if case .photo(let asset) = entry.source, asset.mediaType == .image { return count + 1 }
                return count
            }
            videoCount = entries.reduce(0) { count, entry in
                if case .photo(let asset) = entry.source, asset.mediaType == .video { return count + 1 }
                return count
            }
            importedFileCount = entries.reduce(0) { count, entry in
                if case .file = entry.source { return count + 1 }
                return count
            }
        }
        status = "\(success) guardado(s) no PC; \(removed) apagado(s) do iPhone após conferência. \(retainedComplex) Live Photo/editado(s) preservado(s). \(skipped) abaixo do mínimo; \(failed + removalFailed) falha(s)."
        transferPhase = failed + removalFailed == 0 ? "Concluído" : "Concluído com falhas"
    }

    func prepareForCable() async {
        pauseRequested = false
        stopRequested = false
        switchToInternetRequested = false
        let alreadyQueued = queuedCableAssetIDs()
        let chosen = entries.filter {
            selected.contains($0.id) && !backedUp.contains($0.id) && !alreadyQueued.contains($0.id)
        }
        guard !chosen.isEmpty else {
            status = "Todas as mídias selecionadas já estão na fila do cabo ou conferidas no PC."
            return
        }
        isBusy = true
        hasTransferAttempt = true
        transferFileCount = chosen.count
        transferProgress = 0
        transferSpeed = 0
        transferSecondsRemaining = nil
        totalSecondsRemaining = nil
        transferCompletedCount = 0
        totalStartedAt = Date()
        defer { isBusy = false }
        do { try FileManager.default.createDirectory(at: cableFolder, withIntermediateDirectories: true) }
        catch { status = "Não foi possível preparar a pasta para o cabo: \(error.localizedDescription)"; return }
        var prepared = 0
        var skipped = 0
        var failed = 0
        for (index, entry) in chosen.enumerated() {
            guard await continueAtFileBoundary() else { break }
            transferFileIndex = index + 1
            transferPhase = "Obtendo original: \(entry.name)"
            transferProgress = 0
            do {
                let (source, temporary) = try await materialize(entry)
                defer { if temporary { try? FileManager.default.removeItem(at: source) } }
                let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size < Int64(minimumMB) * 1_000_000 {
                    skipped += 1
                    updateTotalEstimate(completed: index + 1, total: chosen.count)
                    continue
                }
                let id = UUID().uuidString
                let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
                let fileName = "\(id).\(ext)"
                let target = cableFolder.appendingPathComponent(fileName)
                do {
                    let input = try FileHandle(forReadingFrom: source)
                    defer { try? input.close() }
                    FileManager.default.createFile(atPath: target.path, contents: nil)
                    let output = try FileHandle(forWritingTo: target)
                    defer { try? output.close() }
                    var hash = SHA256()
                    var copied: Int64 = 0
                    transferStartedAt = Date()
                    transferPhase = "Preparando cabo: \(entry.name)"
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                        try output.write(contentsOf: data)
                        hash.update(data: data)
                        copied += Int64(data.count)
                        updateUploadProgress(sent: copied, expected: size)
                        await Task.yield()
                    }
                    try output.synchronize()
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    let manifest = CableManifest(id: id, assetID: entry.id, name: entry.name,
                                                 fileName: fileName, size: size, sha256: digest)
                    let manifestURL = cableFolder.appendingPathComponent("\(id).json")
                    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                    prepared += 1
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    throw error
                }
            } catch {
                failed += 1
                status = "Falha ao preparar \(entry.name): \(error.localizedDescription)"
            }
            updateTotalEstimate(completed: index + 1, total: chosen.count)
        }
        cableQueueCount += prepared
        transferPhase = switchToInternetRequested ? "Mudando para rede" :
            (stopRequested ? "Preparação parada" : "Pronto para copiar pelo cabo")
        status = "\(prepared) arquivo(s) preparado(s) para cabo; o PC continuará a copiá-los. \(skipped) abaixo do mínimo; \(failed) falha(s). Nada foi apagado."
        Task { await monitorCableReceipts() }
    }

    func monitorCableReceipts() async {
        guard !cableMonitorRunning else { return }
        cableMonitorRunning = true
        defer { cableMonitorRunning = false }
        for _ in 0..<600 {
            checkCableReceipts()
            if cableQueueCount == 0 { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func checkCableReceipts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cableFolder,
            includingPropertiesForKeys: nil)) ?? []
        var pending = 0
        var confirmed = 0
        for manifestURL in files where manifestURL.pathExtension == "json"
                && !manifestURL.lastPathComponent.hasSuffix(".receipt.json")
                && !manifestURL.lastPathComponent.hasSuffix(".progress.json") {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(CableManifest.self, from: data) else { continue }
            let receiptURL = cableFolder.appendingPathComponent("\(manifest.id).receipt.json")
            if let receiptData = try? Data(contentsOf: receiptURL),
               let receipt = try? JSONDecoder().decode(CableReceipt.self, from: receiptData),
               receipt.id == manifest.id, receipt.size == manifest.size,
               receipt.sha256 == manifest.sha256 {
                backedUp.insert(manifest.assetID)
                cableVerifiedIDs.insert(manifest.assetID)
                cableVerifiedHashes[manifest.assetID] = manifest.sha256
                try? FileManager.default.removeItem(at: cableFolder.appendingPathComponent(manifest.fileName))
                confirmed += 1
            } else {
                pending += 1
                let progressURL = cableFolder.appendingPathComponent("\(manifest.id).progress.json")
                if let progressData = try? Data(contentsOf: progressURL),
                   let progress = try? JSONDecoder().decode(CableProgress.self, from: progressData),
                   progress.total > 0 {
                    transferPhase = "Copiando pelo cabo: \(manifest.name)"
                    transferProgress = min(1, Double(progress.bytes) / Double(progress.total))
                    transferSpeed = progress.speed
                    transferSecondsRemaining = progress.speed > 0 ? Double(progress.total - progress.bytes) / progress.speed : nil
                }
            }
        }
        cableQueueCount = pending
        if pending == 0 && confirmed > 0 {
            transferPhase = "Cópia pelo cabo concluída"
            transferProgress = 1
            status = "\(confirmed) arquivo(s) conferido(s) no disco D:. Os originais continuam no iPhone."
        }
    }

    func deleteCableConfirmedSelected() async {
        checkCableReceipts()
        let chosen = entries.filter { selected.contains($0.id) && cableVerifiedIDs.contains($0.id) }
        guard !chosen.isEmpty else { status = "Selecione mídias já conferidas pelo cabo."; return }
        isBusy = true
        transferFileCount = chosen.count
        defer { isBusy = false }
        var safeToDelete: [MediaEntry] = []
        var retained = 0
        for (index, entry) in chosen.enumerated() {
            transferFileIndex = index + 1
            transferPhase = "Reverificando original: \(entry.name)"
            do {
                guard let expectedHash = cableVerifiedHashes[entry.id] else { retained += 1; continue }
                let (file, temporary) = try await materialize(entry)
                defer { if temporary { try? FileManager.default.removeItem(at: file) } }
                guard try sha256(file) == expectedHash else { retained += 1; continue }
                if case .photo(let asset) = entry.source {
                    let resources = PHAssetResource.assetResources(for: asset)
                    guard resources.count == 1 && !asset.mediaSubtypes.contains(.photoLive) else {
                        retained += 1
                        continue
                    }
                }
                safeToDelete.append(entry)
            } catch { retained += 1 }
        }
        let photos = safeToDelete.compactMap { entry -> PHAsset? in
            if case .photo(let asset) = entry.source { return asset }
            return nil
        }
        var removedIDs: Set<String> = []
        if !photos.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(photos as NSArray)
                }
                removedIDs.formUnion(photos.map(\.localIdentifier))
            } catch { retained += photos.count }
        }
        for entry in safeToDelete {
            if case .file(let url) = entry.source {
                do {
                    try FileManager.default.removeItem(at: url)
                    removedIDs.insert(entry.id)
                } catch { retained += 1 }
            }
        }
        entries.removeAll { removedIDs.contains($0.id) }
        selected.subtract(removedIDs)
        photoCount = entries.reduce(0) { count, entry in
            if case .photo(let asset) = entry.source, asset.mediaType == .image { return count + 1 }
            return count
        }
        videoCount = entries.reduce(0) { count, entry in
            if case .photo(let asset) = entry.source, asset.mediaType == .video { return count + 1 }
            return count
        }
        importedFileCount = entries.reduce(0) { count, entry in
            if case .file = entry.source { return count + 1 }
            return count
        }
        transferPhase = "Limpeza pelo cabo concluída"
        status = "\(removedIDs.count) mídia(s) apagada(s) após conferência pelo cabo. \(retained) preservada(s) por segurança."
    }

    private func updateUploadProgress(sent: Int64, expected: Int64) {
        guard expected > 0 else { return }
        transferProgress = min(1, max(0, Double(sent) / Double(expected)))
        let elapsed = max(Date().timeIntervalSince(transferStartedAt), 0.1)
        transferSpeed = Double(sent) / elapsed
        transferSecondsRemaining = transferSpeed > 0 ? Double(expected - sent) / transferSpeed : nil
    }

    private func updateTotalEstimate(completed: Int, total: Int) {
        transferCompletedCount = completed
        guard completed >= 5, completed < total else {
            totalSecondsRemaining = nil
            return
        }
        // Include Photos/iCloud preparation, hashing, and transfer stalls in the
        // observed average. This is an estimate, not a USB link-speed claim.
        let elapsed = max(Date().timeIntervalSince(totalStartedAt), 1)
        totalSecondsRemaining = elapsed / Double(completed) * Double(total - completed)
    }

    private func verifySavedCopy(_ receipt: UploadReceipt, at base: URL) async throws {
        var components = URLComponents(url: base.appendingPathComponent("api/verify"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "folder", value: receipt.folder),
            URLQueryItem(name: "name", value: receipt.name),
            URLQueryItem(name: "size", value: String(receipt.size)),
            URLQueryItem(name: "sha256", value: receipt.sha256)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(accessCode, forHTTPHeaderField: "x-media-token")
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "GuardaMidias", code: 4, userInfo: [NSLocalizedDescriptionKey: "O computador não confirmou a cópia; o original será mantido"])
        }
    }

    private func materialize(_ entry: MediaEntry) async throws -> (URL, Bool) {
        switch entry.source {
        case .file(let url): return (url, false)
        case .photo(let asset):
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }) else {
                throw NSError(domain: "GuardaMidias", code: 3, userInfo: [NSLocalizedDescriptionKey: "Original indisponível"])
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + entry.name)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return (target, true)
        }
    }

    private func sha256(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
