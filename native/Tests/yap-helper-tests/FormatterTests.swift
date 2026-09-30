import XCTest

@testable import yap_helper

/// Inputs are real Parakeet v2 transcripts of dictated phrases.
final class FormatterTests: XCTestCase {
    private func assertFormats(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Formatter.format(input), expected, file: file, line: line)
    }

    func testLeavesCleanTextAlone() {
        let text = "Okay so I'm thinking we refactor the authentication middleware first, then move the session store to Redis."
        assertFormats(text, text)
        assertFormats("Hey, can you send me the updated deck before the 3 o'clock meeting? Thanks.",
                      "Hey, can you send me the updated deck before the 3 o'clock meeting? Thanks.")
        assertFormats("My iPhone runs macOS apps.", "My iPhone runs macOS apps.")
    }

    func testRemovesFillers() {
        assertFormats("Um, so I think we should, uh, ship it tomorrow, you know, after the review.",
                      "So I think we should ship it tomorrow, you know, after the review.")
        assertFormats("Great. Uhm, let's go.", "Great. Let's go.")
        assertFormats("Hmm, not sure.", "Not sure.")
        // Words that merely contain a filler survive.
        assertFormats("The umbrella is humming.", "The umbrella is humming.")
    }

    func testRemovesStutters() {
        assertFormats("The the build is failing because I I forgot to commit the the lock file",
                      "The build is failing because I forgot to commit the lock file")
        assertFormats("I think that that is fine and we had had enough.", "I think that that is fine and we had had enough.")
    }

    func testScratchThat() {
        assertFormats("Let's meet at 5, scratch that, let's meet at 6", "Let's meet at 6")
        assertFormats("Send the report. Let's meet at 5. Scratch that. Six works for me.",
                      "Send the report. Six works for me.")
    }

    func testSpokenPunctuation() {
        assertFormats("Can you check if the tests pass question mark?", "Can you check if the tests pass?")
        assertFormats("We shipped it exclamation point", "We shipped it!")
    }

    func testLineBreaks() {
        assertFormats("Dear team, new paragraph, the release is delayed until Friday, new line, thanks, Raj",
                      "Dear team,\n\nThe release is delayed until Friday.\nThanks, Raj")
    }

    func testDigitList() {
        assertFormats("I need three things from the store. 1. Milk. 2. Eggs. 3. A loaf of bread.",
                      "I need three things from the store:\n1. Milk\n2. Eggs\n3. A loaf of bread")
    }

    func testOrdinalList() {
        assertFormats(
            "Here's the plan. First, we refactor the auth module. Second, we migrate the database. Third, we delete the old code.",
            "Here's the plan:\n1. We refactor the auth module\n2. We migrate the database\n3. We delete the old code")
    }

    func testNumberWordList() {
        assertFormats("Number one, update the docs. Number two, fix the tests. Number three, cut the release",
                      "1. Update the docs\n2. Fix the tests\n3. Cut the release")
        assertFormats("Two options. One, ship now, and two, wait a week.",
                      "Two options:\n1. Ship now\n2. Wait a week")
    }

    func testNumberWordsWithoutCommas() {
        // How Parakeet writes a list spoken at natural speed.
        assertFormats("I need three things from the store. One milk, two eggs, three a loaf of bread.",
                      "I need three things from the store:\n1. Milk\n2. Eggs\n3. A loaf of bread")
    }

    func testListSaidNaturally() {
        // Both of these are real transcripts of the same sentence.
        let expected = "I need three things from the store:\n- Milk\n- Eggs\n- A loaf of bread"
        assertFormats("I need three things from the store: milk, eggs, a loaf of bread", expected)
        assertFormats("I need three things from the store: milk, eggs and a loaf of bread.", expected)
        assertFormats("Grab these: milk, eggs, and bread.", "Grab these:\n- Milk\n- Eggs\n- Bread")
    }

    func testAnnouncedCountDecidesTheItems() {
        assertFormats("Pick up two things: milk and eggs.", "Pick up two things:\n- Milk\n- Eggs")
        assertFormats("We need three things: salt and pepper, bread, and cheese.",
                      "We need three things:\n- Salt and pepper\n- Bread\n- Cheese")
    }

    func testNaturalListKeepsSurroundingText() {
        assertFormats("Hey Sam. I need three things: milk, eggs, bread. Thanks!",
                      "Hey Sam. I need three things:\n- Milk\n- Eggs\n- Bread\n\nThanks!")
    }

    func testColonSentencesThatAreNotLists() {
        assertFormats("Quick note: I pushed the fix.", "Quick note: I pushed the fix.")
        assertFormats("Two options: ship it tonight.", "Two options: ship it tonight.")
        assertFormats(
            "The plan: we refactor the whole authentication module first, then we migrate every single table, then we delete it.",
            "The plan: we refactor the whole authentication module first, then we migrate every single table, then we delete it.")
        assertFormats("Meet at 3:30, bring snacks, and a charger.", "Meet at 3:30, bring snacks, and a charger.")
    }

    func testQuantitiesAreNotLists() {
        assertFormats("One of the tests failed, two of them passed.", "One of the tests failed, two of them passed.")
        assertFormats("We waited one day, two days, then three days.", "We waited one day, two days, then three days.")
        assertFormats("One more thing, two hundred people signed up.", "One more thing, two hundred people signed up.")
    }

    func testListFollowedByMoreText() {
        assertFormats("Steps. 1. Build it. 2. Test it. Then we can talk about the launch.",
                      "Steps:\n1. Build it\n2. Test it\n\nThen we can talk about the launch.")
    }

    func testSingleMarkerIsNotAList() {
        assertFormats("First, let me say thanks for the review.", "First, let me say thanks for the review.")
        assertFormats("One of the tests failed. We shipped version 2. It works.",
                      "One of the tests failed. We shipped version 2. It works.")
    }

    func testIsFastEnoughToIgnore() {
        let text = String(repeating: "Um, so the the plan is, uh, simple. First, we build. Second, we ship. ", count: 4)
        let started = Date()
        for _ in 0..<200 { _ = Formatter.format(text) }
        let perCall = Date().timeIntervalSince(started) / 200 * 1000
        print("Formatter.format: \(String(format: "%.3f", perCall)) ms per call for \(text.count) characters")
        XCTAssertLessThan(perCall, 2)
    }
}
