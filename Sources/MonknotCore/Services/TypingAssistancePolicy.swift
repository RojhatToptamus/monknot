import Foundation

public struct TypingAssistanceScheduler {
    public let pauseTriggerMilliseconds: Int
    public let fastInterKeyMilliseconds: Int
    public let completionEnabled: Bool

    public init(
        pauseTriggerMilliseconds: Int = 350,
        fastInterKeyMilliseconds: Int = 120,
        completionEnabled: Bool = false
    ) {
        precondition(pauseTriggerMilliseconds > 0)
        precondition(fastInterKeyMilliseconds > 0)
        self.pauseTriggerMilliseconds = pauseTriggerMilliseconds
        self.fastInterKeyMilliseconds = fastInterKeyMilliseconds
        self.completionEnabled = completionEnabled
    }

    public func decide(
        _ event: TypingAssistanceEditorEvent
    ) -> TypingAssistanceScheduleDecision {
        if event.kind == .textChange || event.kind == .focusLost {
            return silent(
                reason: event.kind == .textChange ? "typing_active" : "focus_lost",
                cancelPending: true
            )
        }
        if event.contentMode == .code {
            return silent(reason: "code_mode_not_supported", cancelPending: true)
        }
        if event.kind == .wordBoundary {
            return TypingAssistanceScheduleDecision(
                intent: .wordBoundaryCorrection,
                reason: "completed_token_available",
                cancelPending: true,
                modelCallAllowed: false,
                automaticApplicationAllowed: false,
                visibleSuggestionAllowed: false
            )
        }
        if event.kind == .pause {
            guard event.idleMilliseconds >= pauseTriggerMilliseconds else {
                return silent(reason: "pause_below_threshold", cancelPending: false)
            }
            return TypingAssistanceScheduleDecision(
                intent: .pauseGrammar,
                reason: "pause_threshold_met",
                cancelPending: true,
                modelCallAllowed: true,
                automaticApplicationAllowed: false,
                visibleSuggestionAllowed: true
            )
        }
        guard completionEnabled else {
            return silent(reason: "completion_disabled", cancelPending: false)
        }
        return TypingAssistanceScheduleDecision(
            intent: .completion,
            reason: "explicit_completion_request",
            cancelPending: true,
            modelCallAllowed: true,
            automaticApplicationAllowed: false,
            visibleSuggestionAllowed: true
        )
    }

    private func silent(
        reason: String,
        cancelPending: Bool
    ) -> TypingAssistanceScheduleDecision {
        TypingAssistanceScheduleDecision(
            intent: .silent,
            reason: reason,
            cancelPending: cancelPending,
            modelCallAllowed: false,
            automaticApplicationAllowed: false,
            visibleSuggestionAllowed: false
        )
    }
}

public enum TypingAssistanceContextExtractor {
    public static let maximumCorrectionUTF16Length = 1_200
    public static let maximumCompletionPrefixUTF16Length = 600

    public static func correctionContext(
        for snapshot: TypingAssistanceEditorSnapshot
    ) -> TypingAssistanceContext? {
        guard snapshot.selectionLength == 0 else { return nil }
        let source = snapshot.text as NSString
        let cursor = boundedCursor(snapshot.cursorUTF16Offset, in: source)
        let paragraph = source.paragraphRange(for: NSRange(location: cursor, length: 0))
        let trimmed = trimNewlines(from: paragraph, in: source)
        guard trimmed.length > 0,
              trimmed.length <= maximumCorrectionUTF16Length
        else {
            return nil
        }
        return TypingAssistanceContext(
            text: source.substring(with: trimmed),
            range: trimmed
        )
    }

    public static func completionContext(
        for snapshot: TypingAssistanceEditorSnapshot
    ) -> TypingAssistanceContext? {
        guard snapshot.selectionLength == 0 else { return nil }
        let source = snapshot.text as NSString
        let cursor = boundedCursor(snapshot.cursorUTF16Offset, in: source)
        guard cursor > 0 else { return nil }
        let start = max(0, cursor - maximumCompletionPrefixUTF16Length)
        let range = NSRange(location: start, length: cursor - start)
        return TypingAssistanceContext(text: source.substring(with: range), range: range)
    }

    private static func boundedCursor(_ cursor: Int, in text: NSString) -> Int {
        max(0, min(cursor, text.length))
    }

