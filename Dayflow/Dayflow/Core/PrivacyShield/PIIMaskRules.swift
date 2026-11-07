import CryptoKit
import Foundation

/// The privacy model's labels, in the model's output order (`piigen/labels.py`).
enum PIILabel {
  static let none = 0
  static let secret = 1
  static let privateKey = 2
  static let password = 3
  static let oneTimeCode = 4
  static let secretURL = 5
  static let crypto = 6
  static let card = 7
  static let bank = 8
  static let amount = 9
  static let govID = 10
  static let email = 11
  static let phone = 12

  /// What actually gets hidden: keys and tokens, private keys, passwords, cards, bank details and government IDs.
  /// The other labels only steer the rules below.
  static let masked: Set<Int> = [secret, privateKey, password, card, bank, govID]
}

/// Turns the model's per-character scores into masks: threshold, whole-token fill, edge trimming, then the
/// rule passes, in the order and with the settings r38 was scored with on the golden set (`fa_score.POST`
/// plus plain_guesses at threshold 0.5 in the Python lab). Each rule is a direct port of the function of the
/// same name in `train_lib.py`; read that for the reasoning behind each pattern.
///
/// Two Python checks are left out: zxcvbn password strength (in passphrase_like and the "Password" line rule).
/// On all 7,995 golden and planted frames it never changed a mask.
struct PIIMaskRules {
  let threshold: Float
  /// The 2,048-word BIP39 English list, for seed phrases. Ships with the model download.
  let bip39Words: [String]
  private let bip39Set: Set<String>
  private let bip39Positions: [String: Int]

