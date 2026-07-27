//
//  FinanceSyncAPI.swift
//  Finance Wizard
//
//  HTTP helpers for finance-sync: classify (push edits) + category list.
//

import Foundation

// Body for POST /api/transactions/{id}/classify
struct ClassifyRequestBody: Encodable {
    let category: String
    let multiplier: Double
    // Save a vendor rule so future Plaid rows get the same classification
    let learn: Bool
    // If true, learned rule only applies to the same payment method
    let scopePaymentMethod: Bool
    // If true, also update other existing matching rows on the server
    let applyToMatching: Bool
}

// Minimal success/error decoding from classify responses
struct ClassifyResponse: Decodable {
    let ok: Bool?
    let error: String?
    // Some servers return how many rows were updated when applyToMatching is true
    let updated: Int?
    let marked: Int?
}

// Flexible categories list from GET /api/categories
struct CategoriesResponse: Decodable {
    let categories: [String]?
    let ok: Bool?

    // Also accept a bare JSON array by custom decode below
    static func decode(from data: Data) throws -> [String] {
        // Prefer { "categories": ["Dining", ...] }
        if let wrapped = try? JSONDecoder().decode(CategoriesResponse.self, from: data),
           let list = wrapped.categories, !list.isEmpty {
            return list
        }
        // Or a raw string array
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        // Or { "items": [...] } style — ignore if unknown
        return []
    }
}

// Thin client around AppSettings.serverBaseURL
enum FinanceSyncAPI {
    // POST classify — push category + multiplier to the PC (locks row on server)
    static func classify(
        transactionId: String,
        category: String,
        multiplier: Double,
        learn: Bool = true,
        scopePaymentMethod: Bool = false,
        applyToMatching: Bool = false
    ) async throws {
        // URL-encode the id (Plaid ids are usually safe but encode anyway)
        let encodedId = transactionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? transactionId
        guard let url = URL(string: "\(AppSettings.serverBaseURL)/api/transactions/\(encodedId)/classify") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ClassifyRequestBody(
                category: category,
                multiplier: multiplier,
                learn: learn,
                scopePaymentMethod: scopePaymentMethod,
                applyToMatching: applyToMatching
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if !(200...299).contains(status) {
            // Prefer server error message when present
            if let body = try? JSONDecoder().decode(ClassifyResponse.self, from: data),
               let error = body.error, !error.isEmpty {
                throw APIError.server(status: status, message: error)
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                throw APIError.server(status: status, message: text)
            }
            throw APIError.server(status: status, message: "Classify failed")
        }

        // Optional: check ok: false with 200
        if let body = try? JSONDecoder().decode(ClassifyResponse.self, from: data),
           body.ok == false {
            throw APIError.server(status: status, message: body.error ?? "Classify rejected")
        }
    }

    // GET /api/categories — optional list for the picker
    static func fetchCategories() async -> [String] {
        guard let url = URL(string: "\(AppSettings.serverBaseURL)/api/categories") else {
            return []
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return [] }
            return try CategoriesResponse.decode(from: data)
        } catch {
            return []
        }
    }

    enum APIError: LocalizedError {
        case badURL
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Bad server URL. Check Settings."
            case .server(let status, let message):
                return "Server (\(status)): \(message)"
            }
        }
    }
}
