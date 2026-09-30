import XCTest

@testable import yap_helper

final class VocabularyTests: XCTestCase {
    func testPicksUnusualWordsFromScreenText() {
        let screen = """
            #launch — Anusha: Supabase migration is done, Vercel deploy is running.
            Xiaomei: can someone review the shadcn PR? It uses pnpm and tRPC.
            Refactoring the dashboards next. See https://github.com/xrehpicx/yap for details.
            """
        let terms = Vocabulary.terms(in: [screen])
        for expected in ["Anusha", "Supabase", "Vercel", "Xiaomei", "shadcn", "pnpm", "tRPC", "xrehpicx"] {
            XCTAssertTrue(terms.contains(expected), "\(expected) missing from \(terms)")
        }
        for ordinary in ["migration", "running", "Refactoring", "dashboards", "review", "https", "com"] {
            XCTAssertFalse(terms.contains(ordinary), "\(ordinary) should not be a term")
        }
    }

    func testRanksByFrequencyAndKeepsAlwaysTermsFirst() {
        let terms = Vocabulary.terms(in: ["Vercel Vercel Supabase"], always: ["FluidAudio"])
        XCTAssertEqual(terms.prefix(3), ["FluidAudio", "Vercel", "Supabase"])
    }

    func testSkipsHashesAndShoutedWords() {
        XCTAssertFalse(Vocabulary.isTerm("a1b2c3d4e5"))
        XCTAssertFalse(Vocabulary.isTerm("THE"))
        XCTAssertTrue(Vocabulary.isTerm("JSON"))
    }

    func testFindsNearMisses() {
        // Real Parakeet mishearings of the terms.
        let transcript = "Ask Anusha about the superbase and Versal migration in the Shaden repo using Fluid Audio"
        let misses = Vocabulary.nearMisses(in: transcript, terms: ["Supabase", "Vercel", "shadcn", "FluidAudio", "Anusha"])
        XCTAssertEqual(Set(misses), ["Supabase", "Vercel", "shadcn", "FluidAudio"])
    }

    func testCorrectTranscriptsHaveNoNearMisses() {
        let transcript = "The same linear plan for Supabase and Vercel is fine, and that is all."
        XCTAssertEqual(Vocabulary.nearMisses(in: transcript, terms: ["Supabase", "Vercel", "Linear", "Sam"]), [])
    }

    func testEverydayWordsAreNeverNearMisses() {
        // Real transcripts that once triggered the check or a wrong replacement.
        let transcript = "Here's the plan. First, we refactor the auth module. Second, we migrate the database. New line, thanks."
        XCTAssertEqual(Vocabulary.nearMisses(in: transcript, terms: ["React", "Supabase", "Linear"]), [])
    }

    func testReplacementRules() {
        XCTAssertTrue(Vocabulary.acceptsReplacement(of: "superbase", with: "Supabase"))
        XCTAssertTrue(Vocabulary.acceptsReplacement(of: "Shaden", with: "shadcn"))
        XCTAssertTrue(Vocabulary.acceptsReplacement(of: "Fluid Audio", with: "FluidAudio"))
        XCTAssertFalse(Vocabulary.acceptsReplacement(of: "refactor", with: "React"))
        XCTAssertFalse(Vocabulary.acceptsReplacement(of: "database", with: "Supabase"))
        XCTAssertFalse(Vocabulary.acceptsReplacement(of: "Linear", with: "linear"))
    }

    func testApplyKeepsPunctuationAndSkipsRejected() {
        let applied = Vocabulary.apply(
            [("superbase", "Supabase"), ("database", "Supabase"), ("Fluid Audio", "FluidAudio")],
            to: "Move the superbase data. Then check the database, and Fluid Audio.")
        XCTAssertEqual(applied.text, "Move the Supabase data. Then check the database, and FluidAudio.")
        XCTAssertEqual(applied.count, 2)
    }

    func testNearMissCheckIsFast() {
        let terms = (0..<100).map { "Term\($0)Name" }
        let transcript = String(repeating: "we should ship the new release to production tomorrow morning ", count: 10)
        let started = Date()
        _ = Vocabulary.nearMisses(in: transcript, terms: terms)
        // Debug builds are several times slower than the release app.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }
}
