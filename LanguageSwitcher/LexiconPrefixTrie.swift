import Foundation

/// Prefix tree: each node holds the max prefix-lexicon score among words in its subtree (O(|p|) lookup).
final class LexiconPrefixTrie {
    private final class Node {
        var maxScore: Double = 0
        var child: [Character: Node] = [:]
    }

    private let root = Node()

    func insert(path: String, score: Double) {
        guard !path.isEmpty else { return }
        var n = root
        n.maxScore = max(n.maxScore, score)
        for ch in path {
            let next = n.child[ch] ?? Node()
            n.child[ch] = next
            next.maxScore = max(next.maxScore, score)
            n = next
        }
    }

    func maxScore(prefix: String) -> Double {
        var n = root
        for ch in prefix {
            guard let nx = n.child[ch] else { return 0 }
            n = nx
        }
        return n.maxScore
    }
}
