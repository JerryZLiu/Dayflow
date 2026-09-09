import XCTest

@testable import Dayflow

final class ClaudeActivityCardBoundaryTests: XCTestCase {
  private let provider = ClaudeProvider()

  func testFreshSegmentUsesOnlyCurrentBatchAndOmitsDisconnectedCardsFromPrompt() {
    let oldObservation = observation(batchId: 1, start: 1_000, end: 1_900, text: "Old work")
    let currentObservation = observation(
      batchId: 2,
      start: 4_000,
      end: 4_900,
      text: "Current work"
    )
    let oldCard = card(start: "8:00 AM", end: "8:15 AM", title: "Old card")
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [oldCard],
      hasPreviousCardWithinFiveMinutes: false
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [oldObservation, currentObservation],
      context: context
    )

    XCTAssertTrue(plan.requiresSingleCard)
    XCTAssertEqual(plan.observations.map(\.batchId), [2])
    XCTAssertTrue(plan.context.existingCards.isEmpty)
  }

  func testFreshSegmentPromptRequiresExactlyOneProvisionalCard() {
    let currentObservation = observation(
      batchId: 2,
      start: 4_000,
      end: 4_900,
      text: "Current work"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [],
      hasPreviousCardWithinFiveMinutes: false
    )

    let prompt = provider.buildCardsPrompt(
      observations: [currentObservation],
      context: context
    )

    XCTAssertTrue(prompt.contains("FRESH SEGMENT MODE — EXACTLY ONE CARD"))
    XCTAssertTrue(prompt.contains("later sliding-window passes may split it"))
    XCTAssertFalse(prompt.contains("WHEN TO SPLIT (new card)"))
  }

  func testFreshClaudeSegmentReplacesOnlyCurrentBatchRange() {
    let batchStart = Date(timeIntervalSince1970: TimeInterval(localTimestamp(hour: 9, minute: 15)))
    let windowStart = batchStart.addingTimeInterval(-45 * 60)

    XCTAssertEqual(
      LLMService.cardReplacementStartTime(
        activeProviderID: .claude,
        generatedCards: [
          card(start: "9:15 AM", end: "9:30 AM", title: "Fresh card")
        ],
        batchStartTime: batchStart,
        windowStartTime: windowStart
      ),
      batchStart
    )
    XCTAssertEqual(
      LLMService.cardReplacementStartTime(
        activeProviderID: .claude,
        generatedCards: [
          card(start: "9:00 AM", end: "9:30 AM", title: "Connected rewrite")
        ],
        batchStartTime: batchStart,
        windowStartTime: windowStart
      ),
      Date(timeIntervalSince1970: TimeInterval(localTimestamp(hour: 9, minute: 0)))
    )
    XCTAssertEqual(
      LLMService.cardReplacementStartTime(
        activeProviderID: .chatGPT,
        generatedCards: [],
        batchStartTime: batchStart,
        windowStartTime: windowStart
      ),
      windowStart
    )
  }

  func testOngoingSegmentUsesOnlyHistoryConnectedToCurrentBatch() {
    let disconnectedObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 8, minute: 30),
      end: localTimestamp(hour: 8, minute: 33),
      text: "Disconnected history"
    )
    let connectedObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 15),
      text: "Previous connected activity"
    )
    let precedingObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 8, minute: 50),
      end: localTimestamp(hour: 8, minute: 58),
      text: "Preceding preserved activity"
    )
    let currentObservation = observation(
      batchId: 2,
      start: localTimestamp(hour: 9, minute: 15),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Current activity"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [
        card(start: "8:30 AM", end: "8:33 AM", title: "Disconnected card"),
        card(start: "8:50 AM", end: "8:58 AM", title: "Preceding card"),
        card(start: "9:00 AM", end: "9:15 AM", title: "Connected card"),
      ],
      hasPreviousCardWithinFiveMinutes: true
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [
        disconnectedObservation,
        precedingObservation,
        connectedObservation,
        currentObservation,
      ],
      context: context
    )

    XCTAssertFalse(plan.requiresSingleCard)
    XCTAssertEqual(
      plan.observations.map(\.observation),
      ["Previous connected activity", "Current activity"]
    )
    XCTAssertEqual(plan.context.existingCards.map(\.title), ["Connected card"])
    XCTAssertEqual(plan.expectedStartTime, "9:00 AM")
    XCTAssertEqual(plan.expectedEndTime, "9:30 AM")
  }

  func testOngoingSegmentPreservesSelectedCardTailBeyondCurrentBatch() {
    let currentObservation = observation(
      batchId: 2,
      start: localTimestamp(hour: 9, minute: 15),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Current activity"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [
        card(start: "9:00 AM", end: "9:45 AM", title: "Existing future tail")
      ],
      hasPreviousCardWithinFiveMinutes: true
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [currentObservation],
      context: context
    )
    let rewrittenCards = [
      card(start: "9:00 AM", end: "9:45 AM", title: "Full connected rewrite")
    ]

    XCTAssertEqual(plan.expectedStartTime, "9:00 AM")
    XCTAssertEqual(plan.expectedEndTime, "9:45 AM")
    XCTAssertTrue(
      provider.validateClaudeTimeCoverage(
        existingCards: plan.context.existingCards,
        requiredObservations: plan.observations,
        newCards: rewrittenCards
      ).isValid
    )
    XCTAssertTrue(
      provider.validateClaudeCardPolicy(
        rewrittenCards,
        requiresSingleCard: plan.requiresSingleCard,
        expectedStartTime: plan.expectedStartTime,
        expectedEndTime: plan.expectedEndTime,
        allowsSingleShortCard: plan.allowsSingleShortCard
      ).isValid
    )
    XCTAssertEqual(
      LLMService.cardReplacementEndTime(
        activeProviderID: .claude,
        generatedCards: rewrittenCards,
        batchEndTime: Date(
          timeIntervalSince1970: TimeInterval(localTimestamp(hour: 9, minute: 30))
        )
      ),
      Date(timeIntervalSince1970: TimeInterval(localTimestamp(hour: 9, minute: 45)))
    )
  }

  func testOngoingPolicyRejectsStartingBeforeConnectedRewriteBoundary() {
    let result = provider.validateClaudeCardPolicy(
      [card(start: "8:59 AM", end: "9:30 AM", title: "Overlapping output")],
      requiresSingleCard: false,
      expectedStartTime: "9:00 AM",
      expectedEndTime: "9:30 AM",
      allowsSingleShortCard: false
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("connected rewrite boundary") ?? false)
  }

  func testOngoingSegmentWalksBackwardAcrossContiguousCards() {
    let currentObservation = observation(
      batchId: 2,
      start: localTimestamp(hour: 9, minute: 15),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Current activity"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [
        card(start: "9:00 AM", end: "9:10 AM", title: "Boundary card"),
        card(start: "9:10 AM", end: "9:15 AM", title: "Latest card"),
      ],
      hasPreviousCardWithinFiveMinutes: true
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [currentObservation],
      context: context
    )

    XCTAssertEqual(plan.context.existingCards.map(\.title), ["Boundary card", "Latest card"])
  }

  func testShortIslandAcrossMaterialGapStartsFreshSegment() {
    let currentObservation = observation(
      batchId: 2,
      start: localTimestamp(hour: 9, minute: 15),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Current activity"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [
        card(start: "9:11 AM", end: "9:12 AM", title: "Short disconnected island")
      ],
      hasPreviousCardWithinFiveMinutes: true
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [currentObservation],
      context: context
    )

    XCTAssertTrue(plan.requiresSingleCard)
    XCTAssertTrue(plan.context.existingCards.isEmpty)
  }

  func testShortCardAcrossOneMinuteSeamJoinsOngoingSegment() {
    let currentObservation = observation(
      batchId: 2,
      start: localTimestamp(hour: 9, minute: 15),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Current activity"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [
        card(start: "9:13 AM", end: "9:14 AM", title: "Short connected card")
      ],
      hasPreviousCardWithinFiveMinutes: true
    )

    let plan = provider.makeClaudeCardGenerationPlan(
      observations: [currentObservation],
      context: context
    )
    let rewrittenCards = [
      card(start: "9:13 AM", end: "9:30 AM", title: "Connected rewrite")
    ]

    XCTAssertFalse(plan.requiresSingleCard)
    XCTAssertEqual(plan.context.existingCards.map(\.title), ["Short connected card"])
    XCTAssertTrue(
      provider.validateClaudeTimeCoverage(
        existingCards: plan.context.existingCards,
        requiredObservations: plan.observations,
        newCards: rewrittenCards
      ).isValid
    )
    XCTAssertTrue(
      provider.validateClaudeCardPolicy(
        rewrittenCards,
        requiresSingleCard: plan.requiresSingleCard,
        expectedStartTime: plan.expectedStartTime,
        expectedEndTime: plan.expectedEndTime,
        allowsSingleShortCard: plan.allowsSingleShortCard
      ).isValid
    )
  }

  func testOngoingPromptMakesTenMinuteFloorOverrideSplitting() {
    let currentObservation = observation(
      batchId: 2,
      start: 4_000,
      end: 4_900,
      text: "Current work"
    )
    let context = generationContext(
      batchObservations: [currentObservation],
      existingCards: [card(start: "8:00 AM", end: "8:15 AM", title: "Old card")],
      hasPreviousCardWithinFiveMinutes: true
    )

    let prompt = provider.buildCardsPrompt(
      observations: [currentObservation],
      context: context
    )

    XCTAssertTrue(
      prompt.contains("Every card, including the final card, must be 10-60 minutes")
    )
    XCTAssertTrue(prompt.contains("Absorb a 1-4-minute moment into the longer adjacent episode"))
    XCTAssertTrue(
      prompt.contains(
        "For a distinct 5-9-minute episode, borrow only enough adjacent minutes to reach 10"
      )
    )
    XCTAssertTrue(
      prompt.contains(
        "Split a sustained immediate-goal change when both cards remain at least 10 minutes"
      )
    )
  }

  func testClaudePolicyRejectsEveryShortCardIncludingFinalCard() {
    let result = provider.validateClaudeCardPolicy(
      [
        card(start: "9:00 AM", end: "9:08 AM", title: "Short first"),
        card(start: "9:08 AM", end: "9:20 AM", title: "Valid middle"),
        card(start: "9:20 AM", end: "9:23 AM", title: "Short final"),
      ],
      requiresSingleCard: false,
      expectedStartTime: nil,
      expectedEndTime: nil,
      allowsSingleShortCard: false
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("Card 1") ?? false)
    XCTAssertTrue(result.error?.contains("Card 3") ?? false)
    XCTAssertTrue(result.error?.contains("including the final card") ?? false)
  }

  func testClaudePolicyAllowsOneShortCardOnlyWhenWholeSpanIsShort() {
    let shortCard = card(start: "9:00 AM", end: "9:07 AM", title: "Short supplied span")

    XCTAssertTrue(
      provider.validateClaudeCardPolicy(
        [shortCard],
        requiresSingleCard: true,
        expectedStartTime: "9:00 AM",
        expectedEndTime: "9:07 AM",
        allowsSingleShortCard: true
      ).isValid
    )
    XCTAssertFalse(
      provider.validateClaudeCardPolicy(
        [shortCard],
        requiresSingleCard: false,
        expectedStartTime: nil,
        expectedEndTime: nil,
        allowsSingleShortCard: false
      ).isValid
    )
  }

  func testClaudePolicyRejectsOverlappingCards() {
    let result = provider.validateClaudeCardPolicy(
      [
        card(start: "5:57 PM", end: "6:15 PM", title: "First"),
        card(start: "6:11 PM", end: "6:24 PM", title: "Second"),
      ],
      requiresSingleCard: false,
      expectedStartTime: nil,
      expectedEndTime: nil,
      allowsSingleShortCard: false
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("overlaps the preceding card") ?? false)
  }

  func testClaudeCoverageRejectsDroppingNewestObservationTail() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Continuous activity"
    )
    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: [requiredObservation],
      newCards: [card(start: "9:00 AM", end: "9:27 AM", title: "Incomplete")]
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("cover all supplied observations") ?? false)
  }

  func testClaudeCoverageAcceptsCrossMidnightMerge() {
    let existingCards = [
      card(start: "11:50 PM", end: "12:00 AM", title: "Before midnight"),
      card(start: "12:00 AM", end: "12:05 AM", title: "After midnight"),
    ]
    let mergedCards = [
      card(start: "11:50 PM", end: "12:05 AM", title: "Cross-midnight session")
    ]

    XCTAssertTrue(
      provider.validateClaudeTimeCoverage(
        existingCards: existingCards,
        newCards: mergedCards
      ).isValid
    )
  }

  func testClaudeCoverageRejectsGapInsideCurrentObservations() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Continuous activity"
    )
    let cardsWithGap = [
      card(start: "9:00 AM", end: "9:15 AM", title: "Before gap"),
      card(start: "9:20 AM", end: "9:30 AM", title: "After gap"),
    ]

    XCTAssertFalse(
      provider.validateClaudeTimeCoverage(
        existingCards: [],
        requiredObservations: [requiredObservation],
        newCards: cardsWithGap
      ).isValid
    )
  }

  func testClaudeCoverageRejectsMalformedStorageTimestamp() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 20),
      text: "Continuous activity"
    )

    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: [requiredObservation],
      newCards: [card(start: "garbage", end: "9:20 AM", title: "Malformed")]
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("Invalid timestamp: garbage") ?? false)
  }

  func testClaudeCoverageRejectsTimestampWithSecondsThatPersistenceCannotStore() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 20),
      text: "Continuous activity"
    )

    XCTAssertFalse(
      provider.validateClaudeTimeCoverage(
        existingCards: [],
        requiredObservations: [requiredObservation],
        newCards: [card(start: "9:00:30 AM", end: "9:20 AM", title: "Seconds")]
      ).isValid
    )
  }

  func testClaudeCoverageRejectsReversedMidnightCardOrder() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(day: 20, hour: 23, minute: 50),
      end: localTimestamp(day: 21, hour: 0, minute: 20),
      text: "Continuous overnight activity"
    )
    let reversedCards = [
      card(start: "12:05 AM", end: "12:20 AM", title: "After midnight"),
      card(start: "11:50 PM", end: "12:05 AM", title: "Before midnight"),
    ]

    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: [requiredObservation],
      newCards: reversedCards
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("overlap") ?? false)
  }

  func testClaudeCoverageRejectsCardBridgingMaterialEvidenceGap() {
    let observations = [
      observation(
        batchId: 1,
        start: localTimestamp(hour: 9, minute: 0),
        end: localTimestamp(hour: 9, minute: 10),
        text: "Before gap"
      ),
      observation(
        batchId: 2,
        start: localTimestamp(hour: 9, minute: 20),
        end: localTimestamp(hour: 9, minute: 30),
        text: "After gap"
      ),
    ]

    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: observations,
      newCards: [card(start: "9:00 AM", end: "9:30 AM", title: "Bridged gap")]
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("genuine gap") ?? false)
  }

  func testClaudeCoverageAllowsSubminuteEvidenceSeam() {
    let observations = [
      observation(
        batchId: 1,
        start: localTimestamp(hour: 9, minute: 0),
        end: localTimestamp(hour: 9, minute: 10),
        text: "First segment"
      ),
      observation(
        batchId: 1,
        start: localTimestamp(hour: 9, minute: 10) + 30,
        end: localTimestamp(hour: 9, minute: 20),
        text: "Second segment"
      ),
    ]

    XCTAssertTrue(
      provider.validateClaudeTimeCoverage(
        existingCards: [],
        requiredObservations: observations,
        newCards: [card(start: "9:00 AM", end: "9:20 AM", title: "One session")]
      ).isValid
    )
  }

  func testClaudeCoverageRejectsExactOneMinuteOutputGap() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 30),
      text: "Continuous activity"
    )

    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: [requiredObservation],
      newCards: [
        card(start: "9:00 AM", end: "9:14 AM", title: "First activity"),
        card(start: "9:15 AM", end: "9:30 AM", title: "Second activity"),
      ]
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("cover all supplied observations") ?? false)
  }

  func testOngoingPolicyRejectsMissingExactOneMinuteTail() {
    let result = provider.validateClaudeCardPolicy(
      [card(start: "9:00 AM", end: "9:29 AM", title: "Missing tail")],
      requiresSingleCard: false,
      expectedStartTime: "9:00 AM",
      expectedEndTime: "9:30 AM",
      allowsSingleShortCard: false
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("through 9:30 AM") ?? false)
  }

  func testClaudeCoverageRejectsOutputOutsideEvidence() {
    let requiredObservation = observation(
      batchId: 1,
      start: localTimestamp(hour: 9, minute: 0),
      end: localTimestamp(hour: 9, minute: 20),
      text: "Continuous activity"
    )

    let result = provider.validateClaudeTimeCoverage(
      existingCards: [],
      requiredObservations: [requiredObservation],
      newCards: [card(start: "8:55 AM", end: "9:20 AM", title: "Invented lead-in")]
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("outside the supplied source timeline") ?? false)
  }

  func testClaudeCoverageIncludesOlderPromptWindowObservations() {
    let observations = [
      observation(
        batchId: 1,
        start: localTimestamp(hour: 8, minute: 50),
        end: localTimestamp(hour: 9, minute: 0),
        text: "Earlier supplied activity"
      ),
      observation(
        batchId: 2,
        start: localTimestamp(hour: 9, minute: 15),
        end: localTimestamp(hour: 9, minute: 30),
        text: "Newest batch"
      ),
    ]

    XCTAssertFalse(
      provider.validateClaudeTimeCoverage(
        existingCards: [],
        requiredObservations: observations,
        newCards: [card(start: "9:15 AM", end: "9:30 AM", title: "Newest only")]
      ).isValid
    )
  }

  func testFreshSegmentPolicyRejectsMultipleCardsAndWrongBounds() {
    let result = provider.validateClaudeCardPolicy(
      [
        card(start: "9:01 AM", end: "9:11 AM", title: "First"),
        card(start: "9:11 AM", end: "9:21 AM", title: "Second"),
      ],
      requiresSingleCard: true,
      expectedStartTime: "9:00 AM",
      expectedEndTime: "9:20 AM",
      allowsSingleShortCard: false
    )

    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.error?.contains("exactly one card") ?? false)
  }

  func testCorrectionPromptRepeatsFreshAndFinalCardRules() {
    let prompt = provider.buildCardsCorrectionPrompt(
      validationError: "Two short cards",
      requiresSingleCard: true
    )

    XCTAssertTrue(prompt.contains("including the final card"))
    XCTAssertTrue(prompt.contains("Return exactly ONE card"))
    XCTAssertTrue(prompt.contains("duration rule overrides semantic purity"))
  }

  private func generationContext(
    batchObservations: [Observation],
    existingCards: [ActivityCardData],
    hasPreviousCardWithinFiveMinutes: Bool
  ) -> ActivityGenerationContext {
    ActivityGenerationContext(
      batchObservations: batchObservations,
      existingCards: existingCards,
      currentTime: Date(timeIntervalSince1970: 5_000),
      categories: [],
      hasPreviousCardWithinFiveMinutes: hasPreviousCardWithinFiveMinutes
    )
  }

  private func observation(
    batchId: Int64,
    start: Int,
    end: Int,
    text: String
  ) -> Observation {
    Observation(
      id: nil,
      batchId: batchId,
      startTs: start,
      endTs: end,
      observation: text,
      metadata: nil,
      llmModel: nil,
      createdAt: nil
    )
  }

  private func localTimestamp(day: Int = 20, hour: Int, minute: Int) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 7,
      day: day,
      hour: hour,
      minute: minute
    )
    return Int(calendar.date(from: components)!.timeIntervalSince1970)
  }

  private func card(start: String, end: String, title: String) -> ActivityCardData {
    ActivityCardData(
      startTime: start,
      endTime: end,
      category: "Focus",
      subcategory: "",
      title: title,
      summary: "Summary",
      detailedSummary: "Details",
      distractions: nil,
      appSites: nil
    )
  }
}
