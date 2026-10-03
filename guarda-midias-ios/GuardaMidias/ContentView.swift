import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = MediaStore()
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var through = Date()
    @State private var internet = UserDefaults.standard.string(forKey: "serverURL") != "http://192.168.68.82:8765"

    var body: some View {
        NavigationStack {
            Form {
                Section("Período das fotos") {
                    Button("Todo o histórico até hoje") {
                        from = Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? .distantPast
                        through = Date()
                    }
                    DatePicker("De", selection: $from, displayedComponents: .date).disabled(store.isBusy)
                    DatePicker("Até", selection: $through, in: from..., displayedComponents: .date).disabled(store.isBusy)
                    Button { Task { await store.find(from: from, through: through) } } label: {
                        Label("Buscar fotos e vídeos", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    .disabled(store.isBusy)
                }
                .onChange(of: from) { _, _ in store.clearSearch() }
                .onChange(of: through) { _, _ in store.clearSearch() }
                Section("Encontradas no período") {
                    if store.hasSearched {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.stack.fill")
                                .font(.title).foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(store.entries.count)")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                Text("mídias encontradas no período")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(store.photoCount) fotos · \(store.videoCount) vídeos · \(store.importedFileCount) arquivos importados")
                        Text("\(store.selected.count) selecionadas para guardar")
                            .foregroundStyle(.secondary)
                        if store.limitedPhotoAccess {
                            Text("O iPhone autorizou apenas parte da fototeca. Para encontrar todas, permita acesso a Todas as Fotos nos Ajustes.")
                                .foregroundStyle(.orange)
                            Button("Abrir Ajustes das Fotos") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        } else {
                            Text("\(store.accessibleLibraryCount) mídias acessíveis na fototeca inteira.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Selecionar todas as encontradas") { store.selected = Set(store.entries.map(\.id)) }
                            .disabled(store.entries.isEmpty || store.isBusy)
                        Button("Limpar seleção") { store.selected = [] }
                            .disabled(store.selected.isEmpty || store.isBusy)
                        Button { Task { await store.sendSelected() } } label: {
                            Label("Guardar \(store.selected.count) no computador", systemImage: "arrow.up.doc.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(store.isBusy || store.selected.isEmpty)
                    } else {
                        Text("Escolha o período e toque em Buscar para ver o total.")
                            .foregroundStyle(.secondary)
                    }
                    Text(store.status).font(.caption)
                }
                Section("Conexão com o computador") {
                    Picker("Local", selection: $internet) {
                        Text("Pela internet").tag(true)
                        Text("Em casa").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: internet) { _, remote in
                        store.serverURL = remote ? "http://100.113.163.32:8765" : "http://192.168.68.82:8765"
                    }
                    TextField("Endereço", text: $store.serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("Código de acesso", text: $store.accessCode)
                        .keyboardType(.numberPad)
                    Button("Testar conexão") { Task { await store.testConnection() } }
                        .disabled(store.isBusy)
                    Text("Para usar pela internet, deixe o Tailscale ligado no iPhone e no computador.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Os arquivos serão guardados em uma pasta separada no disco D:.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Arquivos") {
                    if !store.entries.isEmpty {
                        Stepper("Tamanho mínimo: \(store.minimumMB) MB", value: $store.minimumMB, in: 0...100, step: 1)
                    }
                    ForEach(store.entries) { entry in
                        Button {
                            if store.selected.contains(entry.id) { store.selected.remove(entry.id) }
                            else { store.selected.insert(entry.id) }
                        } label: {
                            HStack {
                                Image(systemName: store.selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).lineLimit(1)
                                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.backedUp.contains(entry.id) {
                                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section("Importante") {
                    Text("O app pode ler Fotos após sua permissão e arquivos salvos em No Meu iPhone > Guarda Mídias. Mídias que estão só dentro do WhatsApp precisam ser compartilhadas para Fotos ou Arquivos.")
                    Text("Depois da cópia confirmada, apague os originais no próprio WhatsApp para liberar espaço. Este app nunca apaga conversas ou mídias automaticamente.")
                }
            }
            .navigationTitle("Guarda Mídias")
        }
    }
}