    private static func trimNewlines(from range: NSRange, in text: NSString) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        let newlines = CharacterSet.newlines
        while lower < upper,
              let scalar = UnicodeScalar(text.character(at: lower)),
              newlines.contains(scalar) {
            lower += 1
        }
        while upper > lower,
              let scalar = UnicodeScalar(text.character(at: upper - 1)),
              newlines.contains(scalar) {
            upper -= 1
        }
        return NSRange(location: lower, length: upper - lower)
    }
}

public enum TypingAssistanceTechnicalContextClassifier {
    public static func shouldSuppressAssistance(
        in snapshot: TypingAssistanceEditorSnapshot,
        targetRange: NSRange? = nil
    ) -> Bool {
        let source = snapshot.text as NSString
        let cursor = max(0, min(snapshot.cursorUTF16Offset, source.length))
        let location = min(targetRange?.location ?? cursor, source.length)
        let lineRange = source.lineRange(
            for: NSRange(location: location, length: 0)
        )
        let line = source.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if isInsideFence(source: source, lineStart: lineRange.location)
            || isFenceDelimiter(trimmed)
            || line.hasPrefix("    ")
            || line.hasPrefix("\t") {
            return true
        }

        let localTarget = targetRange.map {
            NSRange(
                location: $0.location - lineRange.location,
                length: $0.length
            )
        }
        let inlineCode = inlineCodeRanges(in: line)
        if coversTrimmedLine(inlineCode, line: line)
            || intersectsAny(localTarget, ranges: inlineCode) {
            return true
        }

        let technicalTokens = technicalTokenRanges(in: line)
        if coversTrimmedLine(technicalTokens, line: line)
            || intersectsAny(localTarget, ranges: technicalTokens) {
            return true
        }

        return isCommandLine(trimmed) || isCodeLine(trimmed)
    }

    private struct FenceDelimiter {
        let marker: unichar
        let length: Int
    }

    private static let commandNames: Set<String> = [
        "bash", "bundle", "cargo", "cat", "chmod", "cmake", "code",
        "cp", "docker", "find", "fish", "git", "go", "gradle", "grep",
        "head", "helm", "java", "javac", "jq", "kubectl", "less", "ls",
        "make", "mkdir", "mv", "ninja", "node", "npm", "npx", "open",
        "pip", "pip3", "pnpm", "podman", "pwd", "python", "python3",
        "rg", "rm", "rsync", "ruby", "rustc", "scp", "sed", "sh",
        "ssh", "swift", "tail", "terraform", "test", "touch", "uv",
        "xed", "xcodebuild", "yarn", "zsh",
    ]
    private static let ambiguousCommandNames: Set<String> = [
        "code", "find", "go", "head", "less", "make", "open", "tail",
    ]
    private static let toolCommandNames: Set<String> = [
        "cargo", "docker", "git", "kubectl", "node", "npm", "swift",
    ]
    private static let standaloneCommandNames: Set<String> = ["ls", "pwd"]
    private static let commandActions: Set<String> = [
        "add", "apply", "branch", "build", "check", "checkout", "ci",
        "clean", "clone", "commit", "compose", "config", "container",
        "delete", "describe", "diff", "doctor", "exec", "fetch", "fmt",
        "format", "get", "image", "init", "install", "list", "log",
        "logs", "merge", "package", "publish", "pull", "push", "remove",
        "reset", "resolve", "restart", "restore", "rollout", "run",
        "show", "start", "status", "stop", "switch", "tag", "test",
        "update", "upgrade", "worktree",
    ]
    private static let commandWrappers: Set<String> = [
        "command", "env", "nohup", "sudo", "time",
    ]
    private static let prosePredicates: Set<String> = [
        "are", "be", "been", "being", "can", "could", "does", "feels",
        "had", "has", "have", "helped", "helps", "is", "made", "makes",
        "may", "means", "might", "must", "seems", "should", "sounds",
        "was", "were", "will", "works", "would",
    ]
    private static let technicalTokenExpressions = [
        expression(
            #"[A-Za-z][A-Za-z0-9+.-]{1,31}://[^\s<>()\[\]{}\"']+"#
        ),
        expression(#"mailto:[^\s<>()\[\]{}\"']+"#),
        expression(
            #"(?<![A-Za-z0-9_])\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}|[0-9#?*@!$-])"#
        ),
        expression(
            #"(?<![A-Za-z0-9_])(?:[A-Za-z]:\\|\\\\)[^\s<>"|]+"#
        ),
        expression(
            #"(?<![A-Za-z0-9_])(?:~|/|\./|\.\./)[A-Za-z0-9_./~:@%+=,-]+"#
        ),
        expression(
            #"(?<![A-Za-z0-9_])[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+(?![A-Za-z0-9_])"#
        ),
        expression(
            #"(?<![A-Za-z0-9_])--?[A-Za-z][A-Za-z0-9-]*(?:=[^\s]+)?"#
        ),
        expression(#"(?<![A-Za-z0-9_])[A-Z_][A-Z0-9_]*=[^\s]+"#),
        expression(
            #"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_.]*\([^)\n]*\)?"#
        ),
    ]
    private static let environmentAssignmentExpression = expression(
        #"^[A-Za-z_][A-Za-z0-9_]*=[^\s]+$"#
    )
    private static let shellVariableExpression = expression(
        #"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}|[0-9#?*@!$-])$"#
    )
    private static let fileNameExpression = expression(
        #"^[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,12}$"#
    )
    private static let windowsPathExpression = expression(
        #"^(?:[A-Za-z]:\\|\\\\)[^\s<>"|]+$"#
    )
    private static let shellOperatorExpression = expression(
        #"(?:^|\s)(?:&&|\|\||[|;<>])(?:\s|$)"#
    )
    private static let completeCallExpression = expression(
        #"^[A-Za-z_][A-Za-z0-9_.]*\([^)\n]*\)\s*;?$"#
    )
    private static let assignmentExpression = expression(
        #"^(?:(?:let|var|const)\s+)?[A-Za-z_][A-Za-z0-9_.]*(?:\[[^\]]+\])?\s*(?:=|\+=|-=|\*=|/=)\s*\S.*$"#
    )

    private static func isInsideFence(
        source: NSString,
        lineStart: Int
    ) -> Bool {
        guard lineStart > 0 else { return false }
        let prefix = source.substring(
            with: NSRange(location: 0, length: lineStart)
        )
        var fence: FenceDelimiter?
        for line in prefix.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                if closesFence(trimmed, delimiter: activeFence) {
                    fence = nil
                }
            } else if let opening = fenceDelimiter(in: trimmed) {
                fence = opening
            }
        }
        return fence != nil
    }

