//
//  VocabularyEntry.swift
//  Easydict
//
//  Created by izual on 2026/9/15.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - VocabularyEntry

/// A single query record persisted to the vocabulary notebook JSONL file.
///
/// Wraps the resolved query metadata (`text`, language pair, translation) around an
/// optional `DictionaryEntry`. Sentence and streaming queries carry no dictionary
/// entry, so `dictionaryEntry` is `nil` for them.
struct VocabularyEntry: Codable {
    /// The query text, either a single word or a full sentence.
    var text: String
    /// BCP-47 code of the effective source language.
    var sourceLanguage: String
    /// BCP-47 code of the effective target language.
    var targetLanguage: String
    /// The translated text, if any.
    var translatedText: String?
    /// Local time when the query completed.
    var timestamp: Date
    /// Detailed dictionary data; `nil` for sentence or streaming queries.
    var dictionaryEntry: DictionaryEntry?
    /// How the query was started: `"inline"` when the user clicked a word inside
    /// another result, `nil` for an ordinary query. A click is an explicit "I do not
    /// know this word" signal, which a plain query is not, so consumers need to tell
    /// them apart. Left `nil` (and thus omitted from the JSON) for ordinary queries so
    /// existing notebooks keep their exact shape.
    var trigger: String?
}
