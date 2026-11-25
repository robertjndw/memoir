import Foundation

extension Services {
    static var live: Services {
        let calendar = EventKitCalendar()
        return Services(
            makeRecorder: { AudioRecorder(folder: $0, keepTracks: $1) },
            makeTranscriber: { SpeechTranscriptionPipeline() },
            speechModels: SpeechModelManager(),
            optionalModels: FluidModelStore(),
            enhancer: FluidEnhancer(),
            intelligence: AppleIntelligence(),
            calendar: calendar,
            detector: MeetingDetector(calendar: calendar),
            hints: MeetingHintPanelController()
        )
    }
}
