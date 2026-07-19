//
//  MiniMaxProvider+Summaries.swift
//  Dayflow
//
//  Title / summary / merge-card prompt execution for the MiniMax provider.
//  Logic mirrors OllamaProvider+Summaries.swift with a few adaptations:
//  - uses `MiniMaxPromptSections` so users can override prompts independently
//  - wraps responses in `MiniMaxReasoning.stripThinkTags` defensively
//

import Foundation

extension MiniMaxProvider {
  struct TitleSummaryResponse: Codable {
    let reasoning: String
    let title: String
    let summary: String
    let category: String
    let appSites: AppSites?
  }

  private struct SummaryResponse: Codable {
    let reasoning: String
    let summary: String
    let category: String
    let appSites: AppSitesResponse?

    struct AppSitesResponse: Codable {
      let primary: String?
      let secondary: String?
    }

    enum CodingKeys: String, CodingKey {
      case reasoning
      case summary
      case category
      case appSites = "app_sites"
    }
  }

  private struct TitleResponse: Codable {
    let reasoning: String
    let title: String
  }

  private struct MergeDecision: Codable {
    let reason: String
    let combine: Bool
  }

  private func normalizeTitleText(_ response: String) -> String {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    var result = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

    if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
      result = String(result.dropFirst().dropLast())
    }

    let lowercased = result.lowercased()
    if lowercased.hasPrefix("title:") {
      let dropped = String(result.dropFirst("title:".count))
      result = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return result
  }

  private func buildAppSites(from response: SummaryResponse.AppSitesResponse?) -> AppSites? {
    guard let response else { return nil }
    let primary = response.primary?.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = response.secondary?.trimmingCharacters(in: .whitespacesAndNewlines)

    let cleanedPrimary = primary?.isEmpty == false ? primary : nil
    let cleanedSecondary = secondary?.isEmpty == false ? secondary : nil

    if cleanedPrimary == nil && cleanedSecondary == nil {
      return nil
    }

    return AppSites(primary: cleanedPrimary, secondary: cleanedSecondary)
  }

  private func generateSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (SummaryResponse, String) {
    let observationLines: [String] = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[\(startTime) - \(endTime)]: \(obs.observation)"
    }
    let observationsText: String = stripUserReferences(observationLines.joined(separator: "\n\n"))

    let descriptorList = categories.isEmpty ? CategoryStore.descriptorsForLLM() : categories
    let categoryLines: [String] = descriptorList.enumerated().map { index, descriptor in
      var description =
        descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && description.isEmpty {
        description = "Use when the user is idle for most of the period."
      }
      let dashDescription = description.isEmpty ? "" : " — \(description)"
      return "- \"\(descriptor.name)\"\(dashDescription)"
    }
    let categoriesSection: String = categoryLines.joined(separator: "\n")

    let allowedValues: String =
      descriptorList
      .map { "\"\($0.name)\"" }
      .joined(separator: ", ")

    let promptSections = MiniMaxPromptSections(overrides: MiniMaxPromptPreferences.load())

    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
      .map { "\n\n\($0)" } ?? ""