    private static func isFenceDelimiter(_ text: String) -> Bool {
        fenceDelimiter(in: text) != nil
    }

    private static func fenceDelimiter(in text: String) -> FenceDelimiter? {
        let source = text as NSString
        guard source.length >= 3 else { return nil }
        let marker = source.character(at: 0)
        guard marker == 96 || marker == 126 else { return nil }
        var length = 1
        while length < source.length,
              source.character(at: length) == marker {
            length += 1
        }
        guard length >= 3 else { return nil }
        return FenceDelimiter(marker: marker, length: length)
    }

    private static func closesFence(
        _ text: String,
        delimiter: FenceDelimiter
    ) -> Bool {
        guard let candidate = fenceDelimiter(in: text),
              candidate.marker == delimiter.marker,
              candidate.length >= delimiter.length
        else {
            return false
        }
        let source = text as NSString
        let remainder = source.substring(
            from: candidate.length
        ).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty
    }

    private static func inlineCodeRanges(in line: String) -> [NSRange] {
        let source = line as NSString
        var ranges: [NSRange] = []
        var opening: (location: Int, length: Int)?
        var index = 0
        while index < source.length {
            guard source.character(at: index) == 96 else {
                index += 1
                continue
            }
            let runStart = index
            while index < source.length,
                  source.character(at: index) == 96 {
                index += 1
            }
            let runLength = index - runStart
            if let start = opening {
                if runLength == start.length {
                    ranges.append(
                        NSRange(
                            location: start.location,
                            length: index - start.location
                        )
                    )
                    opening = nil
                }
            } else {
                opening = (runStart, runLength)
            }
        }
        if let opening {
            ranges.append(
                NSRange(
                    location: opening.location,
                    length: source.length - opening.location
                )
            )
        }
        return ranges
    }

    private static func technicalTokenRanges(in line: String) -> [NSRange] {
        let range = NSRange(location: 0, length: (line as NSString).length)
        var ranges: [NSRange] = []
        for expression in technicalTokenExpressions {
            ranges.append(
                contentsOf: expression.matches(in: line, range: range)
                    .map(\.range)
            )
        }
        return ranges
    }

