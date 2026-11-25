import SwiftUI

/// A failure the user can dismiss, and retry where that makes sense.
struct ErrorRow: View {
    /// What failed, in a few words. Without it the message stands alone.
    var title: LocalizedStringKey?
    let message: String
    var retry: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(message).font(.callout)
            }
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
