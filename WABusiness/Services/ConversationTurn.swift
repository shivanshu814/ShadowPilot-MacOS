import Foundation

struct ConversationTurn {
    let question: String
    let answer: String              // may be stored compressed (long answers truncated for context budget)
    var mode: AnswerMode = .interview   // resolved mode of this turn — used for follow-up inheritance
}
