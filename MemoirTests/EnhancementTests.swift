import AVFoundation
import Foundation
import Testing
@testable import Memoir

@Suite("Transcript assembler")
struct TranscriptAssemblerTests {
    typealias Assembler = TranscriptAssembler

    static func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * step
            return TimedWord(text: String(word), start: begin, end: begin + step * 0.8)
        }
    }

    // MARK: Splitting

    @Test func splitsAtSentenceEnds() {
        let lines = Assembler.finish(Assembler.lines(from: Self.words("Hello there. How are you? Fine", from: 0), attribution: .speaker(.me)))
        #expect(lines.map(\.text) == ["Hello there.", "How are you?", "Fine"])
        #expect(lines.allSatisfy { $0.speaker == .me && $0.voice == nil })
        #expect(lines[0].start == 0)
        #expect(abs(lines[0].end - 0.72) < 0.001)
    }

    @Test func splitsAtLongPauses() {
        let words = Self.words("one two", from: 0) + Self.words("three four", from: 5)
        let lines = Assembler.finish(Assembler.lines(from: words, attribution: .speaker(.others)))
        #expect(lines.map(\.text) == ["one two", "three four"])
    }

    @Test func keepsShortPausesInOneLine() {
        let words = Self.words("one two", from: 0) + Self.words("three four", from: 1.5)
        #expect(Assembler.lines(from: words, attribution: .speaker(.others)).map(\.text) == ["one two three four"])
    }

    @Test func endsLinesThatRunTooLong() {
        let text = Array(repeating: "word", count: 100).joined(separator: " ")
        let lines = Assembler.lines(from: Self.words(text, from: 0, step: 0.5), attribution: .speaker(.me))
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.end - $0.start <= Assembler.maxLineDuration })
        #expect(lines.map { $0.text.split(separator: " ").count }.reduce(0, +) == 100)
    }

    @Test func recognizesSentenceEndsBehindQuotes() {
        #expect(Assembler.endsSentence("done."))
        #expect(Assembler.endsSentence("done?\""))
        #expect(Assembler.endsSentence("終わり。"))
        #expect(!Assembler.endsSentence("e.g"))
        #expect(!Assembler.endsSentence("well,"))
    }

    @Test func ignoresEmptyWordsAndSortsByTime() {
        let words = [TimedWord(text: "world", start: 1, end: 1.3), TimedWord(text: " ", start: 0.5, end: 0.6), TimedWord(text: "hello", start: 0, end: 0.3)]
        #expect(Assembler.lines(from: words, attribution: .speaker(.me)).map(\.text) == ["hello world"])
    }

    // MARK: Speakers

    @Test func splitsOnSpeakerChangeAndNumbersVoicesByFirstAppearance() {
        // The diarizer's cluster numbers say nothing about order: cluster 7 speaks first.
        let turns = [SpeakerTurn(start: 0, end: 2, cluster: 7), SpeakerTurn(start: 2, end: 4, cluster: 3), SpeakerTurn(start: 4, end: 6, cluster: 7)]
        let words = Self.words("a b c d e", from: 0.1) + Self.words("f g h i", from: 2.1) + Self.words("j k", from: 4.1)
        let lines = Assembler.finish(Assembler.lines(from: words, attribution: .turns(turns, user: nil, others: .others)))
        #expect(lines.map(\.text) == ["a b c d e", "f g h i", "j k"])
        #expect(lines.map(\.voice) == [1, 2, 1])
        #expect(lines.allSatisfy { $0.speaker == .others })
        #expect(lines.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func wordsOutsideEveryTurnGoToTheNearestTurn() {
        let turns = [SpeakerTurn(start: 0, end: 1, cluster: 0), SpeakerTurn(start: 5, end: 6, cluster: 1)]
        let words = [
            TimedWord(text: "early", start: 1.2, end: 1.4),
            TimedWord(text: "late", start: 4.5, end: 4.7),
            TimedWord(text: "after", start: 9, end: 9.2),
        ]
        let owners = words.map { Assembler.owner(of: $0.start, $0.end, .turns(turns, user: nil, others: .others)) }
        #expect(owners.map(\.cluster) == [0, 1, 1])
    }

    @Test func wordsSpanningTwoTurnsGoToTheLargerOverlap() {
        let turns = [SpeakerTurn(start: 0, end: 1, cluster: 0), SpeakerTurn(start: 1, end: 3, cluster: 1)]
        #expect(Assembler.cluster(of: 0.8, 1.5, in: turns) == 1)
        #expect(Assembler.cluster(of: 0.2, 1.1, in: turns) == 0)
        #expect(Assembler.cluster(of: 0, 1, in: []) == nil)
    }

    @Test func withoutTurnsEverythingGoesToTheOtherSideWithoutVoices() {
        let lines = Assembler.finish(Assembler.lines(from: Self.words("hi there", from: 0), attribution: .turns([], user: nil, others: .others)))
        #expect(lines.map(\.speaker) == [.others])
        #expect(lines.map(\.voice) == [nil])
    }

    @Test func aStrayShortWordDoesNotSplitALine() {
        // "four" (1.2 to 1.52) falls entirely in cluster 1's sliver.
        let turns = [SpeakerTurn(start: 0, end: 1.15, cluster: 0), SpeakerTurn(start: 1.15, end: 1.6, cluster: 1), SpeakerTurn(start: 1.6, end: 3, cluster: 0)]
        let words = Self.words("one two three four five six", from: 0, step: 0.4)
        let lines = Assembler.finish(Assembler.lines(from: words, attribution: .turns(turns, user: nil, others: .others)))
        #expect(lines.map(\.text) == ["one two three four five six"])
        #expect(lines.map(\.voice) == [1])
    }

    @Test func theUserClusterBecomesMeWithoutAVoice() {
        let turns = [SpeakerTurn(start: 0, end: 2, cluster: 0), SpeakerTurn(start: 2, end: 4, cluster: 1), SpeakerTurn(start: 4, end: 6, cluster: 2)]
        let words = Self.words("a b c", from: 0.1) + Self.words("d e f", from: 2.1) + Self.words("g h i", from: 4.1)
        let lines = Assembler.finish(Assembler.lines(from: words, attribution: .turns(turns, user: 1, others: .others)))
        #expect(lines.map(\.speaker) == [.others, .me, .others])
        #expect(lines.map(\.voice) == [1, nil, 2])
    }

    @Test func mergesSidesInTimeOrder() {
        let me = Assembler.lines(from: Self.words("mine.", from: 3), attribution: .speaker(.me))
        let others = Assembler.lines(
            from: Self.words("first.", from: 0) + Self.words("last.", from: 6),
            attribution: .turns([SpeakerTurn(start: 0, end: 1, cluster: 5), SpeakerTurn(start: 6, end: 7, cluster: 2)], user: nil, others: .others))
        let lines = Assembler.finish(me + others)
        #expect(lines.map(\.text) == ["first.", "mine.", "last."])
        #expect(lines.map(\.voice) == [1, nil, 2])
    }

    // MARK: Keeping text

    @Test func keepsALineWholeWhenOneSpeakerSaidIt() {
        let line = TranscriptLine(speaker: .others, start: 0, end: 2, text: "Hello, everyone!")
        let words = [line.id: Self.words("Hello, everyone!", from: 0.1)]
        let lines = Assembler.finish(Assembler.lines(keeping: [line], words: words, attribution: .turns([SpeakerTurn(start: 0, end: 2, cluster: 4)], user: nil, others: .others)))
        #expect(lines.count == 1)
        #expect(lines[0].id == line.id)
        #expect(lines[0].text == "Hello, everyone!")
        #expect(lines[0].start == 0 && lines[0].end == 2)
        #expect(lines[0].voice == 1)
    }

    @Test func splitsAKeptLineWhereTheSpeakerChanges() {
        let line = TranscriptLine(speaker: .others, start: 0, end: 4, text: "yes I agree sounds good to me")
        let lineWords = Self.words("yes I agree sounds good to me", from: 0, step: 0.5)
        let turns = [SpeakerTurn(start: 0, end: 1.5, cluster: 0), SpeakerTurn(start: 1.5, end: 4, cluster: 1)]
        let lines = Assembler.finish(Assembler.lines(keeping: [line], words: [line.id: lineWords], attribution: .turns(turns, user: nil, others: .others)))
        #expect(lines.map(\.text) == ["yes I agree", "sounds good to me"])
        #expect(lines.map(\.voice) == [1, 2])
        #expect(lines[1].start == 1.5)
    }

    @Test func splitsTextWithoutSpacesWithoutAddingSpaces() {
        let line = TranscriptLine(speaker: .others, start: 0, end: 2, text: "はいそうです")
        let lineWords = [TimedWord(text: "はい", start: 0, end: 0.5), TimedWord(text: "そう", start: 1.1, end: 1.5), TimedWord(text: "です", start: 1.5, end: 2)]
        let turns = [SpeakerTurn(start: 0, end: 1, cluster: 0), SpeakerTurn(start: 1, end: 2, cluster: 1)]
        let lines = Assembler.finish(Assembler.lines(keeping: [line], words: [line.id: lineWords], attribution: .turns(turns, user: nil, others: .others)))
        #expect(lines.map(\.text) == ["はい", "そうです"])
    }

    @Test func aLineWithoutWordTimingsGoesToTheLargestOverlap() {
        let line = TranscriptLine(speaker: .others, start: 1, end: 5, text: "no word timings here")
        let turns = [SpeakerTurn(start: 0, end: 2, cluster: 0), SpeakerTurn(start: 2, end: 5, cluster: 1)]
        let lines = Assembler.finish(Assembler.lines(keeping: [line], words: [:], attribution: .turns(turns, user: nil, others: .others)))
        #expect(lines.map(\.text) == ["no word timings here"])
        // Cluster 1 covers more of the line, and is the only voice in the result.
        #expect(lines.map(\.voice) == [1])
        #expect(Assembler.owner(of: 1, 5, .turns(turns, user: nil, others: .others)).cluster == 1)
    }

    @Test func dropsEmptyKeptLines() {
        let line = TranscriptLine(speaker: .me, start: 0, end: 1, text: "  ")
        #expect(Assembler.lines(keeping: [line], words: [:], attribution: .speaker(.me)).isEmpty)
    }

    @Test func existingLinesLendTheirSpeakersToNewWords() {
        let existing = [
            TranscriptLine(speaker: .me, start: 0, end: 2, text: "old mine"),
            TranscriptLine(speaker: .others, start: 3, end: 5, text: "old theirs", voice: 4),
        ]
        let words = Self.words("new mine.", from: 0.5) + Self.words("new theirs.", from: 3.5) + Self.words("far away", from: 20)
        let lines = Assembler.finish(Assembler.lines(from: words, attribution: .lines(existing, fallback: .unknown)))
        #expect(lines.map(\.text) == ["new mine.", "new theirs.", "far away"])
        #expect(lines.map(\.speaker) == [.me, .others, .unknown])
        #expect(lines.map(\.voice) == [nil, 4, nil])
    }

    @Test func newVoicesSkipNumbersThatAreCarriedOver() {
        let carried = Assembler.Draft(owner: .init(speaker: .others, voice: 1), start: 5, end: 6, text: "carried")
        let fresh = Assembler.Draft(owner: .init(speaker: .others, cluster: 0), start: 0, end: 1, text: "fresh")
        #expect(Assembler.finish([carried, fresh]).map(\.voice) == [2, 1])
    }

    // MARK: Finding the user

    static func meLine(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptLine {
        TranscriptLine(speaker: .me, start: start, end: end, text: "me")
    }

    @Test func findsTheUserByOverlapWithTheirLines() {
        let turns = [
            SpeakerTurn(start: 0, end: 5, cluster: 0), SpeakerTurn(start: 5, end: 10, cluster: 1),
            SpeakerTurn(start: 10, end: 15, cluster: 0), SpeakerTurn(start: 15, end: 20, cluster: 2),
        ]
        let lines = [Self.meLine(5.2, 9.8), TranscriptLine(speaker: .others, start: 0, end: 5, text: "x")]
        #expect(Assembler.userCluster(in: turns, lines: lines) == 1)
    }

    @Test func noUserWithoutTheirLines() {
        let turns = [SpeakerTurn(start: 0, end: 5, cluster: 0)]
        #expect(Assembler.userCluster(in: turns, lines: [TranscriptLine(speaker: .unknown, start: 0, end: 5, text: "x")]) == nil)
        #expect(Assembler.userCluster(in: [], lines: [Self.meLine(0, 5)]) == nil)
    }

    @Test func noUserWhenTheOverlapIsTooThin() {
        // Half a second of overlap is not enough to call anyone the user.
        let turns = [SpeakerTurn(start: 0, end: 10, cluster: 0), SpeakerTurn(start: 10, end: 10.5, cluster: 1)]
        #expect(Assembler.userCluster(in: turns, lines: [Self.meLine(10, 10.5), Self.meLine(30, 40)]) == nil)
    }

    @Test func someoneTalkingOverEverythingIsNotTheUser() {
        // Cluster 0 talks for an hour and covers the user's two seconds, but almost none of what
        // cluster 0 says falls on the user's lines.
        let turns = [SpeakerTurn(start: 0, end: 3600, cluster: 0)]
        #expect(Assembler.userCluster(in: turns, lines: [Self.meLine(100, 102)]) == nil)
    }

    @Test func prefersWordTimingsOverLineSpans() {
        // The live line spans a pause in which cluster 0 talked; the words show it was cluster 1.
        let line = Self.meLine(0, 10)
        let words = [line.id: [TimedWord(text: "a", start: 7, end: 8), TimedWord(text: "b", start: 8, end: 10)]]
        let turns = [SpeakerTurn(start: 0, end: 7, cluster: 0), SpeakerTurn(start: 7, end: 10, cluster: 1)]
        #expect(Assembler.userCluster(in: turns, lines: [line]) == 0)
        #expect(Assembler.userCluster(in: turns, lines: [line], words: words) == 1)
    }
}

