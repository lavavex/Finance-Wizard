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

    /// Hosted Link session for native mobile (`ASWebAuthenticationSession`).
    struct HostedLinkSession: Sendable {
        let linkToken: String
        let hostedLinkURL: URL
    }

    /// Create link_token + Hosted Link URL (webview Link is deprecated).
    static func createHostedLinkSession(
        clientName: String = "Finance Wizard",
        userID: String = "finance-wizard-user"
    ) async throws -> HostedLinkSession {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let client_name: String
            let language: String
            let country_codes: [String]
            let user: User
            let products: [String]
            let transactions: TransactionsOpts
            /// Optional OAuth app-to-app return (https Universal Link preferred in Production).
            let redirect_uri: String?
            let hosted_link: HostedLink

            struct User: Encodable {
                let client_user_id: String
            }

            struct TransactionsOpts: Encodable {
                let days_requested: Int
            }

            struct HostedLink: Encodable {
                let is_mobile_app: Bool
                let completion_redirect_uri: String
                let url_lifetime_seconds: Int
            }

            enum CodingKeys: String, CodingKey {
                case client_id, secret, client_name, language, country_codes
                case user, products, transactions, redirect_uri, hosted_link
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(client_id, forKey: .client_id)
                try c.encode(secret, forKey: .secret)
                try c.encode(client_name, forKey: .client_name)
                try c.encode(language, forKey: .language)
                try c.encode(country_codes, forKey: .country_codes)
                try c.encode(user, forKey: .user)
                try c.encode(products, forKey: .products)
                try c.encode(transactions, forKey: .transactions)
                try c.encodeIfPresent(redirect_uri, forKey: .redirect_uri)
                try c.encode(hosted_link, forKey: .hosted_link)
            }
        }

        // Only send redirect_uri when it is a real http(s) URI allowlisted in the Dashboard.
        // Custom schemes belong in completion_redirect_uri, not redirect_uri.
        let redirect = PlaidCredentialsStore.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let oauthRedirect: String? = {
            guard !redirect.isEmpty else { return nil }
            if redirect.hasPrefix("http://") || redirect.hasPrefix("https://") {
                return redirect
            }
            return nil
        }()

        let body = Body(
            client_id: PlaidCredentialsStore.clientID,
            secret: PlaidCredentialsStore.secret,
            client_name: clientName,
            language: "en",
            country_codes: ["US"],
            user: .init(client_user_id: userID),
            products: ["transactions"],
            transactions: .init(days_requested: 730),
            redirect_uri: oauthRedirect,
            hosted_link: .init(
                is_mobile_app: true,
                completion_redirect_uri: PlaidHostedLink.completionRedirectURI,
                url_lifetime_seconds: 1800
            )
        )

        struct Response: Decodable {
            let link_token: String
            let hosted_link_url: String?
            let expiration: String?
        }

        let response: Response = try await post(path: "/link/token/create", body: body)
        guard let urlString = response.hosted_link_url,
              let url = URL(string: urlString) else {
            throw PlaidAPIError.http(
                status: 0,
                code: nil,
                message: "Plaid did not return a hosted_link_url. Ensure Hosted Link is available for your account."
            )
        }
        return HostedLinkSession(linkToken: response.link_token, hostedLinkURL: url)
    }

    struct LinkSuccessPayload: Sendable {
        let publicToken: String
        let institutionName: String?
        let accountNames: [String]
    }

    /// Poll `/link/token/get` until a public_token is available (or timeout).
    static func waitForLinkSuccess(
        linkToken: String,
        maxAttempts: Int = 24,
        delayNanoseconds: UInt64 = 500_000_000
    ) async throws -> LinkSuccessPayload {
        try PlaidCredentialsStore.requireConfigured()

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            do {
                if let payload = try await fetchLinkSuccess(linkToken: linkToken) {
                    return payload
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
            ?? PlaidAPIError.http(
                status: 0,
                code: nil,
                message: "Link closed without linking a bank (or the session timed out). Try Link again."
            )
    }

    /// One shot `/link/token/get` → first successful Item add, if any.
    static func fetchLinkSuccess(linkToken: String) async throws -> LinkSuccessPayload? {
        struct Body: Encodable {
            let client_id: String
            let secret: String
            let link_token: String
        }

        struct Response: Decodable {
            let link_sessions: [LinkSession]?

            struct LinkSession: Decodable {
                let results: Results?
                let on_success: OnSuccess?

                struct Results: Decodable {
                    let item_add_results: [ItemAdd]?
                }

                struct ItemAdd: Decodable {
                    let public_token: String?
                    let institution: Institution?
                    let accounts: [Account]?
                }

                struct OnSuccess: Decodable {
                    let public_token: String?
                    let metadata: SuccessMetadata?
                }

                struct SuccessMetadata: Decodable {
                    let institution: Institution?
                    let accounts: [Account]?
                }

                struct Institution: Decodable {
                    let name: String?
                    let institution_id: String?
                }

                struct Account: Decodable {
                    let name: String?
                    let mask: String?
                    let meta: Meta?

                    struct Meta: Decodable {
                        let name: String?
                        let number: String?
                    }
                }
            }
        }

        let response: Response = try await post(
            path: "/link/token/get",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                link_token: linkToken
            )
        )

        func labels(from accounts: [Response.LinkSession.Account]?) -> [String] {
            guard let accounts else { return [] }
            return accounts.compactMap { acc in
                let name = acc.name ?? acc.meta?.name
                let mask = acc.mask ?? acc.meta?.number
                guard let name else { return nil }
                if let mask, !mask.isEmpty { return "\(name) ···\(mask)" }
                return name
            }
        }

        for session in response.link_sessions ?? [] {
            if let add = session.results?.item_add_results?.first,
               let token = add.public_token, !token.isEmpty {
                return LinkSuccessPayload(
                    publicToken: token,
                    institutionName: add.institution?.name,
                    accountNames: labels(from: add.accounts)
                )
            }
            if let success = session.on_success,
               let token = success.public_token, !token.isEmpty {
                return LinkSuccessPayload(
                    publicToken: token,
                    institutionName: success.metadata?.institution?.name,
                    accountNames: labels(from: success.metadata?.accounts)
                )
            }
        }
        return nil
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
