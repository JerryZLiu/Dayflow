import AppKit
import Foundation

extension GemmaBackupProvider {
  // MARK: - Summaries + Titles

  struct SummaryResponse: Codable {
    struct AppSitesResponse: Codable {
      let primary: String?
      let secondary: String?
    }
    let apps: [String]
    let people: [String]
    let main_task: String
    let summary: String
    let category: String
    let app_sites: AppSitesResponse?
  }

  struct TitleResponse: Codable {
    let title: String
  }

  struct MergeDecision: Codable {
    let combine: Bool
    let confidence: Double
    let reason: String
  }

  struct MergedContent: Codable {
    let title: String
    let summary: String
  }

  struct TitleSummaryPayload {
    let title: String
    let summary: String
    let category: String
    let appSites: AppSites?
  }

  func generateTitleAndSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (TitleSummaryPayload, String) {
    let (summaryResult, summaryLog) = try await generateSummary(
      observations: observations, categories: categories, batchId: batchId)
    let (titleResult, titleLog) = try await generateTitle(
      summary: summaryResult.summary, batchId: batchId)

    let appSites = buildAppSites(from: summaryResult.app_sites)

    let payload = TitleSummaryPayload(
      title: titleResult.title,
      summary: summaryResult.summary,
      category: summaryResult.category,
      appSites: appSites
    )

    let combinedLog =
      "=== SUMMARY GENERATION ===\n\(summaryLog)\n\n=== TITLE GENERATION ===\n\(titleLog)"
    return (payload, combinedLog)
  }

  func generateSummary(
    observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?
  ) async throws -> (SummaryResponse, String) {
    let observationLines: [String] = observations.map { obs in
      let startTime = formatTimestampForPrompt(obs.startTs)
      let endTime = formatTimestampForPrompt(obs.endTs)
      return "[\(startTime) - \(endTime)]: \(obs.observation)"
    }
    let observationsText = observationLines.joined(separator: "\n")

    let descriptorList = categories.isEmpty ? CategoryStore.descriptorsForLLM() : categories
    let categoryLines: [String] = descriptorList.enumerated().map { index, descriptor in
      var description =
        descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && description.isEmpty {
        description = "Use when the user is idle for most of the period."
      }
      let suffix = description.isEmpty ? "" : " — \(description)"
      return "\(index + 1). \"\(descriptor.name)\"\(suffix)"
    }
    let allowedValues = descriptorList.map { "\"\($0.name)\"" }.joined(separator: ", ")

    let basePrompt = """
      First extract key information, then summarize.

      Observations:
      \(observationsText)

      Step 1 - Extract from the text:
      - Apps/sites used: (list exact names)
      - People mentioned: (list names)
      - Main task: (one phrase)
      - Secondary activities: (brief list)

      Step 2 - Choose EXACTLY ONE category from the list below. Use the label exactly as written.
      \(categoryLines.joined(separator: "\n"))
      Allowed values: [\(allowedValues)]

      Step 3 - Identify appSites from the observations.
      Rules:
      - primary: canonical domain/product path of the main app used
      - secondary: another meaningful app or enclosing app (like browser)
      - Format: lower-case, no protocol, no query or fragments
      - Be specific (docs.google.com over google.com)
      - If unknown, use null

      Step 4 - Write 2-3 sentence summary focusing on main task, using extracted names. first person, without "I".

      Return JSON:
      {
        \"apps\": [\"app1\", \"app2\"],
        \"people\": [\"person1\"],
        \"main_task\": \"what they primarily did\",
        \"summary\": \"2-3 sentence summary using exact names\",
        \"category\": \"one of the allowed values above\",
        \"app_sites\": {\"primary\": \"domain.com\", \"secondary\": \"domain.com\"}
      }
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.generate_summary",
          batchId: batchId,
          temperature: 0.3,
          maxOutputTokens: 1024,
          logRequestBody: true
        )

        let result = try parseJSONResponse(SummaryResponse.self, from: response)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above. Ensure it contains apps, people, main_task, summary, category, and app_sites."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary"])
  }

  func generateTitle(summary: String, batchId: Int64?) async throws -> (
    TitleResponse, String
  ) {
    let basePrompt = """
      Create a title for the given summary

      SUMMARY: "\(summary)"

      TITLE GUIDELINES
      Core principle: If you read this title next week, would you know what you actually did?
      Be specific, but concise:
      Every title needs concrete details. Name the actual thing—the show, the person, the feature, the file, the game. But keep it scannable—aim for roughly 5-10 words. Extra details belong in the summary.

      Bad: "Watched videos" → Good: "The Office bloopers on YouTube"
      Bad: "Worked on UI" → Good: "Fixed navbar overlap on mobile"
      Bad: "Had a call" → Good: "Call with James about venue options"
      Bad: "Did research" → Good: "Comparing gyms near the new apartment"
      Bad: "Debugged issues" → Good: "Tracked down Stripe webhook failures"
      Bad: "Played games" → Good: "Civilization VI — finally beat Deity difficulty"
      Bad: "Browsed YouTube" → Good: "Veritasium video on turbulence"
      Bad: "Chatted with team" → Good: "Slack debate about monorepo vs multirepo"
      Bad: "Made a reservation" → Good: "Booked Nobu for Saturday 7pm"
      Bad: "Coded" → Good: "Built CSV export for transactions"

      Don't overload the title:
      If you're using em-dashes, parentheses, or listing 3+ things—you're probably cramming summary content into the title.

      Bad: "Apartment hunting — Zillow listings in Brooklyn, StreetEasy saved searches, and broker fee research"
      Good: "Apartment hunting in Brooklyn"
      Bad: "Weekly metrics review — signups, churn rate, MRR growth, and cohort retention"
      Good: "Weekly metrics review"
      Bad: "Call with Mom — talked about Dad's birthday, her knee surgery, and Aunt Linda's visit"
      Good: "Call with Mom"

      Avoid vague words:
      These words hide what actually happened:

      "worked on" → doing what to it?
      "looked at" → reviewing? debugging? reading?
      "handled" → fixed? ignored? escalated?
      "dealt with" → means nothing
      "various" / "some" / "multiple" → name them or pick the main one
      "deep dive" / "rabbit hole" → just say what you researched
      "sync" / "aligned" / "circled back" → say what you discussed or decided
      "browsing" / "iterations" / "analytics" → what specifically?

      Avoid repetitive structure:
      Don't start every title with a verb. Mix it up naturally:

      "Fixed the infinite scroll bug on search results"
      "Breaking Bad rewatch — season 3 finale"
      "Call with recruiter about the Stripe role"
      "AWS cost spike investigation"
      "Planning the bachelor party itinerary"
      "Stardew Valley — finished the community center"
      "iPhone vs Pixel camera comparison for Mom"
      "Morning coffee + Hacker News catch-up"

      If several titles in a row start with "Fixed... Debugged... Built... Reviewed..." — vary the structure.
      Use "and" sparingly:
      Don't use "and" to connect unrelated things. Pick the main activity for the title; the rest goes in the summary.

      Bad: "Fixed bug and replied to emails" → Good: "Fixed pagination crash" (emails in summary)
      Bad: "YouTube then coded" → Good: "Built the settings modal" (YouTube is a distraction)
      Bad: "Read articles, watched TikTok, checked Discord" → Good: "Scattered browsing" (it was scattered, just say that)

      "And" is okay when both parts serve the same goal:

      OK: "Designed and prototyped the onboarding flow"
      OK: "Researched and booked the Airbnb in Lisbon"
      OK: "Drafted and sent the investor update"

      When it's genuinely scattered:
      If there was no main focus—just bouncing between tabs—don't force a fake throughline:

      "YouTube and Twitter browsing"
      "Scattered browsing break"
      "Catching up on Reddit and Discord"

      Before finalizing: would this title help you remember what you actually did?

      Return JSON:
      {"title": "single-activity title"}
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.generate_title",
          batchId: batchId,
          temperature: 0.3,
          maxOutputTokens: 256,
          logRequestBody: true
        )

