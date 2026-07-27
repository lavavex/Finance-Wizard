//
//  PlaidAPIClient.swift
//  Finance Wizard
//
//  Thin REST client for the user’s Plaid developer account.
//  Calls use client_id + secret from PlaidCredentialsStore.
//

import Foundation

enum PlaidAPIError: LocalizedError {
    case notConfigured
    case badURL
    case http(status: Int, code: String?, message: String)
    case decoding(String)
    case noPublicToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Plaid client_id and secret in Settings."
        case .badURL:
            return "Invalid Plaid API URL."
        case .http(_, let code, let message):
            if let code, !code.isEmpty {
                return "Plaid (\(code)): \(message)"
            }
            return "Plaid: \(message)"
        case .decoding(let detail):
            return "Could not read Plaid response: \(detail)"
        case .noPublicToken:
            return "Link did not return a public token."
        }
    }
}

/// Stateless helpers that talk to Plaid over HTTPS.
enum PlaidAPIClient {
    // MARK: - Public API

    /// Create a short-lived link_token for Plaid Link (mobile webview + OAuth).
    static func createLinkToken(
        clientName: String = "Finance Wizard",
        userID: String = "finance-wizard-user"
    ) async throws -> String {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let client_name: String
            let language: String
            let country_codes: [String]
            let user: User
            let products: [String]
            let transactions: TransactionsOpts?
            /// Required for OAuth banks (“Continue to Login”) in mobile webviews
            let redirect_uri: String

            struct User: Encodable {
                let client_user_id: String
            }

            struct TransactionsOpts: Encodable {
                let days_requested: Int
            }
        }

        let body = Body(
            client_id: PlaidCredentialsStore.clientID,
            secret: PlaidCredentialsStore.secret,
            client_name: clientName,
            language: "en",
            country_codes: ["US"],
            user: .init(client_user_id: userID),
            products: ["transactions"],
            // Up to ~2 years when product is initialized at Link
            transactions: .init(days_requested: 730),
            redirect_uri: PlaidCredentialsStore.redirectURI
        )

        struct Response: Decodable {
            let link_token: String
            let expiration: String?
        }

        let response: Response = try await post(path: "/link/token/create", body: body)
        return response.link_token
    }

    /// Exchange Link’s public_token for a long-lived access_token + item_id.
    static func exchangePublicToken(_ publicToken: String) async throws -> (accessToken: String, itemID: String) {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let public_token: String
        }

        struct Response: Decodable {
            let access_token: String
            let item_id: String
        }

        let response: Response = try await post(
            path: "/item/public_token/exchange",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                public_token: publicToken
            )
        )
        return (response.access_token, response.item_id)
    }

    /// One page of /transactions/sync.
    static func transactionsSync(
        accessToken: String,
        cursor: String?,
        count: Int = 500
    ) async throws -> TransactionsSyncPage {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
            let cursor: String?
            let count: Int
            let options: Options?

            struct Options: Encodable {
                let include_original_description: Bool
                let days_requested: Int?
            }
        }

        // Omit empty cursor so Plaid returns full history from the start.
        let cursorValue: String? = {
            guard let cursor, !cursor.isEmpty else { return nil }
            return cursor
        }()

        return try await post(
            path: "/transactions/sync",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken,
                cursor: cursorValue,
                count: count,
                options: .init(include_original_description: true, days_requested: nil)
            )
        )
    }

    /// Optional: remove Item on Plaid side (invalidates access token).
    static func removeItem(accessToken: String) async throws {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
        }

        struct Response: Decodable {
            let request_id: String?
        }

        let _: Response = try await post(
            path: "/item/remove",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken
            )
        )
    }

    // MARK: - Networking

    private static func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let base = PlaidCredentialsStore.environment.baseURL
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw PlaidAPIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if !(200...299).contains(status) {
            // Plaid error envelope
            if let err = try? JSONDecoder().decode(PlaidErrorBody.self, from: data) {
                throw PlaidAPIError.http(
                    status: status,
                    code: err.error_code,
                    message: err.error_message ?? err.display_message ?? "HTTP \(status)"
                )
            }
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw PlaidAPIError.http(status: status, code: nil, message: text)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PlaidAPIError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Response models (subset used by the app)

struct PlaidErrorBody: Decodable {
    let error_type: String?
    let error_code: String?
    let error_message: String?
    let display_message: String?
    let request_id: String?
}

struct TransactionsSyncPage: Decodable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    let next_cursor: String
    let has_more: Bool
    let transactions_update_status: String?
    let accounts: [PlaidAccount]?
}

struct PlaidRemovedTransaction: Decodable {
    let transaction_id: String
    let account_id: String?
}

struct PlaidAccount: Decodable {
    let account_id: String
    let name: String?
    let official_name: String?
    let mask: String?
    let type: String?
    let subtype: String?
}

struct PlaidTransaction: Decodable {
    let account_id: String
    let amount: Double
    let date: String
    let name: String?
    let merchant_name: String?
    let pending: Bool?
    let transaction_id: String
    let personal_finance_category: PlaidPFC?
    let payment_channel: String?
    let iso_currency_code: String?
    let original_description: String?
}

struct PlaidPFC: Decodable {
    let primary: String?
    let detailed: String?
    let confidence_level: String?
}