    let basePrompt = """
      You are analyzing someone's computer activity from the last 15 minutes.

      Activity periods:
      \(observationsText)

        Create a summary that captures what happened during this time period.

      \(promptSections.summary)

      CATEGORIES:
      Choose exactly one:
      \(categoriesSection)

      APP SITES (Website Logos)
      Identify the main app or website used for this period. Output the canonical DOMAIN, not the app name.
      - primary: canonical domain of the main app/website used.
      - secondary: another meaningful app used, if relevant.
      - Format: lower-case, no protocol, no query or fragments.
      - Use product subdomains/paths when canonical (e.g., docs.google.com).
      - If you cannot determine a secondary, omit it.
      - Do not invent brands; rely on evidence from observations.

        REASONING:
        Explain your thinking process:
        1. What were the main activities and how much time was spent on each?
        2. Was this primarily work-related, personal, or brief distractions?
        3. Which category best fits based on the MAJORITY of time and focus?
        4. How did you structure the summary to capture the most important activities?

      \(languageBlock)

      Return JSON:
      {
        "reasoning": "Your step-by-step thinking process",
        "summary": "Your 2-3 sentence summary",
        "category": "\(allowedValues)",
        "app_sites": {"primary": "domain.com", "secondary": "domain.com"}
      }
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callTextAPI(
          prompt, operation: "generate_summary", expectJSON: true, batchId: batchId)

        guard let data = response.data(using: .utf8) else {
          throw NSError(
            domain: "MiniMaxProvider", code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse summary response"])
        }

        let result = try parseJSONResponse(SummaryResponse.self, from: data)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts { throw error }

        print("[MINIMAX] ⚠️ generateSummary attempt \(attempt) failed: \(error.localizedDescription)")

        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
            Respond with ONLY the JSON object described above. Ensure it contains "reasoning", "summary", "category", and "app_sites" fields.
            """
      }
    }

    throw lastError
      ?? NSError(
        domain: "MiniMaxProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary after multiple attempts"])
  }

  private func generateTitle(observations: [Observation], batchId: Int64?) async throws -> (
    TitleResponse, String
  ) {
    let promptSections = MiniMaxPromptSections(overrides: MiniMaxPromptPreferences.load())
    let languageBlock =
      LLMOutputLanguagePreferences.languageInstruction(forJSON: false)
      .map { "\n\n\($0)" } ?? ""
    let observationsText =
      observations
      .map { $0.observation.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { "- \($0)" }
      .joined(separator: "\n")

    let basePrompt = """
      \(promptSections.title)
      \(languageBlock)

      OBSERVATIONS:
      \(observationsText)
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callTextAPI(
          prompt, operation: "generate_title", expectJSON: false, batchId: batchId)
        let title = normalizeTitleText(response)
        guard !title.isEmpty else {
          throw NSError(
            domain: "MiniMaxProvider", code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Empty title response"])
        }
        let result = TitleResponse(reasoning: "Generated from observations.", title: title)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts { throw error }
        print("[MINIMAX] ⚠️ generateTitle attempt \(attempt) failed: \(error.localizedDescription)")
        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
            Respond with ONLY the title text on a single line. Do not include JSON or quotes.
            """
      }
    }

    throw lastError
      ?? NSError(
        domain: "MiniMaxProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate title after multiple attempts"])
  }

  func generateTitleAndSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (TitleSummaryResponse, String) {
    let (summaryResult, summaryLog) = try await generateSummary(
      observations: observations,
      categories: categories,
      batchId: batchId
    )

    let (titleResult, titleLog) = try await generateTitle(
      observations: observations, batchId: batchId)

    let appSites = buildAppSites(from: summaryResult.appSites)

    let combinedResult = TitleSummaryResponse(
      reasoning: "Summary: \(summaryResult.reasoning) | Title: \(titleResult.reasoning)",
      title: titleResult.title,
      summary: summaryResult.summary,
      category: summaryResult.category,
      appSites: appSites
    )

    let combinedLog =
      "=== SUMMARY GENERATION ===\n\(summaryLog)\n\n=== TITLE GENERATION ===\n\(titleLog)"

    return (combinedResult, combinedLog)
  }

  func checkShouldMerge(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (Bool, String) {
    let basePrompt = """
      Decide if two consecutive activity cards should be merged.

      Previous activity (\(previousCard.startTime) - \(previousCard.endTime)):
      Title: \(previousCard.title)
      Summary: \(previousCard.summary)

      New activity (\(newCard.startTime) - \(newCard.endTime)):
      Title: \(newCard.title)
      Summary: \(newCard.summary)

      Merge ONLY if they clearly describe the same ongoing task or intent.
      - Tool/app switches are allowed if they support the same goal (e.g., doc writing + research).
      - Do NOT merge if there’s a context switch to a different intent (social feed, chat, video, gaming, email, shopping, unrelated reading).
      - If unsure, do NOT merge.

      Return JSON only:
      {"combine": true/false, "reason": "1 short sentence explaining the decision"}

      EXAMPLES (5):

      1) MERGE
      Prev: "Drafted onboarding doc in Google Docs. Looked up API details in the Stripe docs."
      New:  "Continued the onboarding doc, then cross-checked examples in Stripe docs."
      → {"combine": true, "reason": "Same intent: onboarding doc + supporting research."}

      2) MERGE
      Prev: "Analyzed retention curves in Claude. Adjusted questions for clarity."
      New:  "Kept refining retention metrics in Claude and Notion."
      → {"combine": true, "reason": "Same intent: retention analysis across tools."}

      3) MERGE
      Prev: "Fixed React auth bug in VS Code. Ran local tests."
      New:  "Validated the auth fix in Postman and added notes to the PR."
      → {"combine": true, "reason": "Same task: auth fix and verification."}

      4) DON'T MERGE
      Prev: "Reviewed VC blog post on trohan.com."
      New:  "Watched League of Legends stream and chatted on Messenger."
      → {"combine": false, "reason": "Different intent: research vs entertainment/chat."}

      5) DON'T MERGE
      Prev: "Drafted email reply about product launch."
      New:  "Scrolled X.com and watched a YouTube clip."
      → {"combine": false, "reason": "Context switch to social/video."}
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callTextAPI(
          prompt, operation: "evaluate_card_merge", expectJSON: true, batchId: batchId)

        guard let data = response.data(using: String.Encoding.utf8) else {
          throw NSError(
            domain: "MiniMaxProvider", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse merge decision"])
        }

        let decision = try parseJSONResponse(MergeDecision.self, from: data)
        return (decision.combine, response)
      } catch {
        lastError = error
        if attempt == maxAttempts { throw error }
        print("[MINIMAX] ⚠️ evaluate_card_merge attempt \(attempt) failed: \(error.localizedDescription)")
        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
            Return ONLY the JSON object described above with "reason" and "combine" fields.
            """
      }
    }

    throw lastError
      ?? NSError(
        domain: "MiniMaxProvider", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Failed to evaluate merge decision after multiple attempts"])
  }

  func mergeTwoCards(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (ActivityCardData, String) {
    let basePrompt = """
      Create a single activity card that covers both time periods.

      Activity 1 (\(previousCard.startTime) - \(previousCard.endTime)):
      Title: \(previousCard.title)
      Summary: \(previousCard.summary)

      Activity 2 (\(newCard.startTime) - \(newCard.endTime)):
      Title: \(newCard.title)
      Summary: \(newCard.summary)

      Create a unified title and summary that covers the entire period from \(previousCard.startTime) to \(newCard.endTime).
      Title rules (use ONLY the titles and summaries above):
      - 5-10 words, natural and specific, single line
      - Choose the dominant activity (most time), not necessarily the first
      - Ignore brief interruptions (<3 minutes) mentioned in the summaries
      - Include a second activity only if both take ~5+ minutes
      - If 3+ unrelated activities appear, output exactly: "Scattered apps and sites"
      - Prefer proper nouns/topics (Bookface, Claude, League of Legends, Paul Graham, etc.)
      - Never use: worked on, looked at, handled, various, some, multiple, browsing, browse, multitasking, tabs, brief, quick, short
      - Do NOT use the word "browsing"; use "scrolling" or "reading" instead
      - Avoid long lists; no more than one conjunction
      - In the JSON below, the "title" field must contain only the title text (no extra labels or quotes)
      Summary: Two sentences max, first-person perspective without using the word I. Retell how the work flowed from the first card into the second with concrete verbs (debugged, reviewed, watched) and name the stand-out tools/topics once each. Skip laundry lists, filler like “various tasks,” and bullet points.
      Avoid the words social, media, platform, platforms, interaction, interactions, various, engaged, blend, activity, activities.
      Do not refer to the user; write from the user’s perspective.

      \(LLMOutputLanguagePreferences.languageInstruction(forJSON: true) ?? "")

        GOOD EXAMPLES:
        Card 1: Customer interviews wrap-up + Card 2: Insights deck synthesis
        Merged Title: Shaped customer story for insights deck
        Merged Summary: Logged interview quotes into Airtable. Highlighted the strongest themes and molded them into the insights deck outline.

        Card 1: QA-ing mobile release + Card 2: Answering support tickets
        Merged Title: Balanced mobile QA while clearing support
        Merged Summary: Ran through the iOS smoke checklist in TestFlight. Hopped into Help Scout to close the urgent tickets.

        BAD EXAMPLES:
        ✗ Title: Coding, gaming, and Swift fixes with AI tools and Dayflow (comma list trying to cover everything)
        ✗ Title: Busy afternoon session (too vague)
        ✗ Summary: Worked on several things across platforms (generic, missing specifics)
        ✗ Summary that omits a named site/app/topic from the inputs
        ✗ Summary longer than three sentences or formatted as bullet points

      Return JSON:
      {
        "title": "Merged title",
        "summary": "Merged summary"
      }
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    struct MergedContent: Codable {
      let title: String
      let summary: String
    }

    for attempt in 1...maxAttempts {
      do {
        let response = try await callTextAPI(
          prompt, operation: "merge_cards", expectJSON: true, batchId: batchId)

        guard let data = response.data(using: .utf8) else {
          throw NSError(
            domain: "MiniMaxProvider", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse merged card"])
        }

        let merged = try parseJSONResponse(MergedContent.self, from: data)

        let mergedCard = ActivityCardData(
          startTime: previousCard.startTime,
          endTime: newCard.endTime,
          category: previousCard.category,
          subcategory: previousCard.subcategory,
          title: merged.title,
          summary: merged.summary,
          detailedSummary: previousCard.detailedSummary,
          distractions: previousCard.distractions,
          appSites: previousCard.appSites ?? newCard.appSites
        )

        return (mergedCard, response)
      } catch {
        lastError = error
        if attempt == maxAttempts { throw error }
        print("[MINIMAX] ⚠️ merge_cards attempt \(attempt) failed: \(error.localizedDescription)")
        prompt =
          basePrompt + """


            PREVIOUS ATTEMPT FAILED — The response was invalid (error: \(error.localizedDescription)).
            Respond with ONLY the JSON object described above containing merged "title" and "summary" fields.
            """
      }
    }

    throw lastError
      ?? NSError(
        domain: "MiniMaxProvider", code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Failed to merge cards after multiple attempts"])
  }
}
