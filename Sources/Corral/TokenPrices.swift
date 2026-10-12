import Foundation

/// What each kind of token costs, as a multiple of the same model's fresh
/// input.
///
/// Ratios rather than prices, for two reasons. Nobody running these agents on
/// a subscription pays per token, so a dollar figure would describe a bill
/// that does not exist; and the ratios are what the token history needs to
/// say how much of a pile of tokens actually cost anything. On the session
/// this was written against, 5.05 billion tokens cost what 423 million read
/// at full price would have — 8% — because nearly all of them were cache
/// reads.
///
/// The table is the vendors' published list prices, standard tier, and it has
/// to be kept: Anthropic cut cache reads to 0.05× on Opus 5.5 and to 0.025× on
/// Fable 5.1, and OpenAI's output multiple runs from 5× to 8× depending on the
/// model. A model that is not in it is *unpriced* — its tokens are counted and
/// drawn, and no share of cost is claimed for them — rather than guessed at
/// from its family, because the newest models are exactly the ones whose
/// prices broke the family pattern.
struct TokenPrice: Equatable {
    var cacheRead: Double
    /// Anthropic charges 1.25× for an entry kept five minutes and 2× for one
    /// kept an hour. OpenAI does not charge for writing at all.
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var output: Double

    /// What a turn cost, counted in fresh-input tokens: the number of tokens
    /// that, read at full price, would have cost the same.
    func fullPrice(
        input: Int, write5m: Int, write1h: Int, cacheRead read: Int, output produced: Int
    ) -> Double {
        Double(input)
            + Double(write5m) * cacheWrite5m
            + Double(write1h) * cacheWrite1h
            + Double(read) * cacheRead
            + Double(produced) * output
    }

    /// The price of a model, by the name its tool wrote down.
    ///
    /// Claude Code writes `claude-opus-5-5`, sometimes with a `[1m]` context
    /// marker or a release date after it; both are taken off before looking,
    /// since neither changes the price. Everything else must match exactly.
    static func of(_ model: String) -> TokenPrice? {
        var name = model.lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let dash = name.lastIndex(of: "-"),
           name[name.index(after: dash)...].count == 8,
           name[name.index(after: dash)...].allSatisfy(\.isNumber) {
            name = String(name[..<dash])
        }
        return anthropic[name] ?? openAI[name]
    }

    // ─ Anthropic ────────────────────────────────────────────────────────────
    //
    // Output is five times input on every Claude model; writes are 1.25× for
    // the five-minute entry and 2× for the hour. Only the cache read moved.

    private static func claude(read: Double = 0.1) -> TokenPrice {
        TokenPrice(cacheRead: read, cacheWrite5m: 1.25, cacheWrite1h: 2, output: 5)
    }

    private static let anthropic: [String: TokenPrice] = [
        "claude-fable-5-1": claude(read: 0.025),
        "claude-mythos-5-1": claude(read: 0.025),
        "claude-fable-5": claude(),
        "claude-mythos-5": claude(),
        "claude-opus-5-5": claude(read: 0.05),
        "claude-opus-5": claude(),
        "claude-sonnet-5-5": claude(),
        "claude-sonnet-5": claude(),
        "claude-opus-4-8": claude(),
        "claude-opus-4-7": claude(),
        "claude-opus-4-6": claude(),
        "claude-opus-4-5": claude(),
        "claude-opus-4-1": claude(),
        "claude-opus-4": claude(),
        "claude-sonnet-4-6": claude(),
        "claude-sonnet-4-5": claude(),
        "claude-sonnet-4": claude(),
        "claude-haiku-4-5": claude(),
        "claude-3-7-sonnet": claude(),
        "claude-3-5-sonnet": claude(),
        "claude-3-5-haiku": claude(),
        "claude-3-opus": claude(),
        "claude-3-haiku": claude(),
    ]

    // ─ OpenAI ───────────────────────────────────────────────────────────────
    //
    // Cached input is a tenth of input wherever OpenAI offers it; the `-pro`
    // models have no cached price at all, so a cached token there is a full
    // one. Writing to the cache is free.

    private static func gpt(output: Double, read: Double = 0.1) -> TokenPrice {
        TokenPrice(cacheRead: read, cacheWrite5m: 1, cacheWrite1h: 1, output: output)
    }

    private static let openAI: [String: TokenPrice] = [
        "gpt-5.6-sol": gpt(output: 5),
        "gpt-5.6-terra": gpt(output: 6),
        "gpt-5.6-luna": gpt(output: 6),
        "gpt-5.5": gpt(output: 6),
        "gpt-5.5-pro": gpt(output: 6, read: 1),
        "gpt-5.4": gpt(output: 6),
        "gpt-5.4-mini": gpt(output: 6),
        "gpt-5.4-nano": gpt(output: 6.25),
        "gpt-5.4-pro": gpt(output: 6, read: 1),
        "gpt-5.3-codex": gpt(output: 8),
        "gpt-5.2": gpt(output: 8),
        "gpt-5.2-pro": gpt(output: 8, read: 1),
        "gpt-5.1": gpt(output: 8),
        "gpt-5": gpt(output: 8),
        "gpt-5-mini": gpt(output: 8),
        "gpt-5-nano": gpt(output: 8),
        "gpt-5-pro": gpt(output: 8, read: 1),
    ]
}
