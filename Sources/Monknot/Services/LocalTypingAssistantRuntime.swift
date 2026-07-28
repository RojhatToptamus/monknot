import Foundation
import MonknotCore

struct LocalTypingAssistantConfiguration: Equatable {
    let endpoint: URL
    let model: String
    let contextLength: Int
    let keepAlive: String
    let probeDeadline: TimeInterval
    let foregroundDeadline: TimeInterval
    let backgroundDeadline: TimeInterval

    static let researchDefault = LocalTypingAssistantConfiguration(
        endpoint: URL(string: "http://127.0.0.1:11434")!,
        model: "qwen3:4b-instruct-2507-q4_K_M",
        contextLength: 2_048,
        keepAlive: "5m",
        probeDeadline: 0.15,
        foregroundDeadline: 1.15,
        backgroundDeadline: 2.2
    )

    init(
        endpoint: URL,
        model: String,
        contextLength: Int,
        keepAlive: String,
        probeDeadline: TimeInterval,
        foregroundDeadline: TimeInterval,
        backgroundDeadline: TimeInterval
    ) {
        precondition(Self.isLoopback(endpoint), "Typing assistance must use a loopback HTTP endpoint")
        self.endpoint = endpoint
        self.model = model
        self.contextLength = contextLength
        self.keepAlive = keepAlive
        self.probeDeadline = probeDeadline
        self.foregroundDeadline = foregroundDeadline
        self.backgroundDeadline = backgroundDeadline
    }

