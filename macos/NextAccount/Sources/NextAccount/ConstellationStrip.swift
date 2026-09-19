import SwiftUI

/// Provider status shown as a row of constellation badges. Each badge reports
/// one provider's own live/saved state and never mixes data between providers.
struct ConstellationStrip: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AIProvider.allCases) { provider in
                ConstellationBadge(provider: provider)
            }
        }
    }
}

private struct ConstellationBadge: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let provider: AIProvider

    private var state: ProviderState? {
        store.providerStates.first { $0.provider == provider }
    }

    private var isLive: Bool {
        state?.available == true
    }

    private var savedCount: Int {
        state?.savedAccounts ?? (provider == .openAI ? store.accounts.count : 0)
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: provider.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLive ? PrismTheme.success : Color.secondary)
            Text(provider.compactName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Text(language.text("\(savedCount)", "\(savedCount)"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 48, minHeight: 48)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isLive ? PrismTheme.surfaceHover : PrismTheme.surfacePanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLive ? PrismTheme.success.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        let status = isLive
            ? language.text("đang live", "live")
            : language.text("chưa có phiên", "offline")
        return language.text(
            "\(provider.name): \(status), \(savedCount) đã lưu",
            "\(provider.name): \(status), \(savedCount) saved"
        )
    }
}
