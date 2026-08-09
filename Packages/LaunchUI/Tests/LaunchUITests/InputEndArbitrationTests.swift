import Testing
@testable import LaunchUI

@Suite("Input end arbitration")
struct InputEndArbitrationTests {
    private typealias Source = InputEndArbitration.Source
    private typealias Decision = InputEndArbitration.Decision

    @Test("covers every owner, ending source, and left-button state")
    func allCombinations() {
        let cases: [(
            owner: Source?,
            ending: Source,
            leftPressed: Bool,
            expected: Decision
        )] = [
            (nil, .mouse, false, .reject),
            (nil, .mouse, true, .reject),
            (nil, .threeFinger, false, .reject),
            (nil, .threeFinger, true, .reject),
            (.mouse, .mouse, false, .end),
            (.mouse, .mouse, true, .end),
            (.mouse, .threeFinger, false, .reject),
            (.mouse, .threeFinger, true, .reject),
            (.threeFinger, .mouse, false, .end),
            (.threeFinger, .mouse, true, .end),
            (.threeFinger, .threeFinger, false, .end),
            (.threeFinger, .threeFinger, true, .handoffToMouse),
        ]

        for testCase in cases {
            #expect(
                InputEndArbitration.decide(
                    sessionOwner: testCase.owner,
                    endingSource: testCase.ending,
                    leftMouseButtonPressed: testCase.leftPressed
                ) == testCase.expected
            )
        }
    }
}
