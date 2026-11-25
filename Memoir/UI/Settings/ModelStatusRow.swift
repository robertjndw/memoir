import SwiftUI

/// Where a downloadable model stands, whichever kind of model it is.
enum ModelAvailability: Equatable {
    case checking
    case notInstalled
    case unsupported
    /// Progress 0...1, nil until the first report.
    case downloading(Double?)
    /// Bytes on disk when known.
    case installed(size: Int64?)
}

/// One row for a model the user downloads, used for Apple's speech model and the optional models.
///
/// With a `title` the row is about the model ("Speech model: Installed"). Without one it sits
/// under a toggle that already says what the model is for, so the status becomes the label
/// and only the action or progress is on the trailing side.
struct ModelStatusRow: View {
    var title: LocalizedStringKey?
    let availability: ModelAvailability
    var failure: String?
    /// Approximate size of the download, shown before and while downloading.
    var downloadSize: Int64?
    var isRemoving = false
    let download: () -> Void
    /// Offered once installed. Nil for models that can't be removed from here.
    var remove: (() -> Void)?

    var body: some View {
        LabeledContent {
            if title == nil {
                action
            } else {
                titledStatus
            }
        } label: {
            if let title {
                Text(title)
            } else {
                status
                if let detail {
                    Text(detail)
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .animation(.smooth(duration: 0.2), value: availability)
    }

    // MARK: - Status as the label

    @ViewBuilder private var status: some View {
        switch availability {
        case .checking:
            Text("Checking…")
        case .notInstalled:
            Text("Not downloaded")
        case .unsupported:
            Text("Not supported")
        case .downloading:
            Text("Downloading…")
        case .installed:
            Label {
                Text("Installed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var detail: String? {
        let approximate = downloadSize.map { String(localized: "About \($0.formatted(.byteCount(style: .file)))") }
        switch availability {
        case .notInstalled:
            return approximate
        case .downloading(let progress?):
            guard let downloadSize else { return nil }
            return String(localized: "\(progress.formatted(.percent.precision(.fractionLength(0)))) of about \(downloadSize.formatted(.byteCount(style: .file)))")
        case .downloading(nil):
            return approximate
        case .installed(let size?):
            return String(localized: "\(size.formatted(.byteCount(style: .file))) on this Mac")
        case .checking, .unsupported, .installed(nil):
            return nil
        }
    }

    @ViewBuilder private var action: some View {
        switch availability {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Button(failure == nil ? "Download" : "Retry", action: download)
        case .downloading(let progress):
            progressBar(progress)
        case .installed:
            if let remove {
                Button("Remove", action: remove)
                    .disabled(isRemoving)
            }
        case .unsupported:
            EmptyView()
        }
    }

    // MARK: - Status beside a title

    private var titledStatus: some View {
        HStack(spacing: 8) {
            switch availability {
            case .checking:
                ProgressView().controlSize(.small)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let remove {
                    Button("Remove", action: remove)
                        .disabled(isRemoving)
                }
            case .unsupported:
                Label("Not supported", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .downloading(let progress):
                progressBar(progress)
                Text("Downloading")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Text("Not downloaded")
                    .foregroundStyle(.secondary)
                Button(failure == nil ? "Download" : "Retry", action: download)
            }
        }
    }

    @ViewBuilder
    private func progressBar(_ progress: Double?) -> some View {
        if let progress {
            ProgressView(value: progress)
                .frame(width: 100)
                .accessibilityLabel("Download progress")
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

#Preview("States") {
    Form {
        Section("Under a toggle") {
            ModelStatusRow(availability: .notInstalled, downloadSize: 630_000_000, download: {})
            ModelStatusRow(availability: .downloading(0.42), downloadSize: 630_000_000, download: {})
            ModelStatusRow(availability: .installed(size: 612_400_000), downloadSize: 630_000_000, download: {}, remove: {})
            ModelStatusRow(
                availability: .notInstalled,
                failure: "The network connection was lost.",
                downloadSize: 630_000_000,
                download: {}
            )
        }
        Section("With a title") {
            ModelStatusRow(title: "Speech model", availability: .installed(size: nil), download: {})
            ModelStatusRow(title: "Speech model", availability: .downloading(0.6), download: {})
            ModelStatusRow(title: "Speech model", availability: .notInstalled, download: {})
        }
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
