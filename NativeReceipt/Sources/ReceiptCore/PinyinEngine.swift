import Foundation

public struct PinyinCandidate: Sendable, Equatable, Identifiable {
    public let text: String
    public let consumed: Int
    public var id: String { "\(consumed):\(text)" }
}

/// Local, immutable dictionary. No network, system IME, timers or user-text logs.
public struct PinyinEngine: Sendable {
    private struct Entry: Sendable {
        let text: String
        let frequency: Int
        let boundaries: Set<Int>
    }
    private struct Ranked {
        let candidate: PinyinCandidate
        let rank: Int
        let matched: Int
        let frequency: Int
    }
    private let dictionary: [String: [Entry]]
    private let codes: [String]
    public let entryCount: Int
    public static let shared: PinyinEngine = {
        let text = Bundle.module.url(forResource: "pinyin", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return PinyinEngine(tsv: text)
    }()

    init(tsv: String) {
        var dictionary: [String: [Entry]] = [:]
        var count = 0
        for line in tsv.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count == 3, let frequency = Int(columns[2]) else { continue }
            let syllables = columns[0].split(separator: " ")
            let code = syllables.joined()
            var total = 0, boundaries = Set<Int>()
            for syllable in syllables.dropLast() { total += syllable.count; boundaries.insert(total) }
            dictionary[code, default: []].append(Entry(text: String(columns[1]), frequency: frequency, boundaries: boundaries))
            count += 1
        }
        self.dictionary = dictionary; self.codes = dictionary.keys.sorted(); self.entryCount = count
    }

    public func candidates(_ composition: String) -> [PinyinCandidate] {
        guard !composition.isEmpty, composition.count <= 48,
              composition.allSatisfy({ "abcdefghijklmnopqrstuvwxyz'".contains($0) }) else { return [] }
        let raw = Array(composition)
        let code = composition.replacingOccurrences(of: "'", with: "")
        guard !code.isEmpty else { return [] }
        var boundaries = Set<Int>(), letters = 0
        for c in raw { if c == "'" { boundaries.insert(letters) } else { letters += 1 } }
        func compatible(_ entry: Entry, used: Int) -> Bool {
            boundaries.filter { $0 > 0 && $0 < used }.isSubset(of: entry.boundaries)
        }
        func consumed(_ used: Int) -> Int {
            var letters = 0, index = 0
            while index < raw.count && letters < used {
                if raw[index] != "'" { letters += 1 }; index += 1
            }
            while index < raw.count && raw[index] == "'" { index += 1 }
            return index
        }
        var matches: [Ranked] = []
        // Exact whole words first; shorter valid prefixes can be selected to
        // continue composing a sentence without discarding the unchosen suffix.
        for length in stride(from: code.count, through: 1, by: -1) {
            let prefix = String(code.prefix(length))
            for entry in dictionary[prefix] ?? [] where compatible(entry, used: length) {
                matches.append(Ranked(candidate: PinyinCandidate(text: entry.text, consumed: consumed(length)),
                    rank: length == code.count ? 0 : 2, matched: length, frequency: entry.frequency))
            }
        }
        // Bounded prefix completion helps while entering a word. Finishing its
        // spelling always exposes every exact candidate, including rare names.
        if code.count >= 2, !composition.hasSuffix("'") {
            var low = 0, high = codes.count
            while low < high { let mid = (low + high) / 2; if codes[mid] < code { low = mid + 1 } else { high = mid } }
            var predicted: [Ranked] = []
            for index in low..<min(codes.count, low + 256) {
                let key = codes[index]
                guard key.hasPrefix(code) else { break }
                guard key != code else { continue }
                for entry in dictionary[key] ?? [] where compatible(entry, used: code.count + 1) {
                    predicted.append(Ranked(candidate: PinyinCandidate(text: entry.text, consumed: raw.count), rank: 1, matched: code.count, frequency: entry.frequency))
                }
            }
            matches.append(contentsOf: predicted.sorted { $0.frequency > $1.frequency }.prefix(24))
        }
        matches.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.matched != $1.matched { return $0.matched > $1.matched }
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            return $0.candidate.text < $1.candidate.text
        }
        var seen = Set<String>()
        return matches.compactMap { seen.insert($0.candidate.id).inserted ? $0.candidate : nil }
    }
}

public enum ReceiptKeyboardMode: String, Sendable { case pinyin, english, numbers }
