import Foundation
import FoundationModels

/// What the UI sees when summarizing or chatting fails. Framework errors differ between
/// macOS 26 (`LanguageModelSession.GenerationError`) and 27 (`LanguageModelError` and
/// friends), so all mapping lives in this file.
nonisolated enum IntelligenceError: LocalizedError, Equatable, Sendable {
    case unavailable(IntelligenceAvailability)
    case emptyTranscript
    case meetingNotFound
    case contextTooLarge
    case guardrailViolation
    case refusal
    case unsupportedLanguage
    case rateLimited
    case timeout
    case assetsUnavailable
    case busy
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(.deviceNotEligible):
            "Apple Intelligence is not supported on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is turned off. Turn it on in System Settings to use summaries and chat."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable(.available):
            "Apple Intelligence is not available right now."
        case .emptyTranscript:
            "There is nothing in the transcript to summarize yet."
        case .meetingNotFound:
            "This meeting could not be found."
        case .contextTooLarge:
            "This was too much text for Apple Intelligence to handle at once."
        case .guardrailViolation:
            "Apple Intelligence declined to process this content because it may be sensitive."
        case .refusal:
            "Apple Intelligence declined to answer this request."
        case .unsupportedLanguage:
            "Apple Intelligence does not support this language yet."
        case .rateLimited:
            "Apple Intelligence is busy. Try again in a moment."
        case .timeout:
            "Apple Intelligence took too long to respond. Try again."
        case .assetsUnavailable:
            "The Apple Intelligence model is not available right now. It may still be downloading."
        case .busy:
            "Apple Intelligence is already working on another request."
        case .failed(let detail):
            detail.isEmpty ? "Apple Intelligence could not complete the request." : detail
        }
    }

    /// Converts any error from the framework into an `IntelligenceError`. Cancellation passes
    /// through untouched so callers can tell a user stop apart from a failure.
    static func from(_ error: any Error) -> any Error {
        if error is CancellationError || error is IntelligenceError { return error }
        if let mapped = mapFramework(error) { return mapped }
        if let tool = error as? LanguageModelSession.ToolCallError {
            return from(tool.underlyingError)
        }
        return IntelligenceError.failed(error.localizedDescription)
    }

    static func isContextOverflow(_ error: any Error) -> Bool {
        (from(error) as? IntelligenceError) == .contextTooLarge
    }

    /// Worth one automatic retry after a short pause.
    static func isTransient(_ error: any Error) -> Bool {
        switch from(error) as? IntelligenceError {
        case .rateLimited, .busy, .timeout: true
        default: false
        }
    }

    private static func mapFramework(_ error: any Error) -> IntelligenceError? {
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                return switch error {
                case .contextSizeExceeded: .contextTooLarge
                case .guardrailViolation: .guardrailViolation
                case .refusal: .refusal
                case .unsupportedLanguageOrLocale: .unsupportedLanguage
                case .rateLimited: .rateLimited
                case .timeout: .timeout
                default: .failed(error.localizedDescription)
                }
            }
            if let error = error as? LanguageModelSession.Error {
                return switch error {
                case .concurrentRequests: .busy
                default: .failed(error.localizedDescription)
                }
            }
            if error is SystemLanguageModel.Error {
                return .assetsUnavailable
            }
            return nil
        } else {
            return mapLegacy(error)
        }
    }

    @available(macOS, introduced: 26.0, deprecated: 27.0)
    private static func mapLegacy(_ error: any Error) -> IntelligenceError? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        return switch error {
        case .exceededContextWindowSize: .contextTooLarge
        case .assetsUnavailable: .assetsUnavailable
        case .guardrailViolation: .guardrailViolation
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .rateLimited: .rateLimited
        case .concurrentRequests: .busy
        case .refusal: .refusal
        case .unsupportedGuide, .decodingFailure: .failed(error.localizedDescription)
        @unknown default: .failed(error.localizedDescription)
        }
    }
}

nonisolated extension IntelligenceAvailability {
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available: self = .available
        case .unavailable(.deviceNotEligible): self = .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): self = .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): self = .modelNotReady
        case .unavailable: self = .modelNotReady
        }
    }
}