@Suite("Optional model store")
struct OptionalModelStoreTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MemoirModelStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The layout of a finished diarizer download, with placeholder files.
    static func fakeDiarizer(in directory: URL, marker: Bool) throws -> URL {
        let folder = FluidModels.folder(for: .speakerIdentification, in: directory)
        for bundle in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            let url = folder.appending(path: "\(bundle).mlmodelc", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url.appending(path: "weights"), withIntermediateDirectories: true)
            try Data(count: 4096).write(to: url.appending(path: "coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appending(path: "plda-parameters.json"))
        if marker { try Data().write(to: folder.appending(path: ".memoir-installed")) }
        return folder
    }

    @Test func storesModelsInMemoirsOwnFolder() {
        #expect(FluidModels.directory == RecordingFiles.baseDirectory.appending(path: "Models", directoryHint: .isDirectory))
        #expect(FluidModels.folder(for: .enhancedTranscription, in: FluidModels.directory).lastPathComponent == "parakeet-ultra")
        #expect(FluidModels.folder(for: .speakerIdentification, in: FluidModels.directory).lastPathComponent == "speaker-diarization")
    }

    @Test func nothingIsInstalledInAnEmptyFolder() async throws {
        let store = FluidModelStore(directory: try Self.temporaryDirectory())
        for model in OptionalModel.allCases {
            #expect(await store.isInstalled(model) == false)
            #expect(await store.installedSize(of: model) == nil)
        }
    }

    @Test func aCompleteDownloadCountsOnlyWithTheMarker() async throws {
        let directory = try Self.temporaryDirectory()
        let store = FluidModelStore(directory: directory)
        let folder = try Self.fakeDiarizer(in: directory, marker: false)
        #expect(await store.isInstalled(.speakerIdentification) == false)
        try Data().write(to: folder.appending(path: ".memoir-installed"))
        #expect(await store.isInstalled(.speakerIdentification))
        #expect((await store.installedSize(of: .speakerIdentification) ?? 0) >= 4 * 4096)
        #expect(await store.isInstalled(.enhancedTranscription) == false)
    }

    @Test func aPartialFileMeansNotInstalled() async throws {
        let directory = try Self.temporaryDirectory()
        let folder = try Self.fakeDiarizer(in: directory, marker: true)
        try Data(count: 10).write(to: folder.appending(path: "Embedding.mlmodelc/weights/weight.bin.partial"))
        #expect(await FluidModelStore(directory: directory).isInstalled(.speakerIdentification) == false)
    }

    @Test func aMissingBundleMeansNotInstalled() async throws {
        let directory = try Self.temporaryDirectory()
        let folder = try Self.fakeDiarizer(in: directory, marker: true)
        try FileManager.default.removeItem(at: folder.appending(path: "PldaRho.mlmodelc"))
        #expect(await FluidModelStore(directory: directory).isInstalled(.speakerIdentification) == false)
    }

    @Test func removeDeletesTheFolder() async throws {
        let directory = try Self.temporaryDirectory()
        let store = FluidModelStore(directory: directory)
        let folder = try Self.fakeDiarizer(in: directory, marker: true)
        try await store.remove(.speakerIdentification)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await store.isInstalled(.speakerIdentification) == false)
        try await store.remove(.speakerIdentification)
    }

    @Test func readsThePLDAParameters() throws {
        let directory = try Self.temporaryDirectory()
        let floats: [Float] = [1.5, -2, 0.25]
        let base64 = floats.withUnsafeBytes { Data($0) }.base64EncodedString()
        let url = directory.appending(path: "plda.json")
        try Data(#"{"tensors": {"psi": {"data_base64": "\#(base64)"}}}"#.utf8).write(to: url)
        #expect(try FluidModels.pldaPsi(at: url) == [1.5, -2, 0.25])
        try Data("{}".utf8).write(to: url)
        #expect(throws: OptionalModelError.self) { try FluidModels.pldaPsi(at: url) }
    }

    @Test func enhancementNeedsTheModelsAndNeverDownloads() async throws {
        let enhancer = FluidEnhancer(directory: try Self.temporaryDirectory())
        let line = TranscriptLine(speaker: .others, start: 0, end: 1, text: "hi")
        let request = EnhancementRequest(
            audio: .mixed(URL(fileURLWithPath: "/nonexistent.m4a")), locale: Locale(identifier: "en_US"),
            lines: [line], transcribe: false, identifySpeakers: true)
        await #expect(throws: EnhancementError.self) {
            for try await _ in enhancer.enhance(request) {}
        }
    }

    @Test func supportsTheModelCardLanguagesOnly() {
        let enhancer = FluidEnhancer(directory: FileManager.default.temporaryDirectory)
        for identifier in ["en_US", "en_GB", "de_DE", "fr_FR", "es_MX", "pt_BR", "uk_UA", "mt_MT", "el_GR"] {
            #expect(enhancer.supportsTranscription(in: Locale(identifier: identifier)), "\(identifier)")
        }
        for identifier in ["ja_JP", "zh_CN", "ko_KR", "ar_SA", "tr_TR", "hi_IN", "nb_NO"] {
            #expect(!enhancer.supportsTranscription(in: Locale(identifier: identifier)), "\(identifier)")
        }
        #expect(FluidEnhancer.languages.count == 25)
    }
}

