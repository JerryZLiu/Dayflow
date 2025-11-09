//
//  MemoryStore.swift
//  FocusLock
//
//  Hybrid memory store with BM25 + vector indexing for local knowledge and RAG
//

import Foundation
import CoreML
import NaturalLanguage
import GRDB
import os.log

// MARK: - MemoryStore Protocol

protocol MemoryStore {
    func index(_ item: MemoryItem) async throws
    func search(_ query: String, limit: Int) async throws -> [MemorySearchResult]
    func semanticSearch(_ query: String, limit: Int) async throws -> [MemorySearchResult]
    func hybridSearch(_ query: String, limit: Int) async throws -> [MemorySearchResult]
    func delete(id: UUID) async throws
    func clear() async throws
    func getStatistics() async throws -> MemoryStoreStatistics
}

// MARK: - Memory Models

struct MemoryItem: Codable, Identifiable {
    let id: UUID
    let content: String
    let timestamp: Date
    let source: MemorySource
    let embeddings: [Float]?
    let metadata: [String: AnyCodable]

    init(content: String, source: MemorySource, embeddings: [Float]? = nil, metadata: [String: Any] = [:]) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.source = source
        self.embeddings = embeddings
        self.metadata = metadata.mapValues { AnyCodable($0) }
    }
}

enum MemorySource: String, Codable, CaseIterable {
    case screenCapture = "screen_capture"
    case ocr = "ocr"
    case accessibility = "accessibility"
    case fileContent = "file_content"
    case userNote = "user_note"
    case aiSummary = "ai_summary"
    case journal = "journal"
    case todo = "todo"

    var displayName: String {
        switch self {
        case .screenCapture: return "Screen Capture"
        case .ocr: return "OCR"
        case .accessibility: return "Accessibility"
        case .fileContent: return "File Content"
        case .userNote: return "User Note"
        case .aiSummary: return "AI Summary"
        case .journal: return "Journal"
        case .todo: return "Todo"
        }
    }
}

struct MemorySearchResult: Identifiable {
    let id: UUID
    let item: MemoryItem
    let score: Double
    let matchType: MatchType
    let highlightedContent: String?

    enum MatchType {
        case keyword(score: Double)
        case semantic(score: Double)
        case hybrid(keywordScore: Double, semanticScore: Double)
    }
}

struct MemoryStoreStatistics {
    let totalItems: Int
    let indexedItems: Int
    let averageEmbeddingGenerationTime: TimeInterval
    let averageSearchTime: TimeInterval
    let storageSizeBytes: Int64
    let lastIndexTime: Date
}

// NOTE: AnyCodable is defined in FocusLockModels.swift to avoid duplicate definitions

// MARK: - BM25 Index

