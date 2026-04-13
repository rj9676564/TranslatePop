import Foundation
import SwiftData
import OSLog

@MainActor
final class TranslationStore {
    private let logger = Logger(subsystem: "com.antigravity.TranslatePop", category: "TranslationStore")
    private let modelContext: ModelContext
    private let maxItems = 1000

    static let shared = TranslationStore()

    private init() {
        do {
            let container = try ModelContainer(for: TranslationHistoryItem.self)
            self.modelContext = ModelContext(container)
            self.modelContext.autosaveEnabled = true
            logger.info("SwiftData 存储已初始化")
        } catch {
            fatalError("无法初始化 SwiftData 容器: \(error)")
        }
    }

    func get(for text: String) -> TranslationResult? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let predicate = #Predicate<TranslationHistoryItem> { item in
            item.normalizedText == normalized
        }
        
        let descriptor = FetchDescriptor<TranslationHistoryItem>(predicate: predicate)
        
        do {
            if let item = try modelContext.fetch(descriptor).first {
                item.lookupCount += 1
                item.createdAt = Date()
                return TranslationResult(
                    originalText: item.originalText,
                    translatedText: item.translatedText,
                    detectedSourceLanguage: nil,
                    providerName: item.providerName
                )
            }
        } catch {
            logger.error("查询缓存失败: \(error.localizedDescription)")
        }
        return nil
    }

    func save(_ result: TranslationResult) {
        let normalized = result.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let predicate = #Predicate<TranslationHistoryItem> { item in
            item.normalizedText == normalized
        }
        let descriptor = FetchDescriptor<TranslationHistoryItem>(predicate: predicate)
        
        do {
            let existing = try modelContext.fetch(descriptor)
            if let first = existing.first {
                first.translatedText = result.translatedText
                first.providerName = result.providerName
                first.createdAt = Date()
                first.lookupCount += 1
            } else {
                let newItem = TranslationHistoryItem(result: result)
                modelContext.insert(newItem)
            }
            pruneIfNecessary()
            try modelContext.save()
        } catch {
            logger.error("保存翻译结果失败: \(error.localizedDescription)")
        }
    }

    func clearAll() {
        do {
            try modelContext.delete(model: TranslationHistoryItem.self)
            try modelContext.save()
            logger.info("已清空翻译所有缓存")
        } catch {
            logger.error("清空缓存失败: \(error.localizedDescription)")
        }
    }

    private func pruneIfNecessary() {
        do {
            let countDescriptor = FetchDescriptor<TranslationHistoryItem>()
            let totalCount = try modelContext.fetchCount(countDescriptor)
            
            if totalCount > maxItems {
                var deleteDescriptor = FetchDescriptor<TranslationHistoryItem>(
                    predicate: #Predicate { !$0.isFavorite },
                    sortBy: [SortDescriptor(\.createdAt, order: .forward)]
                )
                deleteDescriptor.fetchLimit = totalCount - maxItems
                
                let toDelete = try modelContext.fetch(deleteDescriptor)
                for item in toDelete {
                    modelContext.delete(item)
                }
                logger.info("已清理 \(toDelete.count) 条旧缓存")
            }
        } catch {
            logger.error("清理缓存失败: \(error.localizedDescription)")
        }
    }
}
