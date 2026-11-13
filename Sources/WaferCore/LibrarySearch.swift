import Foundation

public enum LibrarySearch {
    public struct FileMatch: Equatable, Sendable {
        public let file: LibraryFile
        public let matchedAnchorID: String?
        public let snippet: String
        public let score: Int

        public init(file: LibraryFile, matchedAnchorID: String?, snippet: String, score: Int) {
            self.file = file
            self.matchedAnchorID = matchedAnchorID
            self.snippet = snippet
            self.score = score
        }
    }

    public static func fullTextMatches(
        query: String, in files: [LibraryFile], includesSnippets: Bool = true,
        cancellation: WorkCancellation? = nil
    ) -> [FileMatch] {
        let tokens = query.searchTokens
        guard !tokens.isEmpty else {
            return []
        }
        let foldedQuery = tokens.joined(separator: " ")

        return files.compactMap { file -> FileMatch? in
            guard cancellation?.isCancelled != true else { return nil }
            let searchableFields = file.searchFields
            guard tokens.allSatisfy({ searchableFields.contains($0) }) else {
                return nil
            }

            let headingMatch = bestHeadingMatch(tokens: tokens, in: file.outlineItems, foldedTitles: searchableFields.headings)
            let score: Int
            if searchableFields.filename.hasPrefix(foldedQuery) {
                score = 50_000 + max(0, 1_000 - searchableFields.relativePath.count)
            } else if tokens.allSatisfy({ searchableFields.filename.contains($0) || searchableFields.relativePath.contains($0) }) {
                score = 40_000 + max(0, 1_000 - searchableFields.relativePath.count)
            } else if tokens.allSatisfy({ searchableFields.title.contains($0) }) {
                score = 30_000 + searchableFields.bodyMatchCount(tokens: tokens)
            } else if let headingMatch {
                score = 20_000 + (headingMatch.matchedTokenCount * 100) - headingMatch.index
            } else {
                score = 10_000 + searchableFields.bodyMatchCount(tokens: tokens)
            }

            return FileMatch(
                file: file,
                matchedAnchorID: headingMatch?.item.anchorID,
                snippet: includesSnippets ? snippet(for: tokens, in: searchableFields.plainText) : "",
                score: score
            )
        }
        .sorted(by: fileMatchOrder)
    }

    public static func quickOpenMatches(query: String, in files: [LibraryFile], cancellation: WorkCancellation? = nil) -> [LibraryFile] {
        let foldedQuery = query.libraryFoldedSearchText.replacingOccurrences(of: " ", with: "")
        guard !foldedQuery.isEmpty else {
            return []
        }

        let queryCharacters = Array(foldedQuery)
        return files.compactMap { file -> QuickOpenCandidate? in
            guard cancellation?.isCancelled != true,
                  let score = quickOpenScore(query: queryCharacters, file: file) else {
                return nil
            }
            return QuickOpenCandidate(file: file, score: score)
        }
        .sorted(by: quickOpenCandidateOrder)
        .prefix(50)
        .map(\.file)
    }

    private static func bestHeadingMatch(tokens: [String], in items: [DocumentOutlineItem], foldedTitles: [String]) -> HeadingMatch? {
        items.enumerated().compactMap { index, item -> HeadingMatch? in
            let title = foldedTitles[index]
            let matchedTokenCount = tokens.filter { title.contains($0) }.count
            guard matchedTokenCount > 0 else {
                return nil
            }
            return HeadingMatch(item: item, index: index, matchedTokenCount: matchedTokenCount)
        }
        .max { lhs, rhs in
            if lhs.matchedTokenCount != rhs.matchedTokenCount {
                return lhs.matchedTokenCount < rhs.matchedTokenCount
            }
            if lhs.index != rhs.index {
                return lhs.index > rhs.index
            }
            return lhs.item.level > rhs.item.level
        }
    }

    public static func snippet(query: String, in file: LibraryFile) -> String {
        snippet(for: query.searchTokens, in: file.searchFields.plainText)
    }