actor BM25Index {
    private var documents: [UUID: [String]] = [:]
    private var documentLengths: [UUID: Int] = [:]
    private var termDocumentFrequencies: [String: Int] = [:]
    private var totalDocuments: Int = 0

    // BM25 parameters
    private let k1: Double = 1.2
    private let b: Double = 0.75

    init() {}

    func addDocument(id: UUID, terms: [String]) {
        // Remove existing document if present
        if documents[id] != nil {
            removeDocument(id: id)
        }

        documents[id] = terms
        documentLengths[id] = terms.count

        // Update term frequencies
        let uniqueTerms = Set(terms)
        for term in uniqueTerms {
            termDocumentFrequencies[term, default: 0] += 1
        }

        totalDocuments += 1
    }

    func removeDocument(id: UUID) {
        guard let terms = documents[id] else { return }

        // Update term frequencies
        let uniqueTerms = Set(terms)
        for term in uniqueTerms {
            if termDocumentFrequencies[term, default: 0] > 1 {
                termDocumentFrequencies[term]? -= 1
            } else {
                termDocumentFrequencies.removeValue(forKey: term)
            }
        }

        documents.removeValue(forKey: id)
        documentLengths.removeValue(forKey: id)
        totalDocuments -= 1
    }

    func search(query: String, limit: Int = 10) -> [(UUID, Double)] {
        let queryTerms = tokenize(query.lowercased())
        guard !queryTerms.isEmpty else { return [] }

        var scores: [UUID: Double] = [:]

        // Calculate average document length
        let avgDocLength = Double(documentLengths.values.reduce(0, +)) / Double(max(documentLengths.count, 1))

        for (docId, documentTerms) in documents {
            var score: Double = 0

            for term in queryTerms {
                let termFrequency = documentTerms.filter { $0 == term }.count
                guard termFrequency > 0 else { continue }

                let docLength = Double(documentLengths[docId] ?? 0)
                let idf = calculateIDF(term: term)

                // BM25 formula
                let tf = Double(termFrequency)
                let k1Plus1 = Double(k1 + 1)
                let k1Double = Double(k1)
                let bDouble = Double(b)

                let numerator = tf * k1Plus1
                let lengthRatio = docLength / avgDocLength
                let bComponent = 1 - bDouble + (bDouble * lengthRatio)
                let denominator = tf + (k1Double * bComponent)
                let tfComponent = numerator / denominator
                score += idf * tfComponent
            }

            if score > 0 {
                scores[docId] = score
            }
        }

        return scores.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    private func calculateIDF(term: String) -> Double {
        let df = Double(termDocumentFrequencies[term] ?? 0)
        guard df > 0 && totalDocuments > 0 else { return 0 }
        return log((Double(totalDocuments) - df + 0.5) / (df + 0.5))
    }

    private func tokenize(_ text: String) -> [String] {
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }
}

// MARK: - Vector Embeddings

actor VectorEmbeddingGenerator {
    private var embeddingModel: NLEmbedding?
    private var isLoading: Bool = false
    private var loadingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "FocusLock", category: "VectorEmbeddingGenerator")

    init() {
        // Defer loading to avoid blocking initialization
        // Call loadEmbeddingModel() explicitly via completeInitialization()
    }

    func loadEmbeddingModel() async {
        // Prevent concurrent loading attempts
        guard !isLoading else {
            // Wait for existing load to complete
            await loadingTask?.value
            return
        }
        
        isLoading = true
        loadingTask = Task {
            // Use Apple's multilingual sentence embedding model
            let model = NLEmbedding.sentenceEmbedding(for: .english)
            if let model = model {
                await setEmbeddingModel(model)
                logger.info("Successfully loaded sentence embedding model")
            } else {
                logger.error("Failed to load embedding model: model is nil")
            }
            isLoading = false
        }
        
        await loadingTask?.value
    }

    private func setEmbeddingModel(_ model: NLEmbedding) async {
        self.embeddingModel = model
    }
    
    func isModelReady() async -> Bool {
        return embeddingModel != nil
    }

    func generateEmbedding(for text: String) async throws -> [Float] {
        // Ensure model is loaded before generating embeddings
        if embeddingModel == nil {
            await loadEmbeddingModel()
        }
        
        guard let model = embeddingModel else {
            throw EmbeddingError.modelNotLoaded
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        guard let embeddingDouble = model.vector(for: text) else {
            throw EmbeddingError.processingFailed
        }
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        logger.info("Generated embedding in \(String(format: "%.3f", duration))s")

        // Convert [Double] to [Float]
        var embeddingFloat: [Float] = []
        for value in embeddingDouble {
            embeddingFloat.append(Float(value))
        }
        return embeddingFloat
    }

    func generateBatchEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var embeddings: [[Float]] = []

        for text in texts {
            let embedding = try await generateEmbedding(for: text)
            embeddings.append(embedding)
        }

        return embeddings
    }

    enum EmbeddingError: Error {
        case modelNotLoaded
        case processingFailed
    }
}

// MARK: - Similarity Calculator

struct SimilarityCalculator {
    static func cosineSimilarity(between vectorA: [Float], and vectorB: [Float]) -> Double {
        guard vectorA.count == vectorB.count else { return 0 }

        let dotProduct = zip(vectorA, vectorB).map(*).reduce(0, +)
        let magnitudeA = sqrt(vectorA.map { $0 * $0 }.reduce(0, +))
        let magnitudeB = sqrt(vectorB.map { $0 * $0 }.reduce(0, +))

        guard magnitudeA > 0 && magnitudeB > 0 else { return 0 }

        return Double(dotProduct) / (Double(magnitudeA) * Double(magnitudeB))
    }

    static func euclideanDistance(between vectorA: [Float], and vectorB: [Float]) -> Double {
        guard vectorA.count == vectorB.count else { return Double.greatestFiniteMagnitude }

        let squaredDifferences = zip(vectorA, vectorB).map { pow(Double($0 - $1), 2) }
        return sqrt(squaredDifferences.reduce(0, +))
    }
}

// MARK: - Main MemoryStore Implementation

