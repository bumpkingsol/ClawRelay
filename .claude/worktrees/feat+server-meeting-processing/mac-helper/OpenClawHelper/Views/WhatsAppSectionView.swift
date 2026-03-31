import SwiftUI

struct WhatsAppSectionView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with status
            HStack {
                Image(systemName: "message.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("WhatsApp")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(viewModel.whatsAppStatus)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(whatsAppStatusColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(whatsAppStatusColor)
            }

            // Whitelist contacts (only show if there are any)
            if !viewModel.whatsAppContacts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Whitelist")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.whatsAppContacts) { contact in
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(contact.label)
                                .font(.caption2)
                            Spacer()
                            Text(contact.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 4)
            }

            // Actions
            HStack(spacing: 8) {
                Button(action: { viewModel.relinkWhatsApp() }) {
                    Label("Re-link", systemImage: "qrcode")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.addWhatsAppContact() }) {
                    Label("Add Contact", systemImage: "person.badge.plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var whatsAppStatusColor: Color {
        switch viewModel.whatsAppStatus {
        case "Syncing":       return .green
        case "Paused":        return .orange
        case "Disconnected":  return .red
        case "Error":         return .red
        case "Not running":   return .secondary
        case "Not installed": return .secondary
        default:              return .secondary
        }
    }
}
