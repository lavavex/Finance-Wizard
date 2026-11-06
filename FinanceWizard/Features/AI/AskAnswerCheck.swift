//
//  AskAnswerCheck.swift
//  Finance Wizard
//
//  Catches dollar amounts the model made up. Every amount in an answer has to appear in what the
//  tools returned or what the user typed, since the app is the only source of money facts.
//

import Foundation

enum AskAnswerCheck {
    /// Dollar amounts in the answer that don't match any fact.
    static func unverifiedAmounts(in answer: String, facts: [String]) -> [Double] {
        let known = facts.flatMap(numbers)
        return dollarAmounts(in: answer).filter { amount in
            !known.contains { matches(amount, fact: $0) }
        }
    }

    /// The model may round to whole dollars, so "$1,771" can stand for 1770.76.
    private static func matches(_ amount: Double, fact: Double) -> Bool {
        let value = abs(fact)
        if abs(amount - value) < 0.011 { return true }
        return amount == amount.rounded() && abs(amount - value.rounded()) < 0.011
    }

    static func dollarAmounts(in text: String) -> [Double] {
        values(in: text, pattern: #"\$\s?(\d[\d,]*(?:\.\d+)?)"#)
    }

    static func numbers(in text: String) -> [Double] {
        values(in: text, pattern: #"(\d[\d,]*(?:\.\d+)?)"#)
    }

    private static func values(in text: String, pattern: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let group = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[group].replacingOccurrences(of: ",", with: ""))
        }
    }
}