@Suite(
    "Enhancement end to end",
    .serialized,
    .enabled("both optional models are installed") { EnhancementFixture.modelsReady() },
    .timeLimit(.minutes(10))
)
struct EnhancementEndToEndTests {
    static let systemTurns: [(voice: String, text: String)] = [
        ("Daniel", "Good morning everyone. Thanks for joining the weekly planning meeting today."),
        ("Samantha", "Thanks Daniel. I finished the design review yesterday and sent my notes to the team."),
        ("Daniel", "Great work. Can you also look at the budget numbers before Friday afternoon?"),
        ("Samantha", "Of course. I will check the spreadsheet tonight and let you know tomorrow morning."),
    ]
    static let userSentence = "Before we move on, I would like to add one thing about the release date."

    @Test func tracksSplitTheOtherSideIntoTwoVoices() async throws {
        let fixture = try await EnhancementFixture.make(systemTurns: Self.systemTurns, user: ("Ralph", Self.userSentence))
        let request = EnhancementRequest(
            audio: .tracks([.microphone: fixture.microphone, .system: fixture.system]),
            locale: Locale(identifier: "en_US"), lines: [], transcribe: true, identifySpeakers: true)
        let lines = try await EnhancementFixture.run(request, label: "tracks")

        let mine = lines.filter { $0.speaker == .me }
        let theirs = lines.filter { $0.speaker == .others }
        #expect(mine.allSatisfy { $0.voice == nil })
        #expect(mine.map(\.text).joined(separator: " ").lowercased().contains("release date"))
        #expect(Set(theirs.compactMap(\.voice)) == [1, 2])
        #expect(theirs.first?.voice == 1)
        let text = theirs.map(\.text).joined(separator: " ").lowercased()
        for word in ["planning", "design review", "budget", "spreadsheet"] {
            #expect(text.contains(word), "missing \(word)")
        }
        // Daniel opens and the voices alternate with the sentences.
        let byStart = theirs.sorted { $0.start < $1.start }
        let budget = try #require(byStart.first { $0.text.lowercased().contains("budget") })
        let design = try #require(byStart.first { $0.text.lowercased().contains("design") })
        #expect(budget.voice == 1)
        #expect(design.voice == 2)
        #expect(lines == lines.sorted { $0.start < $1.start })
    }

