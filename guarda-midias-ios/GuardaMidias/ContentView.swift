import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = MediaStore()
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var through = Date()
    @State private var internet = UserDefaults.standard.string(forKey: "serverURL") != "http://192.168.68.82:8765"
    @State private var useCable = false
    @State private var confirmBackupAndDelete = false

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
                        Button { Task {
                            if useCable { await store.prepareForCable() }
                            else { await store.sendSelected() }
                        } } label: {
                            Label(useCable ? "Preparar \(store.selected.count) para cabo" : "Guardar \(store.selected.count) no computador",
                                  systemImage: useCable ? "cable.connector" : "arrow.up.doc.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(store.isBusy || store.selected.isEmpty || (useCable && store.cableQueueCount > 0))
                        if !useCable {
                        Button {
                            confirmBackupAndDelete = true
                        } label: {
                            Label("Guardar e apagar do iPhone", systemImage: "externaldrive.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(store.isBusy || store.selected.isEmpty)
                        Text("Só apaga após conferir a cópia no computador. Se Fotos do iCloud estiver ativo, a exclusão também será sincronizada com iCloud e outros aparelhos. Live Photos e fotos editadas permanecem no iPhone. Mídias dentro do WhatsApp precisam ser apagadas no próprio WhatsApp.")
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("O cabo guarda os originais sem apagar. Depois da cópia confirmada, você pode decidir o que remover no iPhone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Escolha o período e toque em Buscar para ver o total.")
                            .foregroundStyle(.secondary)
                    }
                    Text(store.status).font(.caption)
                    if store.hasTransferAttempt {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.transferPhase).font(.subheadline.weight(.semibold))
                            if store.transferFileCount > 0 {
                                Text("Arquivo \(store.transferFileIndex) de \(store.transferFileCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if store.transferPhase.hasPrefix("Enviando") || store.transferProgress > 0 {
                                ProgressView(value: store.transferProgress)
                                Text("\(Int(store.transferProgress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(store.transferSpeed), countStyle: .file))/s" +
                                     (store.transferSecondsRemaining.map { " · faltam cerca de \(Int($0.rounded())) s" } ?? ""))
                                    .font(.caption).monospacedDigit()
                            } else if store.isBusy {
                                ProgressView()
                            }
                        }
                    }
                }
                Section("Conexão com o computador") {
                    Picker("Método", selection: $useCable) {
                        Text("Internet / Wi-Fi").tag(false)
                        Text("Cabo USB").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useCable {
                        Text("Conecte e desbloqueie o iPhone no PC. O Guarda Mídias no computador copiará os arquivos preparados para o disco D: e conferirá cada um.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Conferir cópias do cabo") { store.checkCableReceipts() }
                        Text("\(store.cableQueueCount) arquivo(s) aguardando cópia pelo cabo")
                            .font(.caption)
                    } else {
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
                    Text("Se você escolher Guardar e apagar, o app só remove da fototeca ou da pasta Guarda Mídias as mídias cuja cópia foi conferida. Conteúdo que continua dentro do WhatsApp deve ser removido no próprio WhatsApp.")
                }
            }
            .navigationTitle("Guarda Mídias")
        }
        .task { await store.monitorCableReceipts() }
        .confirmationDialog("Guardar e apagar do iPhone?", isPresented: $confirmBackupAndDelete, titleVisibility: .visible) {
            Button("Guardar e apagar as cópias conferidas", role: .destructive) {
                Task { await store.sendSelected(deleteAfterBackup: true) }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("O app conferirá cada cópia no computador antes de apagar o original. ATENÇÃO: se Fotos do iCloud estiver ativo, as exclusões também atingirão iCloud e outros aparelhos sincronizados. Mídias sem cópia confirmada serão mantidas.")
        }
    }
}