    private static func isLoopback(_ endpoint: URL) -> Bool {
        guard endpoint.scheme == "http",
              let host = endpoint.host?.lowercased()
        else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

enum LocalTypingAssistantRoute: String, Equatable {
    case loadedForeground
    case modelBusy
    case foregroundNoSuggestion
    case foregroundTimeout
    case unloadedBackgroundWarmup
    case probeFailure
    case invalidResponse
    case safetySuppressed
    case protectedContextSuppressed
}

struct LocalTypingAssistantRuntimeResult: Equatable {
    let route: LocalTypingAssistantRoute
    let suggestion: TypingAssistanceSuggestion?
    let latencyMilliseconds: Double
    let suppressionReason: String?

    static func noSuggestion(
        route: LocalTypingAssistantRoute,
        latencyMilliseconds: Double,
        suppressionReason: String? = nil
    ) -> LocalTypingAssistantRuntimeResult {
        LocalTypingAssistantRuntimeResult(
            route: route,
            suggestion: nil,
            latencyMilliseconds: latencyMilliseconds,
            suppressionReason: suppressionReason
        )
    }
}

struct LocalTypingAssistantRuntimeDiagnostics: Equatable {
    let model: String
    let observedPeakModelConcurrency: Int
    let totalModelCalls: Int
    let foregroundTimeouts: Int
    let backgroundWarmups: Int
    let fallbackTextMutationCount: Int
    let fabricatedFallbackCorrectionCount: Int
}

protocol LocalTypingAssistantTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTypingAssistantTransport: LocalTypingAssistantTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LocalTypingAssistantRuntimeError.timeout
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalTypingAssistantRuntimeError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

enum LocalTypingAssistantRuntimeError: Error, Equatable {
    case modelBusy
    case invalidHTTPResponse
    case invalidResponse
    case requestFailed(Int)
    case timeout
}

private actor LocalTypingAssistantModelGate {
    private var active = false
    private var activeCount = 0
    private(set) var peakCount = 0
    private(set) var totalCalls = 0

    func acquire() throws {
        guard !active else {
            throw LocalTypingAssistantRuntimeError.modelBusy
        }
        active = true
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        totalCalls += 1
    }

    func release() {
        activeCount = max(0, activeCount - 1)
        active = false
    }

    func diagnostics() -> (peak: Int, total: Int) {
        (peakCount, totalCalls)
    }
}

private actor LocalTypingAssistantDeadlineState<Value> {
    private var outcome: Result<Value, Error>?
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?

    func wait() async -> Result<Value, Error> {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(
        _ outcome: Result<Value, Error>,
        cancelling operation: Task<Value, Error>? = nil
    ) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        operation?.cancel()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

actor LocalTypingAssistantRuntime {
    static let shared = LocalTypingAssistantRuntime()

    private let configuration: LocalTypingAssistantConfiguration
    private let transport: LocalTypingAssistantTransport
    private let modelGate = LocalTypingAssistantModelGate()
    private var warmupScheduled = false
    private var foregroundTimeouts = 0
    private var backgroundWarmups = 0

    init(
        configuration: LocalTypingAssistantConfiguration = .researchDefault,
        transport: LocalTypingAssistantTransport = URLSessionTypingAssistantTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func requestCorrection(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult {
        await request(
            snapshot: snapshot,
            context: context,
            kind: .grammar
        )
    }

    func requestCompletion(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult {
        let finalContext = String(context.text.suffix(160))
        if !TypingAssistanceSafetyPolicy.protectedSpans(in: finalContext).isEmpty {
            return .noSuggestion(
                route: .protectedContextSuppressed,
                latencyMilliseconds: 0,
                suppressionReason: "protected_context"
            )
        }
        return await request(
            snapshot: snapshot,
            context: context,
            kind: .completion
        )
    }

    func diagnostics() async -> LocalTypingAssistantRuntimeDiagnostics {
        let gate = await modelGate.diagnostics()
        return LocalTypingAssistantRuntimeDiagnostics(
            model: configuration.model,
            observedPeakModelConcurrency: gate.peak,
            totalModelCalls: gate.total,
            foregroundTimeouts: foregroundTimeouts,
            backgroundWarmups: backgroundWarmups,
            fallbackTextMutationCount: 0,
            fabricatedFallbackCorrectionCount: 0
        )
    }

    private func request(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext,
        kind: TypingAssistanceRequestKind
    ) async -> LocalTypingAssistantRuntimeResult {
        let started = Date()
        do {
            guard try await modelIsLoaded() else {
                scheduleBackgroundWarmup()
                return .noSuggestion(
                    route: .unloadedBackgroundWarmup,
                    latencyMilliseconds: elapsedMilliseconds(since: started)
                )
            }
        } catch is CancellationError {
            return .noSuggestion(
                route: .foregroundNoSuggestion,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "cancelled"
            )
        } catch {
            scheduleBackgroundWarmup()
            return .noSuggestion(
                route: .probeFailure,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "probe_failed"
            )
        }

        do {
            let operation = try await startModelOperation {
                try await self.generate(context: context.text, kind: kind)
            }
            let prediction = try await withDeadline(
                configuration.foregroundDeadline,
                operation: operation
            )
            try Task.checkCancellation()
            return makeResult(
                prediction: prediction,
                snapshot: snapshot,
                context: context,
                kind: kind,
                latencyMilliseconds: elapsedMilliseconds(since: started)
            )
        } catch LocalTypingAssistantRuntimeError.modelBusy {
            return .noSuggestion(
                route: .modelBusy,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "model_busy"
            )
        } catch is CancellationError {
            return .noSuggestion(
                route: .foregroundNoSuggestion,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "cancelled"
            )
        } catch LocalTypingAssistantRuntimeError.timeout {
            foregroundTimeouts += 1
            return .noSuggestion(
                route: .foregroundTimeout,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "foreground_timeout"
            )
        } catch {
            return .noSuggestion(
                route: .invalidResponse,
                latencyMilliseconds: elapsedMilliseconds(since: started),
                suppressionReason: "runtime_error"
            )
        }
    }

    private func modelIsLoaded() async throws -> Bool {
        let request = try makeRequest(
            path: "/api/ps",
            method: "GET",
            body: nil,
            timeout: configuration.probeDeadline
        )
        let operation = Task {
            let (data, response) = try await self.transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw LocalTypingAssistantRuntimeError.requestFailed(response.statusCode)
            }
            return data
        }
        let data = try await withDeadline(
            configuration.probeDeadline,
            operation: operation
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else {
            throw LocalTypingAssistantRuntimeError.invalidResponse
        }
        return models.contains { model in
            let name = model["name"] as? String ?? model["model"] as? String
            let contextLength = model["context_length"] as? Int
            return name == configuration.model
                && contextLength == configuration.contextLength
        }
    }

    private func scheduleBackgroundWarmup() {
        guard !warmupScheduled else { return }
        warmupScheduled = true
        Task {
            await self.performBackgroundWarmup()
        }
    }

    private func performBackgroundWarmup() async {
        defer { warmupScheduled = false }
        do {
            let operation = try await startModelOperation {
                let body: [String: Any] = [
                    "model": self.configuration.model,
                    "prompt": "",
                    "stream": false,
                    "keep_alive": self.configuration.keepAlive,
                    "options": ["num_ctx": self.configuration.contextLength],
                ]
                let request = try self.makeRequest(
                    path: "/api/generate",
                    method: "POST",
                    body: body,
                    timeout: self.configuration.backgroundDeadline
                )
                let (_, response) = try await self.transport.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    throw LocalTypingAssistantRuntimeError.requestFailed(
                        response.statusCode
                    )
                }
            }
            _ = try await withDeadline(
                configuration.backgroundDeadline,
                operation: operation
            )
            backgroundWarmups += 1
        } catch {
            return
        }
    }

    private func generate(
        context: String,
        kind: TypingAssistanceRequestKind
    ) async throws -> ModelPrediction {
        let messages: [[String: String]]
        let schema: [String: Any]
        if kind == .completion {
            schema = [
                "type": "object",
                "additionalProperties": false,
                "required": ["completion"],
                "properties": [
                    "completion": [
                        "anyOf": [
                            ["type": "string"],
                            ["type": "null"],
                        ]
                    ]
                ],
            ]
            messages = completionMessages(context: context, schema: schema)
        } else {
            schema = correctionSchema()
            messages = correctionMessages(context: context, schema: schema)
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "keep_alive": configuration.keepAlive,
            "format": schema,
            "options": [
                "temperature": 0,
                "num_ctx": configuration.contextLength,
                "num_predict": kind == .completion ? 24 : 160,
            ],
            "messages": messages,
        ]
        let request = try makeRequest(
            path: "/api/chat",
            method: "POST",
            body: body,
            timeout: configuration.foregroundDeadline
        )
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw LocalTypingAssistantRuntimeError.requestFailed(response.statusCode)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = envelope["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let prediction = try JSONSerialization.jsonObject(
                with: contentData
              ) as? [String: Any]
        else {
            throw LocalTypingAssistantRuntimeError.invalidResponse
        }
        if kind == .completion {
            if prediction["completion"] is NSNull {
                return ModelPrediction(action: "unchanged", text: nil)
            }
            return ModelPrediction(
                action: "completion",
                text: prediction["completion"] as? String
            )
        }
        return ModelPrediction(
            action: prediction["action"] as? String ?? "",
            text: prediction["text"] is NSNull ? nil : prediction["text"] as? String
        )
    }

    private func makeResult(
        prediction: ModelPrediction,
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext,
        kind: TypingAssistanceRequestKind,
        latencyMilliseconds: Double
    ) -> LocalTypingAssistantRuntimeResult {
        guard let text = prediction.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return .noSuggestion(
                route: .foregroundNoSuggestion,
                latencyMilliseconds: latencyMilliseconds
            )
        }

        if kind == .completion {
            guard prediction.action == "completion",
                  text.split(whereSeparator: \.isWhitespace).count <= 3
            else {
                return .noSuggestion(
                    route: .invalidResponse,
                    latencyMilliseconds: latencyMilliseconds,
                    suppressionReason: "invalid_completion"
                )
            }
            return LocalTypingAssistantRuntimeResult(
                route: .loadedForeground,
                suggestion: TypingAssistanceSuggestion(
                    requestKind: .completion,
                    sourceDocumentID: snapshot.documentID,
                    sourceRevision: snapshot.revision,
                    sourceText: snapshot.text,
                    sourceCursorUTF16Offset: snapshot.cursorUTF16Offset,
                    sourceSelectionUTF16Location: snapshot.selectionUTF16Location,
                    sourceSelectionLength: snapshot.selectionLength,
                    replacementRange: NSRange(
                        location: snapshot.cursorUTF16Offset,
                        length: 0
                    ),
                    replacementText: text,
                    model: configuration.model,
                    latencyMilliseconds: latencyMilliseconds
                ),
                latencyMilliseconds: latencyMilliseconds,
                suppressionReason: nil
            )
        }

        guard prediction.action == "correct",
              text != context.text
        else {
            return .noSuggestion(
                route: .foregroundNoSuggestion,
                latencyMilliseconds: latencyMilliseconds
            )
        }
        guard TypingAssistanceSafetyPolicy.allowsCorrection(
            original: context.text,
            corrected: text
        ) else {
            return .noSuggestion(
                route: .safetySuppressed,
                latencyMilliseconds: latencyMilliseconds,
                suppressionReason: "safety_policy"
            )
        }
        return LocalTypingAssistantRuntimeResult(
            route: .loadedForeground,
            suggestion: TypingAssistanceSuggestion(
                requestKind: .grammar,
                sourceDocumentID: snapshot.documentID,
                sourceRevision: snapshot.revision,
                sourceText: snapshot.text,
                sourceCursorUTF16Offset: snapshot.cursorUTF16Offset,
                sourceSelectionUTF16Location: snapshot.selectionUTF16Location,
                sourceSelectionLength: snapshot.selectionLength,
                replacementRange: context.range,
                replacementText: text,
                model: configuration.model,
                latencyMilliseconds: latencyMilliseconds
            ),
            latencyMilliseconds: latencyMilliseconds,
            suppressionReason: nil
        )
    }

    private func correctionSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["action", "text"],
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["correct", "unchanged", "reject"],
                ],
                "text": [
                    "anyOf": [
                        ["type": "string"],
                        ["type": "null"],
                    ]
                ],
            ],
        ]
    }

    private func correctionMessages(
        context: String,
        schema: [String: Any]
    ) -> [[String: String]] {
        let schemaText = jsonString(schema)
        let payload: [String: Any] = [
            "task": "correct",
            "valid_actions": ["correct", "unchanged", "reject"],
            "input": context,
            "immutable_exact_copy_spans": TypingAssistanceSafetyPolicy.protectedSpans(
                in: context
            ),
        ]
        let system = """
        You are a conservative offline autocorrect engine for a text editor. Return only JSON matching the schema. Make the smallest correction that fixes a clear spelling, grammar, punctuation, capitalization, contraction, or missing-word error. Preserve the user's wording, tone, meaning, singular or plural intent, negation, modal verbs, names, and technical text. Copy every immutable exact-copy span byte-for-byte. Do not polish or rephrase. If the input is already acceptable, choose unchanged and copy it exactly. If a safe correction requires guessing, choose reject with text null. /no_think
        JSON schema:
        \(schemaText)
        """
        return [
            ["role": "system", "content": system],
            [
                "role": "user",
                "content": "Correct the input for text-editor autocorrect.\nInput payload:\n"
                    + jsonString(payload),
            ],
        ]
    }

    private func completionMessages(
        context: String,
        schema: [String: Any]
    ) -> [[String: String]] {
        let system = """
        You are a risk-averse offline inline completion gate. Return only JSON matching the schema. Return completion null unless the immediate next word is strongly determined by the existing prose. Return null when several grammatical continuations are possible or a fact, name, action, or object would be guessed. Return null inside code, URLs, commands, paths, flags, variables, numbers, model names, product names, package names, or technical tokens. When justified, return only the immediate 1 to 3 words after the caret. Never repeat, correct, or rewrite existing context. /no_think
        JSON schema:
        \(jsonString(schema))
        """
        let payload: [String: Any] = ["context": context, "max_words": 3]
        return [
            ["role": "system", "content": system],
            [
                "role": "user",
                "content": "Complete the text after the caret.\nInput payload:\n"
                    + jsonString(payload),
            ],
        ]
    }

    private func makeRequest(
        path: String,
        method: String,
        body: [String: Any]?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.endpoint) else {
            throw LocalTypingAssistantRuntimeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }

    private func startModelOperation<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> Task<T, Error> {
        try Task.checkCancellation()
        try await modelGate.acquire()
        let gate = modelGate
        return Task {
            do {
                let value = try await operation()
                await gate.release()
                return value
            } catch {
                await gate.release()
                throw error
            }
        }
    }

    private func withDeadline<T>(
        _ seconds: TimeInterval,
        operation: Task<T, Error>
    ) async throws -> T {
        let state = LocalTypingAssistantDeadlineState<T>()
        Task {
            do {
                await state.resolve(.success(try await operation.value))
            } catch {
                await state.resolve(.failure(error))
            }
        }
        Task {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
                )
            } catch {
                return
            }
            await state.resolve(
                .failure(LocalTypingAssistantRuntimeError.timeout),
                cancelling: operation
            )
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let outcome = await state.wait()
            try Task.checkCancellation()
            return try outcome.get()
        } onCancel: {
            operation.cancel()
            Task {
                await state.resolve(
                    .failure(CancellationError()),
                    cancelling: operation
                )
            }
        }
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func elapsedMilliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1_000
    }

    private struct ModelPrediction {
        let action: String
        let text: String?
    }
}