        let result = try parseJSONResponse(TitleResponse.self, from: response)
        return (result, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "Failed to generate title"])
  }

  func checkShouldMerge(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (Bool, String) {
    let basePrompt = """
      Are these two activities part of the SAME task or DIFFERENT tasks?

      PREVIOUS (\(previousCard.startTime) - \(previousCard.endTime)):
      \(previousCard.title)

      NEXT (\(newCard.startTime) - \(newCard.endTime)):
      \(newCard.title)

      SAME TASK (combine=true, confidence 0.85+):
      - Continuing the exact same work
      - Same project AND same type of work
      - Would naturally be one story

      DIFFERENT TASKS (combine=false):
      - Different projects
      - Different mental modes (coding vs browsing vs gaming)
      - Context switch happened

      Return JSON:
      {"combine": true/false, "confidence": 0.0-1.0, "reason": "why"}
      """

    let confidenceThreshold = 0.85
    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.merge_check",
          batchId: batchId,
          temperature: 0.2,
          maxOutputTokens: 256,
          logRequestBody: true
        )

        let decision = try parseJSONResponse(MergeDecision.self, from: response)
        let shouldMerge = decision.combine && decision.confidence >= confidenceThreshold
        return (shouldMerge, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Failed to evaluate merge decision"])
  }

  func mergeTwoCards(
    previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?
  ) async throws -> (ActivityCardData, String) {
    let basePrompt = """
      Combine these two cards into one.

      CARD 1 (\(previousCard.startTime) - \(previousCard.endTime)): \(previousCard.title)
      \(previousCard.summary)

      CARD 2 (\(newCard.startTime) - \(newCard.endTime)): \(newCard.title)
      \(newCard.summary)

      Create ONE title and summary for the full period.
      Title: 5-8 words, main throughline, past tense verb
      Summary: 2-3 sentences

      Return JSON:
      {"title": "merged title", "summary": "merged summary"}
      """

    let maxAttempts = 3
    var prompt = basePrompt
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let response = try await callGenerateContent(
          parts: [["text": prompt]],
          operation: "gemma.merge_cards",
          batchId: batchId,
          temperature: 0.2,
          maxOutputTokens: 512,
          logRequestBody: true
        )

        let merged = try parseJSONResponse(MergedContent.self, from: response)

        let mergedCard = ActivityCardData(
          startTime: previousCard.startTime,
          endTime: newCard.endTime,
          category: previousCard.category,
          subcategory: "",
          title: merged.title,
          summary: merged.summary,
          detailedSummary: "",
          distractions: previousCard.distractions,
          appSites: previousCard.appSites ?? newCard.appSites
        )

        return (mergedCard, response)
      } catch {
        lastError = error
        if attempt == maxAttempts {
          throw error
        }
        prompt =
          basePrompt
          + "\n\nPREVIOUS ATTEMPT FAILED — Respond with ONLY the JSON object described above."
      }
    }

    throw lastError
      ?? NSError(
        domain: "GemmaBackupProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Failed to merge cards"])
  }

}
