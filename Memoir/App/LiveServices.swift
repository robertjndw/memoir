import Foundation

extension Services {
    static var live: Services {
        let calendar = EventKitCalendar()
        return Services(
            makeRecorder: { AudioRecorder(folder: $0) },
            makeTranscriber: { SpeechTranscriptionPipeline() },
            speechModels: SpeechModelManager(),
            intelligence: AppleIntelligence(),
            calendar: calendar,
            detector: MeetingDetector(calendar: calendar),
            hints: MeetingHintPanelController()
        )
    }
}
