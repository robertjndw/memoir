import Foundation

/// What Settings says about each optional model.
nonisolated extension OptionalModel {
    // Measured on disk after a download. The files are not compressed in transit, so this is
    // also what goes over the network.
    static let speakerIdentificationDownloadSize: Int64 = 22_000_000
    static let enhancedTranscriptionDownloadSize: Int64 = 640_000_000

    var title: LocalizedStringResource {
        switch self {
        case .speakerIdentification: "Identify speakers"
        case .enhancedTranscription: "Enhanced transcription"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .speakerIdentification: "Tells apart the people on a call after the recording ends."
        case .enhancedTranscription: "Transcribes again after the recording ends. Supports 25 European languages."
        }
    }

    /// Approximate, shown before the download starts.
    var downloadSize: Int64 {
        switch self {
        case .speakerIdentification: Self.speakerIdentificationDownloadSize
        case .enhancedTranscription: Self.enhancedTranscriptionDownloadSize
        }
    }

    /// The model and its license, for the footer only. Titles stay free of model names.
    var credit: LocalizedStringResource {
        switch self {
        case .speakerIdentification: "Speaker identification uses pyannote Community-1 (CC BY 4.0)."
        case .enhancedTranscription: "Enhanced transcription uses Parakeet Ultra by Moondream, based on NVIDIA Parakeet (CC BY 4.0)."
        }
    }
}