    private static func coversTrimmedLine(
        _ ranges: [NSRange],
        line: String
    ) -> Bool {
        guard !ranges.isEmpty else { return false }
        let source = line as NSString
        let covered = ranges.reduce(into: IndexSet()) { indexes, range in
            indexes.insert(integersIn: range.location..<NSMaxRange(range))
        }
        for index in 0..<source.length {
            if covered.contains(index) {
                continue
            }
            guard let scalar = UnicodeScalar(source.character(at: index)),
                  CharacterSet.whitespaces.contains(scalar)
            else {
                return false
            }
        }
        return true
    }

    private static func intersectsAny(
        _ target: NSRange?,
        ranges: [NSRange]
    ) -> Bool {
        guard let target, target.location >= 0 else { return false }
        return ranges.contains {
            NSIntersectionRange(target, $0).length > 0
        }
    }

    private static func isCommandLine(_ line: String) -> Bool {
        var commandText = line
        var hasExplicitInvocation = false
        if commandText.hasPrefix("$ ") || commandText.hasPrefix("% ") {
            commandText = String(commandText.dropFirst(2))
            hasExplicitInvocation = true
        }

        var tokens = commandText.split(
            whereSeparator: \.isWhitespace
        ).map(String.init)
        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
            hasExplicitInvocation = true
        }
        if let first = tokens.first,
           commandWrappers.contains(first.lowercased()) {
            tokens.removeFirst()
            hasExplicitInvocation = true
            while let first = tokens.first, isEnvironmentAssignment(first) {
                tokens.removeFirst()
            }
        }
        guard let command = tokens.first else {
            return hasExplicitInvocation
        }
        if isExecutablePath(command) {
            return true
        }
        if hasExplicitInvocation {
            return true
        }
        let normalizedCommand = command.lowercased()
        guard command == normalizedCommand,
              commandNames.contains(normalizedCommand)
        else {
            return false
        }
        guard tokens.count >= 2 else {
            return standaloneCommandNames.contains(normalizedCommand)
        }

        let arguments = Array(tokens.dropFirst())
        if containsShellOperator(commandText)
            || arguments.contains(where: isTechnicalArgument) {
            return true
        }
        if looksLikeProseMention(arguments) {
            return false
        }
        if !ambiguousCommandNames.contains(normalizedCommand) {
            if toolCommandNames.contains(normalizedCommand) {
                return arguments.count == 1
                    || commandActions.contains(normalizedWord(arguments[0]))
            }
            return true
        }
        return commandActions.contains(normalizedWord(arguments[0]))
    }

    private static func isExecutablePath(_ token: String) -> Bool {
        let path = token.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'")
        )
        let lowercased = path.lowercased()
        if path == "." || path == ".."
            || path.hasPrefix("/")
            || path.hasPrefix("./")
            || path.hasPrefix("../")
            || path.hasPrefix("~/")
            || path.contains("/")
            || matches(path, expression: windowsPathExpression) {
            return true
        }
        return [".bat", ".cmd", ".command", ".com", ".exe", ".ps1", ".sh"]
            .contains { lowercased.hasSuffix($0) }
    }

    private static func isTechnicalArgument(_ token: String) -> Bool {
        if token.hasPrefix("-") && token != "-" {
            return true
        }
        return isExecutablePath(token)
            || isEnvironmentAssignment(token)
            || matches(token, expression: shellVariableExpression)
            || matches(token, expression: fileNameExpression)
    }

    private static func containsShellOperator(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return shellOperatorExpression.firstMatch(
            in: line,
            range: range
        ) != nil
    }

    private static func looksLikeProseMention(_ arguments: [String]) -> Bool {
        arguments.prefix(3).contains {
            prosePredicates.contains(normalizedWord($0))
        }
    }

    private static func normalizedWord(_ token: String) -> String {
        token.trimmingCharacters(
            in: .punctuationCharacters
        ).lowercased()
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        matches(token, expression: environmentAssignmentExpression)
    }

    private static func isCodeLine(_ line: String) -> Bool {
        matches(line, expression: completeCallExpression)
            || matches(line, expression: assignmentExpression)
    }

    private static func matches(
        _ text: String,
        expression: NSRegularExpression
    ) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.firstMatch(in: text, range: range)?.range == range
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid technical-context pattern")
        }
        return expression
    }
}

