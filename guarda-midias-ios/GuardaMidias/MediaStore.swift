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

    func saveConnection() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(accessCode, forKey: "accessCode")
    }

    func clearSearch() {
        entries = []
        selected = []
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
        var found: [MediaEntry] = []
        if auth == .authorized || auth == .limited {
            let options = PHFetchOptions()
            let calendar = Calendar.current
            let first = calendar.startOfDay(for: start)
            let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", first as NSDate, afterLast as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)
            result.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let resource = PHAssetResource.assetResources(for: asset).first
                found.append(MediaEntry(id: asset.localIdentifier,
                                        name: resource?.originalFilename ?? "Mídia",
                                        date: asset.creationDate ?? first,
                                        source: .photo(asset)))
            }
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "mp4", "mov", "m4v", "avi"]
            let calendar = Calendar.current
            for file in files where extensions.contains(file.pathExtension.lowercased()) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date >= calendar.startOfDay(for: start), date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end) {
                    found.append(MediaEntry(id: file.path, name: file.lastPathComponent, date: date, source: .file(file)))
                }
            }
        }
        entries = found.sorted { $0.date > $1.date }
        selected = []
        status = "\(entries.count) mídia(s) encontradas. Selecione as que deseja guardar."
    }

    func sendSelected() async {
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
            } catch {
                failed += 1
                status = "Falha em \(entry.name): \(error.localizedDescription)"
            }
        }
        status = "\(success) guardado(s) e conferido(s) no PC. \(skipped) abaixo de \(minimumMB) MB. \(failed) falha(s). Nada foi apagado do iPhone."
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