    @Test func keepsTheTextWhenOnlyIdentifyingSpeakers() async throws {
        let fixture = try await EnhancementFixture.make(systemTurns: Self.systemTurns, user: ("Ralph", Self.userSentence))
        let live = fixture.systemTimes.map { TranscriptLine(speaker: .others, start: $0.start, end: $0.end, text: $0.text) }
        let request = EnhancementRequest(
            audio: .tracks([.microphone: fixture.microphone, .system: fixture.system]),
            locale: Locale(identifier: "en_US"), lines: live, transcribe: false, identifySpeakers: true)
        let lines = try await EnhancementFixture.run(request, label: "keep")
        #expect(lines.map(\.text) == live.map(\.text))
        #expect(lines.map(\.voice) == [1, 2, 1, 2])
    }

    @Test func mixedFileFindsTheUser() async throws {
        let fixture = try await EnhancementFixture.make(systemTurns: Self.systemTurns, user: ("Ralph", Self.userSentence))
        let userLine = TranscriptLine(speaker: .me, start: fixture.userTime.start, end: fixture.userTime.end, text: Self.userSentence)
        let request = EnhancementRequest(
            audio: .mixed(fixture.mixed), locale: Locale(identifier: "en_US"),
            lines: [userLine], transcribe: true, identifySpeakers: true)
        let lines = try await EnhancementFixture.run(request, label: "mixed")

        let mine = lines.filter { $0.speaker == .me }
        #expect(!mine.isEmpty)
        #expect(mine.allSatisfy { $0.voice == nil })
        #expect(mine.map(\.text).joined(separator: " ").lowercased().contains("release"))
        #expect(lines.filter { $0.speaker == .others }.allSatisfy { $0.voice != nil })
        #expect(Set(lines.compactMap(\.voice)).count >= 2)
    }
}