    private static func snippet(for tokens: [String], in plainText: String) -> String {
        let collapsed = plainText
        guard !collapsed.isEmpty else {
            return ""
        }

        let matchRange = tokens.compactMap {
            collapsed.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }
        .min { lhs, rhs in lhs.lowerBound < rhs.lowerBound }

        guard let matchRange else {
            return ""
        }

        let start = collapsed.index(matchRange.lowerBound, offsetBy: -60, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(matchRange.upperBound, offsetBy: 60, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var snippet = String(collapsed[start..<end]).collapsingWhitespace
        if start > collapsed.startIndex {
            snippet = "..." + snippet
        }
        if end < collapsed.endIndex {
            snippet += "..."
        }
        if snippet.count > 140 {
            let endIndex = snippet.index(snippet.startIndex, offsetBy: 140)
            snippet = snippet[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return snippet
    }

    private static func quickOpenScore(query: [Character], file: LibraryFile) -> Int? {
        [quickOpenScore(query: query, characters: file.searchFields.quickPath),
         quickOpenScore(query: query, characters: file.searchFields.quickName)]
            .compactMap { $0 }.max()
    }

    private static func quickOpenScore(query queryCharacters: [Character], characters: [QuickOpenCharacter]) -> Int? {
        guard !queryCharacters.isEmpty else {
            return nil
        }

        var queryIndex = 0
        var matchedIndexes: [Int] = []
        for (index, character) in characters.enumerated() where character.folded == queryCharacters[queryIndex] {
            matchedIndexes.append(index)
            queryIndex += 1
            if queryIndex == queryCharacters.count {
                break
            }
        }
        guard queryIndex == queryCharacters.count else {
            return nil
        }

        var score = 1_000 - characters.count
        var previousIndex: Int?
        for index in matchedIndexes {
            if index == 0 {
                score += 40
            }
            if isWordBoundary(at: index, in: characters) {
                score += 30
            }
            if let previousIndex, index == previousIndex + 1 {
                score += 20
            }
            previousIndex = index
        }
        return score
    }

    static func quickOpenCharacters(for candidate: String) -> [QuickOpenCharacter] {
        candidate.compactMap { original -> QuickOpenCharacter? in
            let folded = String(original)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
            guard let foldedCharacter = folded.first, !foldedCharacter.isWhitespace else {
                return nil
            }
            return QuickOpenCharacter(folded: foldedCharacter, original: original)
        }
    }

    private static func isWordBoundary(at index: Int, in characters: [QuickOpenCharacter]) -> Bool {
        guard index > 0, index < characters.count else {
            return index == 0
        }

        let previous = characters[index - 1].original
        let current = characters[index].original
        if !previous.isLetterOrNumber {
            return true
        }

        return previous.isLowercaseLetter && current.isUppercaseLetter
    }

    private static func fileMatchOrder(lhs: FileMatch, rhs: FileMatch) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath) == .orderedAscending
    }

    private static func quickOpenCandidateOrder(lhs: QuickOpenCandidate, rhs: QuickOpenCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.file.relativePath.count != rhs.file.relativePath.count {
            return lhs.file.relativePath.count < rhs.file.relativePath.count
        }
        return lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath) == .orderedAscending
    }
}

struct LibrarySearchFields: Equatable, Sendable {
    let filename: String
    let relativePath: String
    let title: String
    let body: String
    let plainText: String
    let headings: [String]
    let quickPath: [QuickOpenCharacter]
    let quickName: [QuickOpenCharacter]
    private let bodyWordCounts: [String: Int]

    init(fileURL: URL, relativePath: String, title: String, headings: [DocumentOutlineItem], plainText: String, body: String) {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        self.filename = filename.libraryFoldedSearchText
        self.relativePath = relativePath.libraryFoldedSearchText
        self.title = title.libraryFoldedSearchText
        self.body = body
        self.plainText = plainText.collapsingWhitespace
        self.headings = headings.map { $0.title.libraryFoldedSearchText }
        self.quickPath = LibrarySearch.quickOpenCharacters(for: relativePath)
        self.quickName = LibrarySearch.quickOpenCharacters(for: filename)
        var counts: [String: Int] = [:]
        for word in body.split(separator: " ") { counts[String(word), default: 0] += 1 }
        self.bodyWordCounts = counts
    }

    func bodyMatchCount(tokens: [String]) -> Int {
        tokens.reduce(0) { total, token in
            total + bodyWordCounts.reduce(0) { $0 + $1.key.matchCount(of: token) * $1.value }
        }
    }

    func contains(_ token: String) -> Bool {
        filename.contains(token)
            || relativePath.contains(token)
            || title.contains(token)
            || body.contains(token)
            || headings.contains { $0.contains(token) }
    }
}

private struct HeadingMatch {
    let item: DocumentOutlineItem
    let index: Int
    let matchedTokenCount: Int
}

private struct QuickOpenCandidate {
    let file: LibraryFile
    let score: Int
}

struct QuickOpenCharacter: Equatable, Sendable {
    let folded: Character
    let original: Character
}

private extension String {
    var searchTokens: [String] {
        libraryFoldedSearchText
            .split(separator: " ")
            .map(String.init)
    }

    func matchCount(of token: String) -> Int {
        guard !token.isEmpty else {
            return 0
        }

        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: token, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    var isLowercaseLetter: Bool {
        String(self).rangeOfCharacter(from: .lowercaseLetters) != nil
    }

    var isUppercaseLetter: Bool {
        String(self).rangeOfCharacter(from: .uppercaseLetters) != nil
    }
}
