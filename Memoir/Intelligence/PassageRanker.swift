import Foundation

/// Pure scoring for retrieval: keyword overlap weighted by inverse document frequency,
/// optionally blended with sentence-embedding similarity.
nonisolated enum PassageRanker {
    nonisolated struct Hit: Sendable, Equatable {
        var index: Int
        var score: Double
    }

    /// Weight of semantic similarity when embeddings exist. Keyword overlap keeps exact names,
    /// numbers and jargon (which sentence embeddings blur) from being outranked.
    static let semanticWeight = 0.6

    /// Lowercased, diacritic-folded word terms without stopwords. Numbers are kept since
    /// dates, amounts and versions are often what people search for.
    static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { term in
                guard !stopwords.contains(term) else { return false }
                return term.count >= 2 || term.allSatisfy(\.isNumber)
            }
    }

    /// Smoothed inverse document frequency for every term in the collection.
    static func inverseDocumentFrequency(_ documents: [[String]]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { counts[term, default: 0] += 1 }
        }
        let total = Double(documents.count)
        return counts.mapValues { log((total + 1) / (Double($0) + 0.5)) }
    }

    /// Fraction (0...1) of the query's IDF mass that the passage covers. Terms match exactly or
    /// by a shared prefix of at least five characters, a cheap stand-in for stemming that
    /// works across the languages the speech engine supports ("deploy" vs "deployment").
    static func keywordScore(query: [String], passage: [String], idf: [String: Double]) -> Double {
        let queryTerms = Set(query)
        guard !queryTerms.isEmpty else { return 0 }
        let passageTerms = Set(passage)
        let fallbackWeight = idf.values.max() ?? 1
        var matched = 0.0
        var total = 0.0
        for term in queryTerms {
            let weight = max(idf[term] ?? fallbackWeight, 0.1)
            total += weight
            if passageTerms.contains(term) || passageTerms.contains(where: { sharesStem($0, term) }) {
                matched += weight
            }
        }
        return total > 0 ? matched / total : 0
    }

    static func sharesStem(_ a: String, _ b: String) -> Bool {
        let shorter = min(a.count, b.count)
        guard shorter >= 5 else { return false }
        return a.commonPrefix(with: b).count >= max(5, shorter - 4)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    static func combinedScore(keyword: Double, semantic: Double?) -> Double {
        guard let semantic else { return keyword }
        return semanticWeight * max(0, semantic) + (1 - semanticWeight) * keyword
    }

    /// Ranks passages for a query, best first. `passageVectors` must be empty (keyword only)
    /// or parallel to `passages`; a nil vector falls back to keyword scoring for that passage.
    static func rank(
        query: String,
        passages: [String],
        queryVector: [Double]? = nil,
        passageVectors: [[Double]?] = []
    ) -> [Hit] {
        let queryTerms = terms(query)
        let passageTerms = passages.map(terms)
        let idf = inverseDocumentFrequency(passageTerms)
        let useVectors = queryVector != nil && passageVectors.count == passages.count
        let hits = passages.indices.map { index in
            let keyword = keywordScore(query: queryTerms, passage: passageTerms[index], idf: idf)
            var semantic: Double?
            if useVectors, let queryVector, let vector = passageVectors[index] {
                semantic = cosine(queryVector, vector)
            }
            return Hit(index: index, score: combinedScore(keyword: keyword, semantic: semantic))
        }
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    }

    /// Expands each hit position into `radius` neighbors on both sides, clamped to `0..<count`,
    /// and merges windows that touch or overlap. Returned in chronological order.
    static func contextWindows(around positions: [Int], radius: Int, count: Int) -> [ClosedRange<Int>] {
        guard count > 0 else { return [] }
        let windows = positions
            .filter { (0..<count).contains($0) }
            .map { max(0, $0 - radius)...min(count - 1, $0 + radius) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for window in windows {
            if let last = merged.last, window.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// Common function words in the languages people most often record in. Without these,
    /// "what did they say about the budget" matches every line containing "they" and "say".
    static let stopwords = Set<String>(stopwordList)

    // An array, not a Set literal: the per-language lists overlap ("so", "was", "des") and a
    // Set literal with duplicates traps at runtime.
    private static let stopwordList: [String] = [
        // English
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "with",
        "about", "from", "as", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "it", "its", "this", "that", "these", "those", "there", "here", "what",
        "which", "who", "whom", "when", "where", "why", "how", "i", "you", "he", "she", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "our", "their", "so", "not", "no", "yes",
        "can", "could", "would", "should", "will", "just", "any", "all", "some", "into", "than",
        "then", "also", "too", "very", "say", "said", "tell", "told", "talk", "talked", "mention",
        "mentioned", "meeting", "anything", "something", "like", "um", "uh", "yeah", "okay", "ok",
        "get", "got", "go", "going", "know", "think", "really", "right", "well", "oh",
        // German
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und",
        "oder", "aber", "ist", "sind", "war", "waren", "wir", "ihr", "sie", "er", "es", "ich", "du",
        "zu", "im", "mit", "von", "auf", "fur", "nicht", "auch", "noch", "wie", "was", "wer", "wann",
        "wo", "warum", "dass", "hat", "haben", "hatte", "uber", "bei", "aus", "nach", "so", "ja", "nein",
        // French and Spanish
        "le", "la", "les", "un", "une", "des", "et", "ou", "est", "sont", "nous", "vous", "ils", "elle",
        "de", "du", "en", "que", "qui", "pour", "pas", "el", "los", "las", "una", "unos", "y", "es",
        "por", "para", "con", "se", "lo", "su",
    ]
}