nonisolated enum EnhancementFixture {
    struct Audio {
        var microphone: URL
        var system: URL
        var mixed: URL
        var systemTimes: [(start: TimeInterval, end: TimeInterval, text: String)]
        var userTime: (start: TimeInterval, end: TimeInterval)
    }

    static func modelsReady() -> Bool {
        let ready = OptionalModel.allCases.allSatisfy { FluidModels.isInstalled($0, in: FluidModels.directory) }
        if !ready { print("Optional models not installed in \(FluidModels.directory.path), skipping") }
        return ready
    }

    static func run(_ request: EnhancementRequest, label: String) async throws -> [TranscriptLine] {
        let clock = ContinuousClock()
        let began = clock.now
        var lines: [TranscriptLine] = []
        var steps: [String] = []
        for try await progress in FluidEnhancer().enhance(request) {
            switch progress {
            case .transcribing(let fraction): steps.append(String(format: "t%.2f", fraction))
            case .identifyingSpeakers(let fraction): steps.append(String(format: "s%.2f", fraction))
            case .finished(let result): lines = result
            }
        }
        print("[\(label)] finished in \(clock.now - began), progress \(steps.joined(separator: " "))")
        for line in lines {
            print("[\(label)] \(line.speaker.rawValue) \(line.voice.map(String.init) ?? "-") [\(String(format: "%.2f-%.2f", line.start, line.end))] \(line.text)")
        }
        return lines
    }

    static let sampleRate = 16_000.0

    /// The system track alternates the turns with a second of silence between them; the user
    /// speaks once into the microphone after the second turn while the system track is silent.
    static func make(systemTurns: [(voice: String, text: String)], user: (voice: String, text: String)) async throws -> Audio {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MemoirEnhancementTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gap = [Float](repeating: 0, count: Int(sampleRate))

        var system: [Float] = gap
        var microphone: [Float] = gap
        var systemTimes: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        var userTime: (start: TimeInterval, end: TimeInterval) = (0, 0)
        for (index, turn) in systemTurns.enumerated() {
            let samples = try speech(turn.text, voice: turn.voice, in: directory)
            systemTimes.append((Double(system.count) / sampleRate, Double(system.count + samples.count) / sampleRate, turn.text))
            system += samples + gap
            microphone += [Float](repeating: 0, count: samples.count + gap.count)
            if index == 1 {
                let mine = try speech(user.text, voice: user.voice, in: directory)
                userTime = (Double(microphone.count) / sampleRate, Double(microphone.count + mine.count) / sampleRate)
                microphone += mine + gap
                system += [Float](repeating: 0, count: mine.count + gap.count)
            }
        }
        let length = max(system.count, microphone.count)
        system += [Float](repeating: 0, count: length - system.count)
        microphone += [Float](repeating: 0, count: length - microphone.count)

        let systemURL = directory.appending(path: "system.caf")
        let microphoneURL = directory.appending(path: "microphone.caf")
        let mixedURL = directory.appending(path: "audio.m4a")
        try write(system, to: systemURL)
        try write(microphone, to: microphoneURL)
        try writeMixed(zip(system, microphone).map { $0 + $1 }, to: mixedURL)
        return Audio(microphone: microphoneURL, system: systemURL, mixed: mixedURL, systemTimes: systemTimes, userTime: userTime)
    }

    private static func speech(_ text: String, voice: String, in directory: URL) throws -> [Float] {
        let aiff = directory.appending(path: "\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", aiff.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try read(aiff)
    }

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// 16 kHz mono CAF, like the recorder's per-source tracks.
    private static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer(samples, format: format))
    }

    /// 48 kHz mono AAC, like the recorder's mixdown.
    private static func writeMixed(_ samples: [Float], to url: URL) throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try #require(AVAudioConverter(from: source, to: target))
        let input = buffer(samples, format: source)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count * 3 + 1024))!
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: output)
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