actor HybridMemoryStore: MemoryStore {
    static let shared = HybridMemoryStore()

    private var databaseQueue: DatabaseQueue?
    private var bm25Index = BM25Index()
    private let embeddingGenerator = VectorEmbeddingGenerator()
    private let logger = Logger(subsystem: "FocusLock", category: "HybridMemoryStore")

    // Performance tracking
    private var embeddingGenerationTimes: [TimeInterval] = []
    private var searchTimes: [TimeInterval] = []

    // Async initialization tracking
    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?

    init() {
        // ✅ NO synchronous database operations in init
        // Database setup deferred to ensureInitialized()
    }

    /// Ensures the database is initialized before use (call before any database operation)
    func ensureInitialized() async {
        // Check if already initialized
        guard !isInitialized else { return }

        // Check if initialization is in progress
        if let task = initializationTask {
            await task.value
            return
        }

        // Start initialization
        let task = Task {
            await performInitialization()
        }
        initializationTask = task
        await task.value
    }

    private func performInitialization() async {
        guard !isInitialized else { return }

        do {
            // Initialize database path
            let dbPath = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FocusLock")
                .appendingPathComponent("MemoryStore.sqlite")

            try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

            // Create database queue with proper configuration
            var config = Configuration()
            config.prepareDatabase { db in
                db.busyMode = .timeout(5.0)
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }

            let queue = try DatabaseQueue(path: dbPath.path, configuration: config)
            self.databaseQueue = queue

            // Setup database schema asynchronously
            try await setupDatabaseAsync(queue: queue)

            // Load embedding model and existing items
            await completeInitialization()

            isInitialized = true
            logger.info("✅ HybridMemoryStore initialized successfully")

        } catch {
            logger.error("❌ Failed to initialize HybridMemoryStore: \(error.localizedDescription)")
            // Set initialized to true to prevent infinite retry loops
            // Database operations will fail gracefully
            isInitialized = true
        }
    }

    // Public method to complete async initialization
    public func completeInitialization() async {
        // Load embedding model first (non-blocking, async)
        await embeddingGenerator.loadEmbeddingModel()
        
        // Then load existing items and rebuild index (can be done lazily)
        await loadExistingItems()
        
        logger.info("MemoryStore initialization complete")
    }

    private func setupDatabaseAsync(queue: DatabaseQueue) async throws {
        // Perform database setup asynchronously to avoid blocking
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_items (
                    id TEXT PRIMARY KEY,
                    content TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    embeddings BLOB,
                    metadata TEXT,
                    created_at INTEGER DEFAULT (strftime('%s', 'now')),
                    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
                )
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_items_timestamp
                ON memory_items(timestamp)
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_items_source
                ON memory_items(source)
            """)
        }
    }

    private var isIndexLoaded: Bool = false
    
    private func loadExistingItems() async {
        // Lazy load - only load index on first search or explicit request
        guard !isIndexLoaded else { return }
        
        do {
            let items = try await getAllStoredItems()
            logger.info("Loading \(items.count) existing items into BM25 index (lazy load)")

            // Rebuild BM25 index incrementally (non-blocking)
            // Process items in batches to avoid overwhelming the system
            let batchSize = 50
            for batchStart in stride(from: 0, to: items.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, items.count)
                let batch = Array(items[batchStart..<batchEnd])
                
                await withTaskGroup(of: Void.self) { group in
                    for item in batch {
                        group.addTask { [weak self] in
                            guard let self = self else { return }
                            let terms = await self.tokenizeForBM25(item.content)
                            await self.bm25Index.addDocument(id: item.id, terms: terms)
                        }
                    }
                }
            }
            
            isIndexLoaded = true
            logger.info("BM25 index loaded with \(items.count) items")

        } catch {
            logger.error("Failed to load existing items: \(error.localizedDescription)")
        }
    }
    
    // Public method to explicitly trigger index loading
    public func ensureIndexLoaded() async {
        await loadExistingItems()
    }

    // MARK: - MemoryStore Protocol Implementation

    func index(_ item: MemoryItem) async throws {
        await ensureInitialized()

        let startTime = CFAbsoluteTimeGetCurrent()

        // Generate embeddings if not provided
        let finalItem: MemoryItem
        if item.embeddings == nil {
            let embeddings = try await embeddingGenerator.generateEmbedding(for: item.content)
            _ = item
            finalItem = MemoryItem(
                content: item.content,
                source: item.source,
                embeddings: embeddings.map { Float($0) },
                metadata: item.metadata
            )
        } else {
            finalItem = item
        }

        // Store in database
        try await storeItem(finalItem)

        // Update BM25 index
        let terms = tokenizeForBM25(finalItem.content)
        await bm25Index.addDocument(id: finalItem.id, terms: terms)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Indexed item in \(String(format: "%.3f", duration))s")
    }

    func search(_ query: String, limit: Int = 10) async throws -> [MemorySearchResult] {
        await ensureInitialized()

        let startTime = CFAbsoluteTimeGetCurrent()

        // Lazy load index on first search
        await ensureIndexLoaded()

        let results = await bm25Index.search(query: query, limit: limit)

        var searchResults: [MemorySearchResult] = []
        for (id, score) in results {
            guard let item = try await self.getItem(id: id) else { continue }
            let highlightedContent = self.highlightText(item.content, query: query)

            searchResults.append(MemorySearchResult(
                id: id,
                item: item,
                score: score,
                matchType: .keyword(score: score),
                highlightedContent: highlightedContent
            ))
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        searchTimes.append(duration)
        if searchTimes.count > 100 { searchTimes.removeFirst() }

        logger.info("Keyword search completed in \(String(format: "%.3f", duration))s")

        return searchResults
    }

    func semanticSearch(_ query: String, limit: Int = 10) async throws -> [MemorySearchResult] {
        await ensureInitialized()

        let startTime = CFAbsoluteTimeGetCurrent()

        // Generate embedding for query
        let queryEmbedding = try await embeddingGenerator.generateEmbedding(for: query)

        // Get all items with embeddings
        let itemsWithEmbeddings = try await getItemsWithEmbeddings()

        // Calculate similarities
        var similarities: [(UUID, Double)] = []
        for item in itemsWithEmbeddings {
            guard let itemEmbeddings = item.embeddings else { continue }

            let similarity = SimilarityCalculator.cosineSimilarity(
                between: queryEmbedding,
                and: itemEmbeddings
            )

            if similarity > 0.3 { // Threshold for semantic similarity
                similarities.append((item.id, similarity))
            }
        }

        // Sort by similarity and take top results
        similarities.sort { $0.1 > $1.1 }
        let topResults = Array(similarities.prefix(limit))

        var searchResults: [MemorySearchResult] = []
        for (id, score) in topResults {
            if let item = try await getItem(id: id) {
                searchResults.append(MemorySearchResult(
                    id: id,
                    item: item,
                    score: score,
                    matchType: .semantic(score: score),
                    highlightedContent: nil
                ))
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        searchTimes.append(duration)
        if searchTimes.count > 100 { searchTimes.removeFirst() }

        logger.info("Semantic search completed in \(String(format: "%.3f", duration))s")

        return searchResults
    }

    func hybridSearch(_ query: String, limit: Int = 10) async throws -> [MemorySearchResult] {
        await ensureInitialized()

        let startTime = CFAbsoluteTimeGetCurrent()

        // Get both keyword and semantic results
        async let keywordResults = search(query, limit: limit * 2)
        async let semanticResults = semanticSearch(query, limit: limit * 2)

        let (keyword, semantic) = try await (keywordResults, semanticResults)

        // Combine and deduplicate results
        var combinedResults: [UUID: MemorySearchResult] = [:]

        // Add keyword results
        for result in keyword {
            combinedResults[result.id] = result
        }

        // Add semantic results or update with hybrid score
        for result in semantic {
            if let existing = combinedResults[result.id] {
                // Combine scores using weighted average
                switch (existing.matchType, result.matchType) {
                case (.keyword(let keywordScore), .semantic(let semanticScore)):
                    let combinedScore = 0.6 * keywordScore + 0.4 * semanticScore
                    combinedResults[result.id] = MemorySearchResult(
                        id: result.id,
                        item: result.item,
                        score: combinedScore,
                        matchType: .hybrid(keywordScore: keywordScore, semanticScore: semanticScore),
                        highlightedContent: existing.highlightedContent
                    )
                default:
                    break
                }
            } else {
                combinedResults[result.id] = result
            }
        }

        // Sort by combined score and limit results
        let finalResults = combinedResults.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        searchTimes.append(duration)
        if searchTimes.count > 100 { searchTimes.removeFirst() }

        logger.info("Hybrid search completed in \(String(format: "%.3f", duration))s")

        return Array(finalResults)
    }

    func delete(id: UUID) async throws {
        await ensureInitialized()

        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        try await queue.write { db in
            try db.execute(sql: "DELETE FROM memory_items WHERE id = ?", arguments: [id.uuidString])
        }

        await bm25Index.removeDocument(id: id)
        logger.info("Deleted item \(id.uuidString)")
    }

    func clear() async throws {
        await ensureInitialized()

        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        try await queue.write { db in
            try db.execute(sql: "DELETE FROM memory_items")
        }

        // Create new BM25 index and clear the existing one
        let newIndex = BM25Index()
        _ = bm25Index
        bm25Index = newIndex
        // Note: The old index will be deallocated automatically
        logger.info("Cleared all items from memory store")
    }

    func getStatistics() async throws -> MemoryStoreStatistics {
        await ensureInitialized()

        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        let items = try await getAllStoredItems()
        let indexedItems = items.filter { $0.embeddings != nil }

        let avgEmbeddingTime = embeddingGenerationTimes.isEmpty ? 0 :
            embeddingGenerationTimes.reduce(0, +) / Double(embeddingGenerationTimes.count)

        let avgSearchTime = searchTimes.isEmpty ? 0 :
            searchTimes.reduce(0, +) / Double(searchTimes.count)

        // Calculate storage size
        let storageSize = try await queue.read { db -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT SUM(LENGTH(embeddings) + LENGTH(content) + LENGTH(metadata)) FROM memory_items") ?? 0
        }

        let lastIndexTime = items.max { $0.timestamp < $1.timestamp }?.timestamp ?? Date()

        return MemoryStoreStatistics(
            totalItems: items.count,
            indexedItems: indexedItems.count,
            averageEmbeddingGenerationTime: avgEmbeddingTime,
            averageSearchTime: avgSearchTime,
            storageSizeBytes: storageSize,
            lastIndexTime: lastIndexTime
        )
    }

    // MARK: - Private Helper Methods

    private func storeItem(_ item: MemoryItem) async throws {
        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        let metadataData = try JSONEncoder().encode(item.metadata)

        let embeddingsData: Data?
        if let embeddings = item.embeddings {
            embeddingsData = Data(bytes: embeddings, count: embeddings.count * MemoryLayout<Float>.size)
        } else {
            embeddingsData = nil
        }

        try await queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO memory_items
                (id, content, timestamp, source, embeddings, metadata)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                item.id.uuidString,
                item.content,
                Int(item.timestamp.timeIntervalSince1970),
                item.source.rawValue,
                embeddingsData,
                String(data: metadataData, encoding: .utf8)
            ])
        }
    }

    private func getItem(id: UUID) async throws -> MemoryItem? {
        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        return try await queue.read { db -> MemoryItem? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, content, timestamp, source, embeddings, metadata
                FROM memory_items WHERE id = ?
            """, arguments: [id.uuidString]) else { return nil }

            return try parseMemoryItem(from: row)
        }
    }

    private func getAllStoredItems() async throws -> [MemoryItem] {
        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        let rows = try queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT id, content, timestamp, source, embeddings, metadata
                FROM memory_items ORDER BY timestamp DESC
            """)
        }
        return try rows.compactMap { try parseMemoryItem(from: $0) }
    }

    private func getItemsWithEmbeddings() async throws -> [MemoryItem] {
        guard let queue = databaseQueue else {
            throw DatabaseError.storageError
        }

        let rows = try queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT id, content, timestamp, source, embeddings, metadata
                FROM memory_items
                WHERE embeddings IS NOT NULL
                ORDER BY timestamp DESC
            """)
        }
        return try rows.compactMap { try parseMemoryItem(from: $0) }
    }

    nonisolated private func parseMemoryItem(from row: Row) throws -> MemoryItem {
        let idString: String = row["id"]
        let content: String = row["content"]
        let _: Int = row["timestamp"]
        let sourceString: String = row["source"]
        let embeddingsData: Data? = row["embeddings"]
        let metadataString: String? = row["metadata"]

        guard let _ = UUID(uuidString: idString),
              let source = MemorySource(rawValue: sourceString) else {
                throw DatabaseError.invalidData
            }

        let embeddings: [Float]?
        if let data = embeddingsData {
            embeddings = data.withUnsafeBytes { bytes in
                Array(bytes.bindMemory(to: Float.self))
            }
        } else {
            embeddings = nil
        }

        var metadata: [String: AnyCodable] = [:]
        if let metadataString = metadataString,
           let data = metadataString.data(using: .utf8) {
            metadata = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        }

        return MemoryItem(
            content: content,
            source: source,
            embeddings: embeddings,
            metadata: metadata.mapValues { $0.value }
        )
    }

    private func tokenizeForBM25(_ text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
    }

    private func highlightText(_ text: String, query: String) -> String {
        let queryTerms = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var highlightedText = text

        for term in queryTerms {
            let range = highlightedText.lowercased().range(of: term)
            if let range = range {
                highlightedText = String(highlightedText.prefix(upTo: range.lowerBound)) +
                    "**" + String(highlightedText[range]) + "**" +
                    String(highlightedText.suffix(from: range.upperBound))
            }
        }

        return highlightedText
    }

    enum DatabaseError: Error {
        case invalidData
        case storageError
    }
}