public enum TypingAssistanceAcceptancePolicy {
    public static func apply(
        _ suggestion: TypingAssistanceSuggestion,
        to snapshot: TypingAssistanceEditorSnapshot
    ) -> TypingAssistanceApplicationResult {
        if suggestion.sourceDocumentID != snapshot.documentID {
            return rejected(snapshot, .documentChanged)
        }
        if suggestion.sourceRevision != snapshot.revision {
            return rejected(snapshot, .revisionChanged)
        }
        if suggestion.sourceText != snapshot.text {
            return rejected(snapshot, .textChanged)
        }
        if suggestion.sourceCursorUTF16Offset != snapshot.cursorUTF16Offset {
            return rejected(snapshot, .cursorChanged)
        }
        if suggestion.sourceSelectionUTF16Location
            != snapshot.selectionUTF16Location
            || suggestion.sourceSelectionLength != snapshot.selectionLength {
            return rejected(snapshot, .selectionChanged)
        }

        let source = snapshot.text as NSString
        guard suggestion.replacementRange.location >= 0,
              suggestion.replacementRange.length >= 0,
              NSMaxRange(suggestion.replacementRange) <= source.length
        else {
            return rejected(snapshot, .invalidRange)
        }

        let replacement = replacementText(
            for: suggestion,
            in: source
        )
        let updated = source.replacingCharacters(
            in: suggestion.replacementRange,
            with: replacement
        )
        let cursor = suggestion.replacementRange.location + (replacement as NSString).length
        return TypingAssistanceApplicationResult(
            accepted: true,
            text: updated,
            selectedRange: NSRange(location: cursor, length: 0),
            rejection: nil
        )
    }

    private static func rejected(
        _ snapshot: TypingAssistanceEditorSnapshot,
        _ rejection: TypingAssistanceApplicationRejection
    ) -> TypingAssistanceApplicationResult {
        TypingAssistanceApplicationResult(
            accepted: false,
            text: snapshot.text,
            selectedRange: NSRange(
                location: snapshot.selectionUTF16Location,
                length: snapshot.selectionLength
            ),
            rejection: rejection
        )
    }

    private static func replacementText(
        for suggestion: TypingAssistanceSuggestion,
        in source: NSString
    ) -> String {
        let trimmed = suggestion.replacementText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard suggestion.requestKind == .completion, !trimmed.isEmpty else {
            return suggestion.replacementText
        }

        let location = suggestion.replacementRange.location
        let needsLeadingSpace = location > 0
            && !isSpacingOrOpeningPunctuation(source.character(at: location - 1))
        let needsTrailingSpace = location < source.length
            && !isSpacingOrClosingPunctuation(source.character(at: location))
        return (needsLeadingSpace ? " " : "")
            + trimmed
            + (needsTrailingSpace ? " " : "")
    }

    private static func isSpacingOrOpeningPunctuation(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || "([{\"'".unicodeScalars.contains(scalar)
    }

    private static func isSpacingOrClosingPunctuation(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || ".,;:!?)]}\"'".unicodeScalars.contains(scalar)
    }
}

public struct TypingAssistanceWordBoundaryCorrector {
    public static let conservativeDefaults = [
        "adn": "and",
        "becuase": "because",
        "definately": "definitely",
        "occured": "occurred",
        "recieve": "receive",
        "seperate": "separate",
        "teh": "the",
        "thier": "their",
        "wich": "which",
    ]

    public let replacements: [String: String]

    public init(replacements: [String: String] = conservativeDefaults) {
        self.replacements = replacements
    }

    public func edit(
        for snapshot: TypingAssistanceEditorSnapshot
    ) -> TypingAssistanceTextEdit? {
        guard snapshot.selectionLength == 0 else { return nil }
        let source = snapshot.text as NSString
        let cursor = max(0, min(snapshot.cursorUTF16Offset, source.length))
        guard cursor >= 2,
              isBoundary(source.character(at: cursor - 1))
        else {
            return nil
        }

        var start = cursor - 1
        while start > 0, isASCIIAlpha(source.character(at: start - 1)) {
            start -= 1
        }
        let range = NSRange(location: start, length: cursor - 1 - start)
        guard range.length > 0 else { return nil }
        if start > 0, isTechnicalJoiner(source.character(at: start - 1)) {
            return nil
        }

        let word = source.substring(with: range)
        guard !TypingAssistanceTechnicalContextClassifier.shouldSuppressAssistance(
            in: snapshot,
            targetRange: range
        ),
        let replacement = replacements[word.lowercased()]
        else {
            return nil
        }
        return TypingAssistanceTextEdit(
            range: range,
            replacementText: matchCase(replacement, source: word)
        )
    }

