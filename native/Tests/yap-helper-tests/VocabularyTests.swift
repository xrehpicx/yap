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
        // "Fluid Audio" has FluidAudio's exact letters, so `snap` fixes it without the audio check.
        XCTAssertEqual(Set(misses), ["Supabase", "Vercel", "shadcn"])
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

    func testMishearingsSplitIntoEverydayWords() {
        // Real transcripts where Parakeet split an unusual word into ordinary ones.
        XCTAssertEqual(
            Vocabulary.nearMisses(in: "Counterfeiting, security, notice, change lock.", terms: ["changelog"]), ["changelog"])
        XCTAssertEqual(Vocabulary.nearMisses(in: "Move it to super base today", terms: ["Supabase"]), ["Supabase"])
        XCTAssertEqual(Vocabulary.nearMisses(in: "Ask cloud code to fix it", terms: ["Claude Code"]), ["Claude Code"])
        XCTAssertEqual(Vocabulary.nearMisses(in: "I want to PMPM install something.", terms: ["pnpm"]), ["pnpm"])
        XCTAssertTrue(Vocabulary.acceptsReplacement(of: "change lock", with: "changelog"))
        XCTAssertTrue(Vocabulary.acceptsReplacement(of: "super base", with: "Supabase"))
    }

    func testTermWithANeighbourIsNotAMishearing() {
        XCTAssertEqual(Vocabulary.nearMisses(in: "We use a React app on the Supabase stack", terms: ["React", "Supabase"]), [])
        XCTAssertFalse(Vocabulary.acceptsReplacement(of: "a React", with: "React"))
    }

    func testFindsIdentifiersOnScreen() {
        let ids = Vocabulary.identifiers(in: ["Fix RE-727 and RE-729 before ENG-4521. Version 2.1, PR42."])
        XCTAssertEqual(Set(ids), ["RE-727", "RE-729", "ENG-4521", "PR42"])
    }

    func testSnapsToScreenSpelling() {
        // After formatting turned "Re seven two seven" into digits.
        XCTAssertEqual(Vocabulary.snap("Re 727 of Re 729.", to: ["RE-727", "RE-729"]), "RE-727 of RE-729.")
        XCTAssertEqual(Vocabulary.snap("look at re-727 now", to: ["RE-727"]), "look at RE-727 now")
        XCTAssertEqual(Vocabulary.snap("whether Fluid Audio runs", to: ["FluidAudio"]), "whether FluidAudio runs")
        // Case alone never changes a plain word.
        XCTAssertEqual(Vocabulary.snap("a linear plan", to: ["Linear"]), "a linear plan")
        XCTAssertEqual(Vocabulary.snap("nothing to change", to: ["RE-727"]), "nothing to change")
    }

    func testSoundKeys() {
        XCTAssertEqual(Vocabulary.soundKey("yeah") + Vocabulary.soundKey("plugs"), Array("YPLKS".utf8))
        XCTAssertEqual(Vocabulary.soundKey("Vercel"), Vocabulary.soundKey("Versal"))
        XCTAssertEqual(Vocabulary.soundKey("changelog"), Array("XNJLK".utf8))
    }

    func testSoundAlikePhrasesFromScreen() {
        // Real transcripts, dictated while "yap logs" was on screen.
        let screen = Vocabulary.phraseIndex(from: ["Then run `yap logs` to see what happened. Open diff"])
        XCTAssertEqual(Vocabulary.soundAlike("Yeah, plugs.", phrases: screen), "yap logs.")
        XCTAssertEqual(Vocabulary.soundAlike("Yeah, blogs.", phrases: screen), "yap logs.")
        XCTAssertEqual(Vocabulary.soundAlike("Check the yap logs.", phrases: screen), "Check the yap logs.")
        // Only the misheard word changes; the speaker's own words keep their case.
        XCTAssertEqual(Vocabulary.soundAlike("Run YAP logs and open div.", phrases: screen), "Run YAP logs and open diff.")
        // An unusual single word, spelled as on screen.
        XCTAssertEqual(
            Vocabulary.soundAlike("Deploy it to Versal.", phrases: Vocabulary.phraseIndex(from: ["Vercel dashboard"])),
            "Deploy it to Vercel.")
    }

    func testSoundAlikeLeavesOrdinaryWordsAlone() {
        let screen = Vocabulary.phraseIndex(from: ["the logs are here", "React and Supabase"])
        // A single ordinary word is never swapped for another.
        XCTAssertEqual(Vocabulary.soundAlike("Check the locks.", phrases: screen), "Check the locks.")
        XCTAssertEqual(Vocabulary.soundAlike("We refactor the database.", phrases: screen), "We refactor the database.")
        XCTAssertEqual(Vocabulary.soundAlike("Yeah, plugs.", phrases: Vocabulary.phraseIndex(from: ["nothing here"])), "Yeah, plugs.")
    }

    func testNearMissCheckIsFast() {
        let terms = (0..<100).map { "Term\($0)Name" }
        let transcript = String(repeating: "we should ship the new release to production tomorrow morning ", count: 10)
        // The app loads the English word list at startup; do the same before timing.
        Vocabulary.warmUp()
        // Best of three, so a busy machine cannot fail the test.
        let fastest = (0..<3).map { _ in
            let started = Date()
            _ = Vocabulary.nearMisses(in: transcript, terms: terms)
            return Date().timeIntervalSince(started)
        }.min()!
        // This is the worst case: 100 screen words and a 100-word dictation. The release app
        // takes ~15 ms; debug builds, which the tests use, take ~120 ms on an M4 Max and over
        // 250 ms on a busy machine. The bound catches a change in kind, not a slow machine.
        XCTAssertLessThan(fastest, 1.0)
    }
}
