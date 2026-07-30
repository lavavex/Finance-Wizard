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
    /// - Parameter accessToken: When set, opens **update mode** to re-authenticate an existing Item
    ///   (and optionally pick more accounts). Do not pass products in that case.
    static func createHostedLinkSession(
        clientName: String = "Finance Wizard",
        userID: String = "finance-wizard-user",
        accessToken: String? = nil
    ) async throws -> HostedLinkSession {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let client_name: String
            let language: String
            let country_codes: [String]
            let user: User
            /// New Link only — omit in update mode.
            let products: [String]?
            /// Credit APR / due dates when the institution supports Liabilities (new Link).
            let required_if_supported_products: [String]?
            let transactions: TransactionsOpts?
            /// Existing Item access token → update mode (re-auth / add accounts).
            let access_token: String?
            let update: UpdateOpts?
            /// Optional OAuth app-to-app return (https Universal Link preferred in Production).
            let redirect_uri: String?
            let hosted_link: HostedLink

            struct User: Encodable {
                let client_user_id: String
            }

            struct TransactionsOpts: Encodable {
                let days_requested: Int
            }

            struct UpdateOpts: Encodable {
                /// Let the user add/remove accounts while repairing login.
                let account_selection_enabled: Bool
            }

            struct HostedLink: Encodable {
                let is_mobile_app: Bool
                /// Custom scheme allowed only when `is_mobile_app` is true.
                let completion_redirect_uri: String?
                let url_lifetime_seconds: Int

                enum CodingKeys: String, CodingKey {
                    case is_mobile_app, completion_redirect_uri, url_lifetime_seconds
                }

                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(is_mobile_app, forKey: .is_mobile_app)
                    try c.encodeIfPresent(completion_redirect_uri, forKey: .completion_redirect_uri)
                    try c.encode(url_lifetime_seconds, forKey: .url_lifetime_seconds)
                }
            }

            enum CodingKeys: String, CodingKey {
                case client_id, secret, client_name, language, country_codes
                case user, products, required_if_supported_products, transactions
                case access_token, update, redirect_uri, hosted_link
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(client_id, forKey: .client_id)
                try c.encode(secret, forKey: .secret)
                try c.encode(client_name, forKey: .client_name)
                try c.encode(language, forKey: .language)
                try c.encode(country_codes, forKey: .country_codes)
                try c.encode(user, forKey: .user)
                try c.encodeIfPresent(products, forKey: .products)
                try c.encodeIfPresent(
                    required_if_supported_products,
                    forKey: .required_if_supported_products
                )
                try c.encodeIfPresent(transactions, forKey: .transactions)
                try c.encodeIfPresent(access_token, forKey: .access_token)
                try c.encodeIfPresent(update, forKey: .update)
                try c.encodeIfPresent(redirect_uri, forKey: .redirect_uri)
                try c.encode(hosted_link, forKey: .hosted_link)
            }
        }

        // redirect_uri (OAuth) MUST be https and allowlisted in the Plaid Dashboard.
        // Never send a custom scheme there — Plaid rejects it with
        // "redirect_uri must use HTTPS". Custom schemes belong only on
        // hosted_link.completion_redirect_uri (closes ASWebAuthenticationSession).
        let completionURI = PlaidHostedLink.completionRedirectURI
        let httpsRedirect = PlaidCredentialsStore.httpsRedirectURI
        // Full mobile Hosted Link (app-to-app OAuth + custom-scheme completion)
        // only when we have a valid https redirect. Otherwise omit redirect_uri
        // entirely (sending financewizard:// was the Relink failure).
        let useMobileAppHostedLink = httpsRedirect != nil

        let isUpdate = accessToken.map { !$0.isEmpty } ?? false
        let body = Body(
            client_id: PlaidCredentialsStore.clientID,
            secret: PlaidCredentialsStore.secret,
            client_name: clientName,
            language: "en",
            country_codes: ["US"],
            user: .init(client_user_id: userID),
            products: isUpdate ? nil : ["transactions"],
            required_if_supported_products: isUpdate ? nil : ["liabilities"],
            transactions: isUpdate ? nil : .init(days_requested: 730),
            access_token: isUpdate ? accessToken : nil,
            update: isUpdate ? .init(account_selection_enabled: true) : nil,
            redirect_uri: httpsRedirect,
            hosted_link: .init(
                is_mobile_app: useMobileAppHostedLink,
                // Custom-scheme completion only valid for mobile Hosted Link sessions.
                completion_redirect_uri: useMobileAppHostedLink ? completionURI : nil,
                url_lifetime_seconds: 1800
            )
        )

        struct Response: Decodable {
            let link_token: String
            let hosted_link_url: String?
            let expiration: String?
        }

        let response: Response
        do {
            response = try await post(path: "/link/token/create", body: body)
        } catch let err as PlaidAPIError {
            // Surface a clear fix when Plaid wants an https redirect (OAuth / update mode).
            if case .http(_, let code, let message) = err {
                let blob = "\(code ?? "") \(message ?? "")".lowercased()
                if blob.contains("redirect_uri") && httpsRedirect == nil {
                    throw PlaidAPIError.http(
                        status: 0,
                        code: code,
                        message: """
                        Plaid needs an https OAuth redirect URI for this bank (and for Relink). \
                        In Settings, set “OAuth redirect” to an https URL you’ve added under \
                        Plaid Dashboard → Team Settings → API → Allowed redirect URIs. \
                        (Custom schemes like financewizard:// are only for the in-app completion callback.)
                        """
                    )
                }
            }
            throw err
        }
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

    /// On-demand bank pull (`/transactions/refresh`). Optional paid add-on; soft-fail if not enabled.
    /// After success, call `/transactions/sync` to pull the new cursor updates.
    @discardableResult
    static func transactionsRefresh(accessToken: String) async throws -> String? {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
        }

        struct Response: Decodable {
            let request_id: String?
        }

        let response: Response = try await post(
            path: "/transactions/refresh",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken
            )
        )
        return response.request_id
    }

    /// Recurring inflow/outflow streams (`/transactions/recurring/get`). Optional add-on.
    static func transactionsRecurringGet(
        accessToken: String,
        accountIDs: [String]? = nil
    ) async throws -> PlaidRecurringGetResponse {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
            let account_ids: [String]?
        }

        return try await post(
            path: "/transactions/recurring/get",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken,
                account_ids: accountIDs
            )
        )
    }

    /// Institution id + error status for a linked Item (`/item/get`).
    static func itemGet(accessToken: String) async throws -> PlaidItemGetResult {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
        }

        struct Response: Decodable {
            let item: Item

            struct Item: Decodable {
                let item_id: String?
                let institution_id: String?
                let error: ItemError?

                struct ItemError: Decodable {
                    let error_code: String?
                    let error_message: String?
                    let display_message: String?
                }
            }
        }

        let response: Response = try await post(
            path: "/item/get",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken
            )
        )
        return PlaidItemGetResult(
            itemID: response.item.item_id,
            institutionID: response.item.institution_id,
            errorCode: response.item.error?.error_code,
            errorMessage: response.item.error?.display_message
                ?? response.item.error?.error_message
        )
    }

    /// Institution id for a linked Item (`/item/get`).
    static func itemInstitutionID(accessToken: String) async throws -> String? {
        try await itemGet(accessToken: accessToken).institutionID
    }

    /// Logo + brand color via `/institutions/get_by_id` (optional metadata).
    /// This is the supported way to show bank branding — not product card photography.
    static func institutionBranding(institutionID: String) async throws -> PlaidInstitutionBranding {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let institution_id: String
            let country_codes: [String]
            let options: Options

            struct Options: Encodable {
                let include_optional_metadata: Bool
            }
        }

        struct Response: Decodable {
            let institution: Institution

            struct Institution: Decodable {
                let institution_id: String
                let name: String?
                let logo: String?
                let primary_color: String?
                let url: String?
            }
        }

        let response: Response = try await post(
            path: "/institutions/get_by_id",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                institution_id: institutionID,
                country_codes: ["US"],
                options: .init(include_optional_metadata: true)
            )
        )
        return PlaidInstitutionBranding(
            institutionID: response.institution.institution_id,
            name: response.institution.name,
            logoBase64: response.institution.logo,
            primaryColorHex: response.institution.primary_color
        )
    }

    /// Current balances / credit limits for all accounts on an Item.
    static func accountsGet(accessToken: String) async throws -> [PlaidAccountDetail] {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
        }

        struct Response: Decodable {
            let accounts: [PlaidAccountDetail]
        }

        let response: Response = try await post(
            path: "/accounts/get",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken
            )
        )
        return response.accounts
    }

    /// Credit-card terms: APR, min payment, due dates, statement balance (`/liabilities/get`).
    /// Requires Liabilities on the Item (Link with `required_if_supported_products: liabilities`).
    static func liabilitiesGet(accessToken: String) async throws -> [PlaidCreditLiability] {
        try PlaidCredentialsStore.requireConfigured()

        struct Body: Encodable {
            let client_id: String
            let secret: String
            let access_token: String
        }

        struct Response: Decodable {
            let liabilities: Liabilities?

            struct Liabilities: Decodable {
                let credit: [PlaidCreditLiability]?
            }
        }

        let response: Response = try await post(
            path: "/liabilities/get",
            body: Body(
                client_id: PlaidCredentialsStore.clientID,
                secret: PlaidCredentialsStore.secret,
                access_token: accessToken
            )
        )
        return response.liabilities?.credit ?? []
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

/// Full account row from `/accounts/get` (includes balances).
struct PlaidAccountDetail: Decodable {
    let account_id: String
    let name: String?
    let official_name: String?
    let mask: String?
    let type: String?
    let subtype: String?
    let balances: PlaidBalances?
}

struct PlaidInstitutionBranding: Sendable {
    let institutionID: String
    let name: String?
    /// Base64 PNG (no data: prefix) when Plaid has a logo
    let logoBase64: String?
    let primaryColorHex: String?
}

struct PlaidBalances: Decodable {
    let available: Double?
    let current: Double?
    let limit: Double?
    let iso_currency_code: String?
}

/// One credit-card liability from `/liabilities/get`.
struct PlaidCreditLiability: Decodable, Sendable {
    let account_id: String?
    let aprs: [PlaidAPR]?
    let is_overdue: Bool?
    let last_payment_amount: Double?
    let last_payment_date: String?
    let last_statement_issue_date: String?
    let last_statement_balance: Double?
    let minimum_payment_amount: Double?
    let next_payment_due_date: String?
}

struct PlaidAPR: Decodable, Sendable {
    let apr_percentage: Double?
    let apr_type: String?
    let balance_subject_to_apr: Double?
    let interest_charge_amount: Double?
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
    /// Prefer for UI date when present (user-facing “when I spent”).
    let authorized_date: String?
    /// Posted tx points at its former pending twin (delete the pending row).
    let pending_transaction_id: String?
    let merchant_entity_id: String?
    let logo_url: String?
    let website: String?
    let counterparties: [PlaidCounterparty]?

    /// Best merchant logo: top-level, else first merchant counterparty.
    var resolvedLogoURL: String? {
        if let logo_url, !logo_url.isEmpty { return logo_url }
        return counterparties?.first(where: { $0.type == "merchant" })?.logo_url
            ?? counterparties?.first?.logo_url
    }

    var resolvedWebsite: String? {
        if let website, !website.isEmpty { return website }
        return counterparties?.first(where: { $0.type == "merchant" })?.website
            ?? counterparties?.first?.website
    }

    var resolvedMerchantEntityID: String? {
        if let merchant_entity_id, !merchant_entity_id.isEmpty { return merchant_entity_id }
        return counterparties?.first(where: { $0.type == "merchant" })?.entity_id
    }
}

struct PlaidCounterparty: Decodable {
    let name: String?
    let entity_id: String?
    let type: String?
    let website: String?
    let logo_url: String?
    let confidence_level: String?
}

struct PlaidPFC: Decodable {
    let primary: String?
    let detailed: String?
    let confidence_level: String?
}

struct PlaidItemGetResult: Sendable {
    let itemID: String?
    let institutionID: String?
    let errorCode: String?
    let errorMessage: String?

    var needsRelink: Bool {
        guard let code = errorCode?.uppercased() else { return false }
        return code == "ITEM_LOGIN_REQUIRED"
            || code == "ITEM_LOCKED"
            || code == "ITEM_NOT_SUPPORTED"
            || code == "USER_PERMISSION_REVOKED"
            || code == "PENDING_EXPIRATION"
    }
}

struct PlaidRecurringGetResponse: Decodable {
    let inflow_streams: [PlaidRecurringStream]?
    let outflow_streams: [PlaidRecurringStream]?
    let updated_datetime: String?
    let request_id: String?
}

struct PlaidRecurringStream: Decodable {
    let account_id: String?
    let stream_id: String
    let description: String?
    let merchant_name: String?
    let first_date: String?
    let last_date: String?
    let predicted_next_date: String?
    let frequency: String?
    let transaction_ids: [String]?
    let average_amount: PlaidStreamAmount?
    let last_amount: PlaidStreamAmount?
    let is_active: Bool?
    let status: String?
    let personal_finance_category: PlaidPFC?
}

struct PlaidStreamAmount: Decodable {
    let amount: Double?
    let iso_currency_code: String?
}