    private func matchCase(_ replacement: String, source: String) -> String {
        if source == source.uppercased() {
            return replacement.uppercased()
        }
        if source.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private func isBoundary(_ character: unichar) -> Bool {
        character == 9 || character == 10 || character == 13 || character == 32
    }

    private func isASCIIAlpha(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private func isTechnicalJoiner(_ character: unichar) -> Bool {
        character == 45 || character == 46 || character == 47 || character == 95
    }
}

public enum TypingAssistanceSafetyPolicy {
    public static func allowsCorrection(original: String, corrected: String) -> Bool {
        guard !corrected.isEmpty else { return false }
        for span in protectedSpans(in: original) where !corrected.contains(span) {
            return false
        }
        guard canonicalNegations(in: original) == canonicalNegations(in: corrected),
              canonicalModals(in: original) == canonicalModals(in: corrected)
        else {
            return false
        }
        return lexicallyLocal(original: original, corrected: corrected)
    }

    public static func protectedSpans(in text: String) -> [String] {
        let patterns = [
            #"https?://[^\s)>\]\"']+"#,
            #"`[^`]+`"#,
            #"(?<!\w)--?[A-Za-z][\w-]*"#,
            #"(?:~|/|\./|\.\./)[A-Za-z0-9_./~:-]+"#,
            #"\b[A-Z][A-Z0-9_]{2,}\b"#,
            #"\b[A-Za-z]+[A-Za-z0-9_.-]*:[A-Za-z0-9_.-]+\b"#,
            #"\b[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+\b"#,
            #"\b[A-Za-z0-9]*[a-z][A-Z][A-Za-z0-9]*\b"#,
            #"\b[A-Z][a-z]{1,}\b"#,
        ]
        var spans: [String] = []
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            for match in expression.matches(in: text, range: fullRange) {
                let value = (text as NSString).substring(with: match.range)
                if !spans.contains(value) {
                    spans.append(value)
                }
            }
        }
        return spans
    }

    private static let negationCanonical = [
        "not": "not", "no": "no", "never": "never", "cannot": "not",
        "can't": "not", "cant": "not", "don't": "not", "dont": "not",
        "doesn't": "not", "doesnt": "not", "dosnt": "not", "didn't": "not",
        "didnt": "not", "won't": "not", "wont": "not", "wouldn't": "not",
        "wouldnt": "not", "shouldn't": "not", "shouldnt": "not",
        "isn't": "not", "isnt": "not", "aren't": "not", "arent": "not",
        "without": "without",
    ]
    private static let modalCanonical = [
        "can": "can", "could": "could", "should": "should", "shoud": "should",
        "must": "must", "may": "may", "might": "might", "will": "will",
        "would": "would", "shall": "shall",
    ]
    private static let grammarGroups = [
        Set(["a", "an"]),
        Set(["am", "is", "are", "was", "were", "be", "been", "being"]),
        Set(["do", "does", "did"]),
        Set(["have", "has", "had"]),
    ]
    private static let safeInsertions = Set([
        "am", "are", "be", "been", "being", "did", "do", "does", "had", "has",
        "have", "is", "to", "was", "were",
    ])
    private static let contractionCanonical: [[String]: [String]] = [
        ["arent"]: ["are", "not"], ["aren't"]: ["are", "not"],
        ["cant"]: ["can", "not"], ["can't"]: ["can", "not"],
        ["cannot"]: ["can", "not"], ["couldnt"]: ["could", "not"],
        ["couldn't"]: ["could", "not"], ["didnt"]: ["did", "not"],
        ["didn't"]: ["did", "not"], ["doesnt"]: ["does", "not"],
        ["doesn't"]: ["does", "not"], ["dosnt"]: ["does", "not"],
        ["dont"]: ["do", "not"], ["don't"]: ["do", "not"],
        ["isnt"]: ["is", "not"], ["isn't"]: ["is", "not"],
        ["shouldnt"]: ["should", "not"], ["shouldn't"]: ["should", "not"],
        ["wont"]: ["will", "not"], ["won't"]: ["will", "not"],
        ["wouldnt"]: ["would", "not"], ["wouldn't"]: ["would", "not"],
    ]

    private static func canonicalNegations(in text: String) -> [String] {
        words(in: text).compactMap { negationCanonical[$0] }
    }

    private static func canonicalModals(in text: String) -> [String] {
        words(in: text).compactMap { modalCanonical[$0] }
    }

    private static func lexicallyLocal(original: String, corrected: String) -> Bool {
        let before = canonicalizedContractions(words(in: original))
        let after = canonicalizedContractions(words(in: corrected))
        let operations = alignedOperations(before, after)
        return operations.allSatisfy { operation in
            switch operation {
            case .equal:
                return true
            case let .replace(left, right):
                return sameGrammarGroup(left, right)
                    || (!changesLexicalNumber(left, right)
                        && tokenSimilarity(left, right) >= 0.65)
            case let .insert(token), let .delete(token):
                return safeInsertions.contains(token)
            }
        }
    }

    private static func canonicalizedContractions(_ tokens: [String]) -> [String] {
        tokens.flatMap { contractionCanonical[[$0]] ?? [$0] }
    }

    private static func words(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[A-Za-z]+(?:'[A-Za-z]+)?"#
        ) else {
            return []
        }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return expression.matches(in: text, range: range).map {
            source.substring(with: $0.range).lowercased()
        }
    }

    private enum AlignmentOperation {
        case equal
        case replace(String, String)
        case insert(String)
        case delete(String)
    }

    private static func alignedOperations(
        _ before: [String],
        _ after: [String]
    ) -> [AlignmentOperation] {
        var costs = Array(
            repeating: Array(repeating: 0, count: after.count + 1),
            count: before.count + 1
        )
        for index in 0...before.count { costs[index][0] = index }
        for index in 0...after.count { costs[0][index] = index }
        if !before.isEmpty, !after.isEmpty {
            for left in 1...before.count {
                for right in 1...after.count {
                    let substitution = costs[left - 1][right - 1]
                        + (before[left - 1] == after[right - 1] ? 0 : 1)
                    costs[left][right] = min(
                        substitution,
                        costs[left - 1][right] + 1,
                        costs[left][right - 1] + 1
                    )
                }
            }
        }

        var operations: [AlignmentOperation] = []
        var left = before.count
        var right = after.count
        while left > 0 || right > 0 {
            if left > 0, right > 0,
               before[left - 1] == after[right - 1],
               costs[left][right] == costs[left - 1][right - 1] {
                operations.append(.equal)
                left -= 1
                right -= 1
            } else if left > 0, right > 0,
                      costs[left][right] == costs[left - 1][right - 1] + 1 {
                operations.append(.replace(before[left - 1], after[right - 1]))
                left -= 1
                right -= 1
            } else if right > 0,
                      costs[left][right] == costs[left][right - 1] + 1 {
                operations.append(.insert(after[right - 1]))
                right -= 1
            } else {
                operations.append(.delete(before[left - 1]))
                left -= 1
            }
        }
        return operations.reversed()
    }

    private static func sameGrammarGroup(_ left: String, _ right: String) -> Bool {
        grammarGroups.contains { $0.contains(left) && $0.contains(right) }
    }

    private static func changesLexicalNumber(_ left: String, _ right: String) -> Bool {
        let demonstrativePairs = [
            Set(["this", "these"]),
            Set(["that", "those"]),
        ]
        if demonstrativePairs.contains(where: { $0.contains(left) && $0.contains(right) }) {
            return true
        }

        return isRegularPlural(right, of: left)
            || isRegularPlural(left, of: right)
    }

    private static func isRegularPlural(_ candidate: String, of singular: String) -> Bool {
        if candidate == singular + "s" || candidate == singular + "es" {
            return true
        }
        guard singular.hasSuffix("y"), singular.count > 1 else { return false }
        return candidate == singular.dropLast() + "ies"
    }

    private static func tokenSimilarity(_ left: String, _ right: String) -> Double {
        let maximum = max(left.count, right.count)
        guard maximum > 0 else { return 1 }
        return 1 - Double(levenshtein(left, right)) / Double(maximum)
    }

    private static func levenshtein(_ left: String, _ right: String) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var previous = Array(0...rightCharacters.count)
        for (leftIndex, leftCharacter) in leftCharacters.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[rightCharacters.count]
    }
}
