import Testing
@testable import Triage

struct OnboardingStepTests {
    @Test func requiredStepsGateWhatComesAfter() {
        var facts = OnboardingStep.Facts()
        #expect(OnboardingStep.github.isReachable(facts))
        #expect(!OnboardingStep.github.canContinue(facts))
        #expect(!OnboardingStep.organization.isReachable(facts))

        facts.hasAccount = true
        #expect(OnboardingStep.organization.isReachable(facts))
        #expect(!OnboardingStep.copilot.isReachable(facts))

        facts.hasOrganization = true
        #expect(OnboardingStep.ready.isReachable(facts))
    }

    @Test func optionalStepsCanBeSkipped() {
        let facts = OnboardingStep.Facts(hasAccount: true, hasOrganization: true)
        for step in [OnboardingStep.copilot, .notifications, .mac] {
            #expect(step.canContinue(facts))
            #expect(!step.isComplete(facts))
        }
        #expect(OnboardingStep.copilot.isComplete(.init(isCopilotReady: true)))
    }

    @Test func stepsRunInOrder() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.ready.next == nil)
        #expect(OnboardingStep.allCases.compactMap(\.next) == Array(OnboardingStep.allCases.dropFirst()))
    }
}