  init(threshold: Float, bip39Words: [String]) {
    self.threshold = threshold
    self.bip39Words = bip39Words
    self.bip39Set = Set(bip39Words)
    self.bip39Positions = Dictionary(
      bip39Words.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: - Entry point

  /// `sensitive[line][char]` is the model's averaged P(not "none"), `best[line][char]` its label pick.
  /// Returns one label per code point per line (0 = keep).
  func apply(lines: [PIIOCRLine], sensitive: [[Float]], best: [[Int]]) -> [[Int]] {
    let texts = lines.map { PIILineText($0.text) }
    var preds: [[Int]] = []
    for (index, text) in texts.enumerated() {
      var pred = zip(sensitive[index], best[index]).map { score, label in
        score > threshold ? label : 0
      }
      fillTokens(text, &pred)
      trimMaskedEdges(text, &pred)
      preds.append(pred)
    }
    unmaskOrphanDomains(texts, &preds)
    maskSetupKeys(texts, &preds)
    maskVaultPasswords(texts, &preds)
    unmaskPlainGuesses(texts, &preds)
    maskLabeledPasswords(texts, &preds)
    maskKeyBlocks(texts, &preds)
    unmaskOAuthNoise(texts, &preds)
    unmaskBareNumbers(texts, &preds)
    unmaskPlainURLs(texts, &preds)
    maskSeedPhrases(texts, &preds)
    maskRecoveryCodes(texts, &preds)
    maskKeyPrefixes(texts, &preds)
    return preds
  }

  // MARK: - Span completion

  /// T3 tokens: a ":" ends a token unless it starts "://", so "api:key-..." fills only the value.
  private static let tokenPattern = PIIRegex(
    #"(?:[^\s"'(),<>\[\]{}=;|:]|:(?=//))+?(?=[.,:!?]*(?:[\s"'(),<>\[\]{}=;|]|:(?!//)|$))"#)

  /// Masks the whole token around any masked character, with the token's most common label
  /// (the lowest label wins a tie, the way Python's `max(set(seeds), key=seeds.count)` picks).
  private func fillTokens(_ text: PIILineText, _ pred: inout [Int]) {
    for token in Self.tokenPattern.matches(in: text) {
      var counts: [Int: Int] = [:]
      for i in token.range where pred[i] != 0 {
        counts[pred[i], default: 0] += 1
      }
      guard !counts.isEmpty else { continue }
      let top = counts.values.max() ?? 0
      let label = counts.filter { $0.value == top }.keys.min() ?? 0
      for i in token.range where pred[i] == 0 {
        pred[i] = label
      }
    }
  }

  private static let trimLead = Set(" \t•·*.…".unicodeScalars)
  private static let trimTrail = Set(" \t•·*…".unicodeScalars)
  private static let redactionPrefix = PIIRegex(#"(?:[-–/ ]*(?:[*•]+|XX+|xx+)[-–/ ]*)+"#)

  /// Unmasks spaces and mask glyphs at the edges of each masked run, and an already-redacted prefix ("•••• ").
  private func trimMaskedEdges(_ text: PIILineText, _ pred: inout [Int]) {
    var i = 0
    while i < pred.count {
      if pred[i] == 0 {
        i += 1
        continue
      }
      var j = i
      while j < pred.count && pred[j] != 0 { j += 1 }
      var start = i
      var end = j
      while start < end && Self.trimLead.contains(text.scalars[start]) { start += 1 }
      while end > start && Self.trimTrail.contains(text.scalars[end - 1]) { end -= 1 }
      if let placeholder = Self.redactionPrefix.matchAtStart(of: text, from: start, to: end) {
        start = placeholder.end
      }
      for k in i..<start { pred[k] = 0 }
      for k in end..<j { pred[k] = 0 }
      i = j
    }
  }

  // MARK: - Run helpers

  /// (start, end, label) of each run of one nonzero label.
  private func runs(_ pred: [Int]) -> [(Int, Int, Int)] {
    var result: [(Int, Int, Int)] = []
    var i = 0
    while i < pred.count {
      if pred[i] != 0 {
        var j = i
        while j < pred.count && pred[j] == pred[i] { j += 1 }
        result.append((i, j, pred[i]))
        i = j
      } else {
        i += 1
      }
    }
    return result
  }

  private func set(_ pred: inout [Int], _ start: Int, _ end: Int, to label: Int) {
    for k in start..<min(end, pred.count) { pred[k] = label }
  }

  // MARK: - Orphan domains

  private static let fullEmail = PIIRegex(#"[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}"#)
  private static let bareDomain = PIIRegex(#"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\.?"#)

  private func unmaskOrphanDomains(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    let reach = 3
    for n in texts.indices {
      let text = texts[n]
      let nearby = texts[max(0, n - reach)..<min(texts.count, n + reach + 1)].map(\.string).joined(
        separator: "\n")
      let emailNearby = Self.fullEmail.search(nearby)
      var i = 0
      while i < preds[n].count {
        if preds[n][i] != PIILabel.email {
          i += 1
          continue
        }
        var j = i
        while j < preds[n].count && preds[n][j] == PIILabel.email { j += 1 }
        let run = PIIPython.strip(text.slice(i, j))
        let afterAt = PIIPython.rstrip(text.slice(0, i)).hasSuffix("@")
        if !run.contains("@") && !afterAt
          && (run.contains("/") || (emailNearby && Self.bareDomain.fullMatch(run)))
        {
          set(&preds[n], i, j, to: 0)
        }
        i = j
      }
    }
  }

  // MARK: - Setup keys

  private static let setupKey = PIIRegex(#"[A-Z2-7]{4}(?: ?[A-Z2-7]{4}){3,}"#)

  private func maskSetupKeys(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for n in texts.indices {
      let value = PIIPython.strip(texts[n].string)
      if Self.setupKey.fullMatch(value)
        && value.unicodeScalars.filter(PIIPython.isDigit).count >= 2,
        let start = PIIPython.index(of: value, in: texts[n].string)
      {
        set(&preds[n], start, start + PIIPython.scalarCount(value), to: PIILabel.secret)
      }
    }
  }

  // MARK: - Password managers

  private static let vaultScreen = PIIRegex(
    "bitwarden|1password|lastpass|keepass|dashlane|proton pass|password manager|password generator|"
      + "generate password|keychain access|passwords app", caseInsensitive: true)
  private static let vaultTitleWords = 5
  private static let notAPassword = PIIRegex(
    #"@|/|\.\w{2,4}$|^www\.|^(?:ctr[il1]|cmd|shift|alt|option)\W"#, caseInsensitive: true)
  private static let wordAndNumber = PIIRegex(#"[A-Z]?[a-z]+[_-]?\d{1,2}"#)
  private static let edgePunctuation = ".,;:|()[]-_…'\""

  /// One 6-40 character token with a letter and a digit or symbol, that isn't an email, link, file, shortcut,
  /// sentence end or a word with a short number on the end.
  private func passwordLike(_ value: String) -> Bool {
    let core = PIIPython.strip(value, Self.edgePunctuation)
    let length = PIIPython.scalarCount(core)
    if !(6...40).contains(length) || core.contains(" ") || Self.notAPassword.search(core)
      || Self.wordAndNumber.fullMatch(core)
    {
      return false
    }
    let scalars = core.unicodeScalars
    let hasLetter = scalars.contains(where: PIIPython.isAlpha)
    let hasDigit = scalars.contains(where: PIIPython.isDigit)
    let hasSymbol = scalars.contains {
      !PIIPython.isAlnum($0) && !"-_.".unicodeScalars.contains($0)
    }
    return hasLetter && (hasDigit || hasSymbol)
  }

  private func maskVaultPasswords(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    let isVault = texts.contains {
      Self.vaultScreen.search($0.string) && PIIPython.split($0.string).count <= Self.vaultTitleWords
    }
    guard isVault else { return }
    for n in texts.indices {
      let value = PIIPython.strip(texts[n].string)
      // passphrase_like needs zxcvbn and is left out (see the type comment).
      if passwordLike(value) && !preds[n].contains(where: { $0 != 0 }),
        let start = PIIPython.index(of: value, in: texts[n].string)
      {
        set(&preds[n], start, start + PIIPython.scalarCount(value), to: PIILabel.password)
      }
    }
  }

  // MARK: - Plain guesses

  private static let guessTime = PIIRegex(
    #"^(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w*,?\s+)?(?:[A-Z][a-z]{2}\s+\d{1,2},?\s+)?[0-9OoBSlI]{1,2}[:.][0-9OoBSlI]{2}"#
      + #"(?::[0-9OoBSlI]{2})?\s*(?:[AaPp]\.?[Mm]\.?)?$"#)
  private static let guessClock = PIIRegex(
    #"^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun|S\w?n)\S*[^\s]{0,8}[AP]M$"#)
  private static let guessCJK = PIIRegex(#"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af\uff00-\uffef]"#)
  private static let guessWords = PIIRegex(
    #"^(?:[A-Z][a-z]+(?:-[A-Za-z][a-z]+)*\+?|[a-z]+(?:['’][a-z]{1,2}|[?!]))$"#)
  private static let guessVersion = PIIRegex(#"^[A-Za-z]{2,}-\d{1,2}\.\d{1,2}$"#)
  private static let guessPercent = PIIRegex(#"^\W*\w?\d{1,3}%\W*$"#)
  private static let guessFile = PIIRegex(
    #"\.(?:mp4|mov|m4a|mp3|wav|jpe?g|png|gif|webp|heic|pdf|docx?|xlsx?|pptx?|zip|txt|csv|json|html?)$"#,
    caseInsensitive: true)
  private static let guessID = PIIRegex(
    #"^(?:req|dpl|session|sess|msg|evt|cus|ch|pi|sub|prod|price|in|inv|toolu|run|job|org|proj|acct|file|batch)_[A-Za-z0-9]{8,}$"#
  )
  private static let guessParam = PIIRegex(#"[?&](?:pl|pp|si|feature|ref|list|v|t|utm_\w+|op)=$"#)
  private static let guessPasswordContext = PIIRegex(
    #"pass(?:word|code|phrase)?\b|\bpw\b|\bpwd\b|\bpin\b|login|sign.?in|credential"#,
    caseInsensitive: true)
  private static let nonSpace = PIIRegex(#"\S+"#)
  private static let urlPath = PIIRegex(#"/[A-Za-z]{3,}"#)

  /// Unmasks guesses that are ordinary screen text: clock times, CJK, file names, known non-secret ids,
  /// number labels with no digit, and capitalized words or versions guessed as passwords with no password wording near.
  private func unmaskPlainGuesses(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    let masked = PIILabel.masked
    let numbers: Set<Int> = [PIILabel.card, PIILabel.bank, PIILabel.govID]

    func maskedRuns(_ pred: [Int]) -> [(Int, Int)] {
      var result: [(Int, Int)] = []
      var i = 0
      while i < pred.count {
        if masked.contains(pred[i]) {
          var j = i
          while j < pred.count && masked.contains(pred[j]) { j += 1 }
          result.append((i, j))
          i = j
        } else {
          i += 1
        }
      }
      return result
    }

    func clear(_ pred: inout [Int], _ start: Int, _ end: Int) {
      for k in start..<end where masked.contains(pred[k]) { pred[k] = 0 }
    }

    for index in texts.indices {
      let text = texts[index]
      let nearPassword = texts[max(0, index - 3)...index].contains {
        Self.guessPasswordContext.search($0.string)
      }

      for token in Self.nonSpace.matches(in: text) {
        let labels = token.range.map { preds[index][$0] }.filter { masked.contains($0) }
        let raw = text.slice(token.start, token.end)
        let value = PIIPython.strip(raw, ".,;:)")
        if !labels.isEmpty
          && (Self.guessCJK.search(raw)
            || (labels.contains(PIILabel.secret)
              && (Self.guessFile.search(value)
                || (Self.guessID.matchesStart(value) && !PIIPython.lower(value).contains("secret")))))
        {
          clear(&preds[index], token.start, token.end)
        }
      }

      for (start, end) in maskedRuns(preds[index]) {
        let value = PIIPython.strip(text.slice(start, end))
        let labels = Set(preds[index][start..<end]).intersection(masked)
        if Self.guessTime.matchesStart(value)
          || Self.guessParam.firstMatch(in: text, to: start) != nil
        {
          clear(&preds[index], start, end)
        } else if labels.isSubset(of: numbers)
          && !value.unicodeScalars.contains(where: PIIPython.isDigit)
        {
          clear(&preds[index], start, end)
        } else if labels == [PIILabel.card] && Self.urlPath.search(value) {
          clear(&preds[index], start, end)
        } else if labels == [PIILabel.password] && !nearPassword
          && (Self.guessWords.matchesStart(value) || Self.guessVersion.matchesStart(value)
            || Self.guessClock.matchesStart(value) || Self.guessPercent.matchesStart(value))
        {
          clear(&preds[index], start, end)
        }
      }
    }
  }

  // MARK: - Labeled passwords

  private static let cliTool = PIIRegex(
    #"\b(?:redis-cl[il1]|mysql\w*|mariadb\w*|sshpass|mongo(?:sh|dump|restore)?|mosquitto_\w+|smbclient|docker login|"#
      + #"podman login|helm registry login|rabbitmqadmin|influx|clickhouse-client)\b"#,
    caseInsensitive: true)
  private static let cliPasswordFlag = PIIRegex(
    #"\s(?:-a|-p|--pass(?:word)?|--auth)(?:\s+|=)?['"]?(?<value>[^\s'"]{4,})"#,
    groupNames: ["value"])
  private static let cliUserPass = PIIRegex(
    #"\b(?:curl|http|wget)\b.*?\s(?:-u|--user)\s+['"]?[^\s:'"]+:(?<value>[^\s'"]{4,})"#,
    groupNames: ["value"])
  private static let basicAuthPair = PIIRegex(
    #"(?:^|\s)[\w.-]{1,32}:(?<value>[^\s:/@'"]{6,40})\s+https?://"#, groupNames: ["value"])
  private static let revealedValue = PIIRegex(
    #"^\W{0,2}(?<value>[^\s•*]{8,})\s+Hide\b(?:\s+Copy)?\W*$"#, groupNames: ["value"])
  private static let passwordLine = PIIRegex(
    #"^\W*(?:wi-?fi\s+)?(?:password|passcode|passphrase|pin)\b"#, caseInsensitive: true)

  /// Masks a password handed to a command-line tool, a "user:pass https://" pair, a revealed value next to its
  /// Hide button, and the last word of a short line that starts with "Password" when that word looks like one.
  private func maskLabeledPasswords(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for n in texts.indices {
      let text = texts[n]
      var hits: [Range<Int>] = []
      if let tool = Self.cliTool.firstMatch(in: text) {
        hits += Self.cliPasswordFlag.matches(in: text, from: tool.end).compactMap {
          $0.groups["value"]
        }
      }
      hits += Self.cliUserPass.matches(in: text).compactMap { $0.groups["value"] }
      for hit in hits {
        let value = text.slice(hit.lowerBound, hit.upperBound)
        if !value.hasPrefix("-") && !PIIPython.isAllDigits(value) {  // "-p 6379" is a port
          set(&preds[n], hit.lowerBound, hit.upperBound, to: PIILabel.password)
        }
      }
      if let pair = Self.basicAuthPair.firstMatch(in: text), let value = pair.groups["value"],
        passwordLike(text.slice(value.lowerBound, value.upperBound))
      {
        set(&preds[n], value.lowerBound, value.upperBound, to: PIILabel.password)
      }
      if let revealed = Self.revealedValue.matchAtStart(of: text),
        let value = revealed.groups["value"],
        passwordLike(text.slice(value.lowerBound, value.upperBound)),
        !preds[n][value].contains(where: { $0 != 0 })
      {
        set(&preds[n], value.lowerBound, value.upperBound, to: PIILabel.secret)
      }
      let words = PIIPython.split(text.string)
      if Self.passwordLine.matchesStart(text.string) && (2...4).contains(words.count),
        let lastWord = words.last
      {
        let last = PIIPython.strip(lastWord, Self.edgePunctuation)
        // The zxcvbn alternative is left out (see the type comment).
        if PIIPython.scalarCount(last) >= 6 && !Self.passwordLine.matchesStart(last)
          && passwordLike(last),
          let start = PIIPython.lastIndex(of: last, in: text.string)
        {
          let end = start + PIIPython.scalarCount(last)
          if !preds[n][start..<min(end, preds[n].count)].contains(where: { $0 != 0 }) {
            set(&preds[n], start, end, to: PIILabel.password)
          }
        }
      }
    }
  }

  // MARK: - Private key blocks

  private static let keyBlockStart = PIIRegex("BEGIN [A-Z ]*PRIVATE KEY")
  private static let keyBlockEnd = PIIRegex("END [A-Z ]*PRIVATE KEY")
  private static let keyFileTitle = PIIRegex(
    #"(?:\bid_\w+|\w+_(?:rsa|ed25519|ecdsa|dsa)|\.pem|\.key|\.ppk)\W*$"#)
  private static let shellPrompt = PIIRegex(#"[%$#]\s"#)
  private static let keyBlockLines = 40
  private static let base64Run = PIIRegex(#"[A-Za-z0-9+/=]{8,}"#)

  private func base64Like(_ run: String) -> Bool {
    let scalars = run.unicodeScalars
    let kinds = [
      scalars.contains(where: PIIPython.isUpper), scalars.contains(where: PIIPython.isLower),
      scalars.contains(where: PIIPython.isDigit),
    ].filter { $0 }.count
    return kinds == 3 || (PIIPython.scalarCount(run) >= 30 && kinds >= 2)
  }

  private func maskKeyBlocks(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    var left = 0
    for n in texts.indices {
      let text = texts[n]
      if Self.keyBlockEnd.search(text.string) {
        left = 0
        continue
      }
      if Self.keyBlockStart.search(text.string)
        || (Self.keyFileTitle.search(text.string) && !Self.shellPrompt.search(text.string))
      {
        left = Self.keyBlockLines
        continue
      }
      if left == 0 { continue }
      left -= 1
      for run in Self.base64Run.matches(in: text) where base64Like(text.slice(run.start, run.end)) {
        for k in run.range where preds[n][k] == 0 {
          preds[n][k] = PIILabel.privateKey
        }
      }
    }
  }

  // MARK: - OAuth and plain links

  private static let oauthURL = PIIRegex(
    #"oauth|authorize|/auth\b|signin|sign-in|login|reauth|consent|ServiceLogin|accountchooser|/o/saml"#,
    caseInsensitive: true)
  private static let urlCredential = PIIRegex(
    #"access_token|refresh_token|id_token|[?&#](?:token|key|sig|signature|password|pwd|secret|code|authcode|otp|ticket)=|"#
      + #"X-Amz-Signature|X-Goog-Signature|reset|magic|verify|confirm"#, caseInsensitive: true)
  private static let oauthParamBefore = PIIRegex(
    #"(?:[?&]|\b)(?:state|nonce|code_challenge|client_id|redirect_uri|login_hint|flowName)=\s*$"#,
    caseInsensitive: true)

  private func unmaskOAuthNoise(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for n in texts.indices {
      let text = texts[n]
      for (i, j, label) in runs(preds[n]) {
        let value = text.slice(i, j)
        if label == PIILabel.secretURL && Self.oauthURL.search(value)
          && !Self.urlCredential.search(value)
        {
          set(&preds[n], i, j, to: 0)
        } else if [PIILabel.secret, PIILabel.password, PIILabel.secretURL].contains(label)
          && Self.oauthParamBefore.firstMatch(in: text, to: i) != nil
        {
          set(&preds[n], i, j, to: 0)
        }
      }
    }
  }

  private static let uuid = PIIRegex(
    #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, caseInsensitive: true)
  private static let urlPiece = PIIRegex(#"[A-Za-z0-9_\-]{16,}"#)

  /// A 16+ character link piece that mixes digits with letters, or upper with lower case (not counting UUIDs).
  private func randomPiece(_ value: String) -> Bool {
    let withoutUUIDs = PIILineText(value).removingMatches(of: Self.uuid)
    let text = PIILineText(withoutUUIDs)
    for match in Self.urlPiece.matches(in: text) {
      let piece = text.slice(match.start, match.end).unicodeScalars
      let hasDigit = piece.contains(where: PIIPython.isDigit)
      let hasUpper = piece.contains(where: PIIPython.isUpper)
      let hasLower = piece.contains(where: PIIPython.isLower)
      if (hasDigit && (hasUpper || hasLower))
        || (hasUpper && hasLower && piece.filter(PIIPython.isUpper).count >= 3)
      {
        return true
      }
    }
    return false
  }

  private func unmaskPlainURLs(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for n in texts.indices {
      for (i, j, label) in runs(preds[n]) where label == PIILabel.secretURL {
        let value = texts[n].slice(i, j)
        if !Self.urlCredential.search(value) && !randomPiece(value) {
          set(&preds[n], i, j, to: 0)
        }
      }
    }
  }

  // MARK: - Bare numbers

  private static let secretWords = PIIRegex(
    #"pass|pwd|\bpin\b|code|key|token|secret|api|auth|bearer|credential|login|sign.?in|ssn|account|routing|"#
      + #"iban|card|cvv|wi-?fi|combo|combination"#, caseInsensitive: true)

  /// Unmasks a PASSWORD/SECRET run of 8 or fewer digits with no password, PIN, code or key word on its line or the two above.
  private func unmaskBareNumbers(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for index in texts.indices {
      let nearby = texts[max(0, index - 2)...index].map(\.string).joined(separator: " ")
      if Self.secretWords.search(nearby) { continue }
      for (i, j, label) in runs(preds[index]) {
        let value = PIIPython.strip(texts[index].slice(i, j), " .,:;()")
        if (label == PIILabel.secret || label == PIILabel.password) && PIIPython.isAllDigits(value)
          && PIIPython.scalarCount(value) <= 8
        {
          set(&preds[index], i, j, to: 0)
        }
      }
    }
  }

  // MARK: - Seed phrases

  private static let seedContext = PIIRegex(
    #"recovery|seed|mnemonic|secret phrase|backup phrase|passphrase|wallet|\bwords?\b"#,
    caseInsensitive: true)
  private static let seedNumber = PIIRegex(#"\d{1,2}[.):]?"#)
  private static let seedLengths = [12, 15, 18, 21, 24]
  private static let seedContextLines = 4

  /// The (start, end, word) of each seed word on a line and its slot numbers, or nil when the line holds anything else.
  private func seedLineWords(_ text: PIILineText, wordlist: Set<String>) -> (
    words: [(Int, Int, String)], numbers: [Int]
  )? {
    var words: [(Int, Int, String)] = []
    var numbers: [Int] = []
    var afterNumber = false
    for token in Self.nonSpace.matches(in: text) {
      let raw = text.slice(token.start, token.end)
      if Self.seedNumber.fullMatch(raw) {
        let digits = PIIPython.strip(raw, ".):").unicodeScalars.compactMap {
          $0.properties.numericValue
        }
        numbers.append(digits.reduce(0) { $0 * 10 + Int($1) })
        afterNumber = true
        continue
      }
      let word = PIIPython.lower(PIIPython.strip(raw, ".,;:()[]\"'"))
      let length = PIIPython.scalarCount(word)
      let isWord =
        wordlist.contains(word)
        || (afterNumber && word.unicodeScalars.allSatisfy(PIIPython.isAlpha)
          && (3...8).contains(length))
      if word.isEmpty || !isWord { return nil }
      guard let offset = PIIPython.index(of: word, in: PIIPython.lower(raw)) else { return nil }
      let start = token.start + offset
      words.append((start, start + length, word))
      afterNumber = false
    }
    return (words, numbers)
  }

  /// Masks a wallet recovery phrase: a block of lines holding only 12+ seed words and slot numbers, when the slots
  /// count up from 1, a recovery/seed/wallet word is near, or the BIP39 checksum passes.
  private func maskSeedPhrases(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    let wordlist = bip39Set
    guard !wordlist.isEmpty else { return }
    var block: [(index: Int, words: [(Int, Int, String)], numbers: [Int])] = []

    func finish() {
      defer { block.removeAll() }
      let words = block.flatMap(\.words)
      let numbers = block.flatMap(\.numbers)
      guard words.count >= 12, let first = block.first?.index, let last = block.last?.index else {
        return
      }
      let nearby = texts[max(0, first - Self.seedContextLines)...last].map(\.string).joined(
        separator: " ")
      let counted =
        numbers.sorted() == Array(stride(from: 1, through: numbers.count, by: 1))
        && numbers.count >= words.count / 2
      if counted || Self.seedContext.search(nearby) || seedChecksumOK(words.map(\.2)) {
        for entry in block {
          for (start, end, _) in entry.words {
            set(&preds[entry.index], start, end, to: PIILabel.secret)
          }
        }
      }
    }

    for index in texts.indices {
      if let found = seedLineWords(texts[index], wordlist: wordlist), !found.words.isEmpty {
        block.append((index, found.words, found.numbers))
      } else {
        finish()
      }
    }
    finish()
  }

  /// True when some 12/15/18/21/24-word stretch passes the BIP39 checksum (python-mnemonic's `check`).
  private func seedChecksumOK(_ words: [String]) -> Bool {
    let positions = bip39Positions
    for n in Self.seedLengths where words.count >= n {
      for i in 0...(words.count - n) {
        let stretch = words[i..<(i + n)].map { $0.decomposedStringWithCompatibilityMapping }
        if bip39Check(stretch, positions: positions) { return true }
      }
    }
    return false
  }

  private func bip39Check(_ words: [String], positions: [String: Int]) -> Bool {
    var bits: [Bool] = []
    for word in words {
      guard let position = positions[word] else { return false }
      for shift in stride(from: 10, through: 0, by: -1) {
        bits.append((position >> shift) & 1 == 1)
      }
    }
    let checksumLength = bits.count / 33
    let entropyLength = checksumLength * 32
    var entropy = [UInt8](repeating: 0, count: entropyLength / 8)
    for i in 0..<entropyLength where bits[i] {
      entropy[i / 8] |= 1 << (7 - UInt8(i % 8))
    }
    let digest = Array(SHA256.hash(data: entropy))
    for i in 0..<checksumLength {
      let expected = (digest[i / 8] >> (7 - UInt8(i % 8))) & 1 == 1
      if bits[entropyLength + i] != expected { return false }
    }
    return true
  }

  // MARK: - Recovery codes

  private static let recoveryContext = PIIRegex(
    #"recovery|backup code|back-up code|scratch code|emergency (?:kit|code)"#, caseInsensitive: true
  )
  private static let recoveryContextLines = 8

  /// Relabels one-time codes as SECRET under a recovery or backup code heading (on the line or the eight above).
  private func maskRecoveryCodes(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for index in preds.indices where preds[index].contains(PIILabel.oneTimeCode) {
      let nearby = texts[max(0, index - Self.recoveryContextLines)...index].map(\.string).joined(
        separator: " ")
      if Self.recoveryContext.search(nearby) {
        preds[index] = preds[index].map { $0 == PIILabel.oneTimeCode ? PIILabel.secret : $0 }
      }
    }
  }

  // MARK: - Key prefixes

  private static let keyPrefix = PIIRegex(
    #"(?<![A-Za-z0-9])(?:sk-(?:proj-|ant-(?:api\d\d-)?)?[A-Za-z0-9_-]{10,}|[sr]k_(?:live|test)_[A-Za-z0-9]{10,}"#
      + #"|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_\w{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{12,}|glpat-[\w-]{16,}"#
      + #"|whsec_\w{16,}|npm_\w{20,}|hf_\w{20,}|AIza[\w-]{20,}|fw_\w{15,}|figd_[\w-]{16,}|shp(?:at|ss|ca)_\w{16,}"#
      + #"|sq0(?:atp|csp)-[\w-]{16,}|dop_v1_\w{20,})"#)

  /// Masks tokens with a well-known secret key prefix (sk-, ghp_, xoxb-, AKIA, ...) as SECRET. Runs last.
  private func maskKeyPrefixes(_ texts: [PIILineText], _ preds: inout [[Int]]) {
    for n in texts.indices {
      for match in Self.keyPrefix.matches(in: texts[n]) {
        for i in match.range where preds[n][i] == 0 {
          preds[n][i] = PIILabel.secret
        }
      }
    }
  }
}

extension PIILineText {
  /// The text with every match of `regex` removed, like Python's `regex.sub("", text)`.
  func removingMatches(of regex: PIIRegex) -> String {
    var result = String.UnicodeScalarView()
    var cursor = 0
    for match in regex.matches(in: self) {
      result.append(contentsOf: scalars[cursor..<match.start])
      cursor = match.end
    }
    result.append(contentsOf: scalars[cursor..<count])
    return String(result)
  }
}
