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

@MainActor
final class MediaStore: ObservableObject {
    @Published var entries: [MediaEntry] = []
    @Published var selected: Set<String> = []
    @Published var status = "Escolha o período e toque em Buscar fotos."
    @Published var isBusy = false
    @Published var backedUp: Set<String> = []
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://100.113.163.32:8765"
    @Published var accessCode = UserDefaults.standard.string(forKey: "accessCode") ?? ""
    @Published var minimumMB = 5
    @Published var hasSearched = false
    @Published var limitedPhotoAccess = false
    @Published var accessibleLibraryCount = 0
    @Published var photoCount = 0
    @Published var videoCount = 0
    @Published var importedFileCount = 0

    func saveConnection() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(accessCode, forKey: "accessCode")
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
                let resource = PHAssetResource.assetResources(for: asset).first
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
            let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "mp4", "mov", "m4v", "avi"]
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

    func sendSelected(deleteAfterBackup: Bool = false) async {
        guard let base = URL(string: serverURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              !accessCode.isEmpty else {
            status = "Confira o endereço do computador e o código de acesso."
            return
        }
        saveConnection()
        isBusy = true
        defer { isBusy = false }
        let chosen = entries.filter { selected.contains($0.id) }
        var success = 0
        var skipped = 0
        var failed = 0
        var retainedComplex = 0
        var verifiedForRemoval: [MediaEntry] = []
        for (index, entry) in chosen.enumerated() {
            status = "Verificando \(index + 1) de \(chosen.count): \(entry.name)"
            do {
                let (file, temporary) = try await materialize(entry)
                defer { if temporary { try? FileManager.default.removeItem(at: file) } }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size < Int64(minimumMB) * 1_000_000 { skipped += 1; continue }
                let localHash = try sha256(file)
                var components = URLComponents(url: base.appendingPathComponent("api/upload"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "name", value: entry.name)]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "PUT"
                request.setValue(accessCode, forHTTPHeaderField: "x-media-token")
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
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
                status = "Falha em \(entry.name): \(error.localizedDescription)"
            }
        }
        if !deleteAfterBackup {
            status = "\(success) guardado(s) e conferido(s) no PC. \(skipped) abaixo de \(minimumMB) MB. \(failed) falha(s). Nada foi apagado do iPhone."
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
            guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }) ?? resources.first else {
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
