//
//  QueryResult+WindowSnapshot.swift
//  Easydict
//
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

extension QueryResult {
    /// Copies visible data without sharing requests, WebViews, callbacks or row geometry.
    @objc(windowSnapshotWithModel:)
    func windowSnapshot(model: QueryModel) -> QueryResult {
        let snapshot = QueryResult()
        snapshot.queryModel = model
        snapshot.serviceTypeWithUniqueIdentifier = serviceTypeWithUniqueIdentifier
        snapshot.isShowing = isShowing
        snapshot.isStreamFinished = isStreamFinished
        snapshot.queryText = queryText
        snapshot.from = from
        snapshot.to = to
        snapshot.translatedResults = translatedResults
        snapshot.wordResult = wordResult?.windowSnapshot()
        snapshot.error = error.map {
            QueryError(type: $0.type, message: $0.message, errorDataMessage: $0.errorDataMessage)
        }
        snapshot.manualShow = manualShow
        snapshot.fromSpeakURL = fromSpeakURL
        snapshot.toSpeakURL = toSpeakURL
        snapshot.promptTitle = promptTitle
        snapshot.promptURL = promptURL
        snapshot.showBigWord = showBigWord
        snapshot.translateResultsTopInset = translateResultsTopInset
        snapshot.htmlString = htmlString
        snapshot.htmlStrings = htmlStrings
        snapshot.innerTexts = innerTexts
        snapshot.copiedText = copiedText
        snapshot.validationMessage = validationMessage
        snapshot.markdownRenderingOverride = markdownRenderingOverride
        // Replacement belongs to the selection in the originating application.
        snapshot.showReplaceButton = false
        return snapshot
    }
}

private extension EZTranslateWordResult {
    func windowSnapshot() -> EZTranslateWordResult {
        let snapshot = EZTranslateWordResult()
        snapshot.phonetics = phonetics?.map {
            let item = EZWordPhonetic()
            item.word = $0.word
            item.language = $0.language
            item.value = $0.value
            item.speakURL = $0.speakURL
            item.name = $0.name
            item.accent = $0.accent
            return item
        }
        snapshot.parts = parts?.map { $0.windowSnapshot() }
        snapshot.exchanges = exchanges?.map {
            let item = EZTranslateExchange()
            item.name = $0.name
            item.words = $0.words
            return item
        }
        snapshot.simpleWords = simpleWords?.map {
            let item = EZTranslateSimpleWord()
            item.word = $0.word
            item.part = $0.part
            item.means = $0.means
            item.showPartMeans = $0.showPartMeans
            return item
        }
        snapshot.tags = tags
        snapshot.etymology = etymology
        snapshot.synonyms = synonyms?.map { $0.windowSnapshot() }
        snapshot.antonyms = antonyms?.map { $0.windowSnapshot() }
        snapshot.collocation = collocation?.map { $0.windowSnapshot() }
        return snapshot
    }
}

private extension EZTranslatePart {
    func windowSnapshot() -> EZTranslatePart {
        let snapshot = EZTranslatePart()
        snapshot.part = part
        snapshot.means = means
        return snapshot
    }
}
