import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var store = MediaStore()
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var through = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Período das fotos") {
                    DatePicker("De", selection: $from, displayedComponents: .date)
                    DatePicker("Até", selection: $through, in: from..., displayedComponents: .date)
                    Button("Buscar fotos e vídeos") { Task { await store.find(from: from, through: through) } }
                        .disabled(store.isBusy)
                }
                Section("Conexão com o computador") {
                    TextField("Endereço", text: $store.serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("Código de acesso", text: $store.accessCode)
                    Text("Os arquivos serão guardados em uma pasta separada no disco D:.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Arquivos") {
                    if !store.entries.isEmpty {
                        Button("Selecionar todos do período") { store.selected = Set(store.entries.map(\.id)) }
                        Button("Limpar seleção") { store.selected = [] }
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
                    if !store.entries.isEmpty {
                        Button("Guardar \(store.selected.count) no computador") { Task { await store.sendSelected() } }
                            .disabled(store.isBusy || store.selected.isEmpty)
                    }
                }
                Section("Situação") { Text(store.status) }
                Section("Importante") {
                    Text("O app pode ler Fotos após sua permissão e arquivos salvos em No Meu iPhone > Guarda Mídias. Mídias que estão só dentro do WhatsApp precisam ser compartilhadas para Fotos ou Arquivos.")
                    Text("Depois da cópia confirmada, apague os originais no próprio WhatsApp para liberar espaço. Este app nunca apaga conversas ou mídias automaticamente.")
                }
            }
            .navigationTitle("Guarda Mídias")
        }
    }
}
