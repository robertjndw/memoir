import Foundation
@testable import Memoir

nonisolated enum IntelligenceFixtures {
    static func lines(_ script: [(Speaker, String)], startingAt offset: TimeInterval = 0) -> [TranscriptLine] {
        var time = offset
        return script.map { speaker, text in
            // Conversational pace with pauses between turns.
            let words = Double(text.split(separator: " ").count)
            let duration = max(1.5, words / 2.1)
            defer { time += duration + 2.5 }
            return TranscriptLine(speaker: speaker, start: time, end: time + duration, text: text)
        }
    }

    /// About ten minutes: the user (Sam) and Priya plan a delayed mobile release.
    static let releaseMeeting: [(Speaker, String)] = [
        (.me, "Hey Priya, thanks for jumping on. I wanted to go through where we are with the Fieldnote 2.3 release before the end of the week."),
        (.others, "Sure, yeah. I have the QA report open, so I can walk you through that first if you like."),
        (.me, "Please do. Last time we talked the plan was still to ship on May 6th, right?"),
        (.others, "Right, May 6th was the plan. But the Android build has a crash that shows up when people attach photos from the gallery on older Samsung phones."),
        (.me, "How bad is it? Is that a few users or is that something a lot of people would hit?"),
        (.others, "From the beta it is about 4 percent of Android sessions that attach a photo. So not huge, but the people who hit it lose the note they were writing, which is pretty painful."),
        (.me, "Yeah, losing the note is the worst case. Do we know what is causing it?"),
        (.others, "Marco thinks it is the image downscaling library running out of memory on large HEIC files. He has a fix in review, but it touches the whole attachment pipeline."),
        (.me, "So realistically the fix needs another round of QA."),
        (.others, "Exactly. QA said they need at least four working days once the fix is merged. If Marco merges tomorrow, that gets us to roughly the 12th."),
        (.me, "Okay. And iOS is fine?"),
        (.others, "iOS is fine. Crash free sessions are at 99.8 percent on the beta. The only open iOS issue is a layout glitch on the iPad settings screen, and that one is cosmetic."),
        (.me, "Could we ship iOS on the 6th and Android a week later?"),
        (.others, "We could, but marketing really wants one announcement. Daniel was pretty clear that a split launch makes the blog post and the newsletter awkward."),
        (.me, "Right, I remember that conversation. Honestly I would rather move the whole thing by a week than ship something that eats people's notes."),
        (.others, "I agree. So we move the launch to May 13th for both platforms?"),
        (.me, "Yes, let's do that. May 13th, both platforms together. I will tell Daniel today so marketing can adjust the newsletter."),
        (.others, "Great. That also gives me time to finish the release notes properly instead of rushing them."),
        (.me, "When could you have a draft of the release notes?"),
        (.others, "I can have a draft by Thursday. I will put it in the shared doc and tag you."),
        (.me, "Perfect. Then the other thing I wanted to talk about is the beta feedback on the new search."),
        (.others, "Yeah, that was mostly positive. People love that search now finds text inside photos. The main complaint is that results are sorted by date instead of relevance."),
        (.me, "Is relevance sorting a big change?"),
        (.others, "Not for 2.3. Marco estimated two to three weeks because the index needs a ranking score. I would put it in 2.4."),
        (.me, "Agreed, that goes into 2.4. We should not add scope now that we are already slipping a week."),
        (.others, "Exactly. I will add it to the 2.4 board with the beta quotes so we do not lose the context."),
        (.me, "Good. Anything else from the beta?"),
        (.others, "A few people asked for a dark mode app icon, and two people reported that the export to PDF cuts off long tables."),
        (.me, "The PDF thing sounds like a real bug. Is that in 2.3?"),
        (.others, "It was introduced in 2.2, so it is already in production. Marco says it is a small fix, maybe half a day."),
        (.me, "Then let's include the PDF table fix in 2.3 if it really is half a day. But only if it does not delay QA."),
        (.others, "Okay. I will ask Marco to do it right after the crash fix and check with QA whether they can test both together."),
        (.me, "And the dark mode icon can wait. That is nice to have."),
        (.others, "Sure, I will park that one."),
        (.me, "One more topic. The user research budget for next quarter. Finance asked me how much we need."),
        (.others, "Last quarter we spent about 3,000 dollars on interview incentives. With the tablet study I would ask for 4,500."),
        (.me, "4,500 sounds reasonable. I will put that in the budget request, but I cannot promise finance approves the full amount."),
        (.others, "Understood. If they cut it, the tablet study is the first thing I would drop."),
        (.me, "Okay, good to know. Let me write that down as the fallback."),
        (.others, "Also, small thing, the App Store screenshots still show the old search screen. Someone should update them before the launch."),
        (.me, "Good catch. Can design do that?"),
        (.others, "I think Lena has capacity. I can ask her, but you might need to approve the time since she is on the website project."),
        (.me, "I will approve it. Ask her and tell her the deadline is May 10th, so we have a few days of buffer."),
        (.others, "Will do."),
        (.me, "So to recap: launch moves to May 13th for both platforms, Marco fixes the crash and the PDF tables, you write the release notes by Thursday, and I talk to Daniel and finance."),
        (.others, "And I ask Lena about the screenshots."),
        (.me, "Right, and Lena with the screenshots by May 10th. Anything I missed?"),
        (.others, "No, I think that is everything. I will send the QA report to you after this call."),
        (.me, "Great, thanks Priya. Talk tomorrow at standup."),
        (.others, "Thanks, bye."),
    ]

    /// Further topics for a long, roughly hour-long meeting that forces map-reduce.
    static let hiringSegment: [(Speaker, String)] = [
        (.me, "Okay, next topic is hiring. We still have the senior Android engineer role open."),
        (.others, "Right. We had six candidates in the pipeline, two of them made it to the final round."),
        (.me, "Who were the two finalists again?"),
        (.others, "Tomasz, who currently works at a bank on their mobile app, and Aiko, who was at a startup doing offline sync."),
        (.me, "I liked Aiko's system design interview a lot. She went deep on conflict resolution."),
        (.others, "Same. Marco also preferred Aiko. Tomasz was strong on testing but weaker on architecture."),
        (.me, "What is Aiko's salary expectation?"),
        (.others, "She asked for 145,000, which is a bit above our band. The top of the band is 140,000."),
        (.me, "I think we can go to 140,000 plus a signing bonus. I will ask HR whether a 5,000 dollar signing bonus is possible."),
        (.others, "That would probably work. She mentioned that the start date matters more to her, she wants to start in June."),
        (.me, "June is fine with me. So we make Aiko an offer at 140,000, and I check the signing bonus with HR."),
        (.others, "Sounds good. I will tell Tomasz we went with someone else, but I want to keep him in mind for the backend role."),
        (.me, "Good idea. He seemed like a good engineer, just not the right fit for this role."),
        (.others, "Should we also restart the search for the designer role? It has been on hold since February."),
        (.me, "Not yet. The budget for the designer role depends on the Q3 planning, so let's wait until July."),
        (.others, "Okay, I will leave it on hold."),
    ]

    static let customerSegment: [(Speaker, String)] = [
        (.others, "Can we talk about the Acme Logistics escalation? Their account manager called me yesterday."),
        (.me, "Yes, what happened? I only saw the subject line of the email."),
        (.others, "Their field team uses Fieldnote on about 300 devices, and since last Tuesday sync has been failing for roughly a third of them."),
        (.me, "A third of their devices? That is a lot. Do we know why?"),
        (.others, "The sync server logs show timeouts. Their notes have very large attachments, some over 200 megabytes, because they record video of warehouse inspections."),
        (.me, "We never really designed for attachments that big."),
        (.others, "No. Marco suggested we add resumable uploads, but that is a bigger project. As a short term fix we can raise the server timeout from 60 to 300 seconds."),
        (.me, "Let's do the timeout change right away. Who can deploy that?"),
        (.others, "Jonas from the backend team. He said he can do it tomorrow morning."),
        (.me, "Good. And resumable uploads should go on the roadmap discussion for Q3."),
        (.others, "Agreed. Acme also asked for a credit for the outage. They are on the enterprise plan at about 9,000 dollars a month."),
        (.me, "I do not want to decide on credits myself. I will bring that to Karen in account management, she owns those decisions."),
        (.others, "Fair. I told them we would get back to them by Friday."),
        (.me, "Okay, I will make sure Karen replies by Friday then."),
    ]

    static let roadmapSegment: [(Speaker, String)] = [
        (.me, "Last big topic, the Q3 roadmap. We have to submit a first draft to leadership by May 20th."),
        (.others, "I started a list. The top candidates are relevance sorting in search, resumable uploads, the tablet layout, and the Windows desktop app."),
        (.me, "The Windows app keeps coming up, but I am not convinced we have the people for it."),
        (.others, "Me neither. It would need at least two engineers for a full quarter. I would rather do the tablet layout, since the research shows tablet usage grew 40 percent this year."),
        (.me, "That is a strong number. Where did that come from?"),
        (.others, "From our analytics, comparing March this year with March last year. I can put the chart in the roadmap doc."),
        (.me, "Please do. My gut says the Q3 list is relevance sorting, resumable uploads and the tablet layout, and the Windows app gets pushed to Q4 at the earliest."),
        (.others, "I agree with that order. Resumable uploads might even jump to first place because of Acme."),
        (.me, "Let's not decide the order today. I want to see the effort estimates first."),
        (.others, "Okay. I will ask Marco and Jonas for rough estimates by next Wednesday."),
        (.me, "Great. And I will write the narrative part of the roadmap doc once we have the estimates."),
        (.others, "Sounds like a plan."),
    ]

    static let smallTalkSegment: [(Speaker, String)] = [
        (.others, "Before we wrap up, did you see that the office move got pushed again?"),
        (.me, "I heard rumors. What is the new date?"),
        (.others, "Facilities said end of August now, because the new floor still needs network cabling."),
        (.me, "That is the third delay. At least it does not affect the launch."),
        (.others, "True. Oh, and the team offsite is confirmed for June 18th in Lisbon."),
        (.me, "Nice, I need to book flights then. Do we have a budget per person?"),
        (.others, "I think it is 800 euros for travel, but check with Hannah, she organizes it."),
        (.me, "Will do."),
    ]

    static var longMeeting: [TranscriptLine] {
        let segments = [releaseMeeting, hiringSegment, customerSegment, roadmapSegment, smallTalkSegment]
        var lines: [TranscriptLine] = []
        var offset: TimeInterval = 0
        for segment in segments {
            let part = Self.lines(segment, startingAt: offset)
            lines += part
            offset = (part.last?.end ?? offset) + 30
        }
        return lines
    }

    // MARK: Corpus

    nonisolated struct FakeCorpus: TranscriptCorpus {
        var digests: [MeetingDigest]
        var transcripts: [UUID: [TranscriptLine]]

        func meetings() async -> [MeetingDigest] { digests }
        func lines(of meetingID: UUID) async -> [TranscriptLine] { transcripts[meetingID] ?? [] }
    }

    static let releaseID = UUID()
    static let hiringID = UUID()
    static let customerID = UUID()

    static func corpus(now: Date = .now) -> FakeCorpus {
        let day: TimeInterval = 86_400
        let release = lines(releaseMeeting)
        let hiring = lines(hiringSegment)
        let customer = lines(customerSegment + roadmapSegment)
        return FakeCorpus(
            digests: [
                MeetingDigest(
                    id: releaseID,
                    title: "Fieldnote 2.3 release planning",
                    date: now.addingTimeInterval(-2 * day),
                    duration: release.last?.end ?? 600,
                    attendees: ["Priya Nair"],
                    summary: MeetingSummary(
                        title: "Fieldnote 2.3 release planning",
                        overview: "Sam and Priya moved the Fieldnote 2.3 launch from May 6 to May 13 because of an Android photo attachment crash.",
                        keyPoints: ["Android crash affects 4 percent of photo sessions.", "Relevance sorting moves to 2.4."],
                        decisions: ["Launch moves to May 13 on both platforms."],
                        actionItems: [.init(task: "Draft release notes by Thursday", owner: "Priya")]
                    )
                ),
                MeetingDigest(
                    id: hiringID,
                    title: "Android hiring sync",
                    date: now.addingTimeInterval(-9 * day),
                    duration: hiring.last?.end ?? 300,
                    attendees: ["Priya Nair"],
                    summary: nil
                ),
                MeetingDigest(
                    id: customerID,
                    title: "Acme escalation and Q3 roadmap",
                    date: now.addingTimeInterval(-20 * day),
                    duration: customer.last?.end ?? 600,
                    attendees: ["Priya Nair", "Jonas Weber"],
                    summary: nil
                ),
            ],
            transcripts: [releaseID: release, hiringID: hiring, customerID: customer]
        )
    }
}
