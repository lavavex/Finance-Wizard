//
//  PlaidAPIClient.swift
//  Finance Wizard
//
//  Thin REST client for the user’s Plaid developer account.
//  Calls use client_id + secret from PlaidCredentialsStore.
//  Shared networking lives in private post(...).
//

import Foundation

// MARK: - Errors

/// Failures from Plaid configuration, HTTP, or JSON decoding.
enum PlaidAPIError: LocalizedError {
    /// client_id or secret missing from Settings.
    case notConfigured
    /// Could not build a valid URL from path + base.
    case badURL
    /// Non-2xx HTTP, optionally with Plaid’s error_code / message.
    case http(status: Int, code: String?, message: String)
    /// JSON decoded into the wrong shape.
    case decoding(String)
    /// Link finished without a public_token.
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

// MARK: - API client

/// Stateless helpers that talk to Plaid over HTTPS.
enum PlaidAPIClient {
    // MARK: - Public API — Hosted Link

    /// Hosted Link session for native mobile (`ASWebAuthenticationSession`).
    struct HostedLinkSession: Sendable {
        /// Opaque token identifying this Link session (used for polling).
        let linkToken: String
        /// URL to open in the secure browser.
        let hostedLinkURL: URL
    }

    /// Create link_token + Hosted Link URL (webview Link is deprecated).
    /// - Parameter accessToken: When set, opens **update mode** to re-authenticate an existing Item
    ///   (and optionally pick more accounts). Do not pass products in that case.
    /// - Returns: Session with link_token and hosted URL for the browser.
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
            /// New Link: `transactions`. Update mode: omit unless **adding** a product (e.g. liabilities).
            let products: [String]?
            /// Credit APR / due dates when the institution supports Liabilities.
            let required_if_supported_products: [String]?
            /// Consent to call product endpoints later (or after Relink) without re-init.
            let additional_consented_products: [String]?
            let transactions: TransactionsOpts?
            /// Existing Item access token → update mode (re-auth / add accounts / add products).
            let access_token: String?
            let update: UpdateOpts?
            /// Optional OAuth app-to-app return (https Universal Link preferred in Production).
            let redirect_uri: String?
            /// HTTPS endpoint for Item/Transactions webhooks (Cloudflare Worker).
            let webhook: String?
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

                // Omit nil completion URI — Plaid is picky about unexpected nulls.
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(is_mobile_app, forKey: .is_mobile_app)
                    try c.encodeIfPresent(completion_redirect_uri, forKey: .completion_redirect_uri)
                    try c.encode(url_lifetime_seconds, forKey: .url_lifetime_seconds)
                }
            }

            enum CodingKeys: String, CodingKey {
                case client_id, secret, client_name, language, country_codes
                case user, products, required_if_supported_products, additional_consented_products
                case transactions, access_token, update, redirect_uri, webhook, hosted_link
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
                try c.encodeIfPresent(
                    additional_consented_products,
                    forKey: .additional_consented_products
                )
                try c.encodeIfPresent(transactions, forKey: .transactions)
                try c.encodeIfPresent(access_token, forKey: .access_token)
                try c.encodeIfPresent(update, forKey: .update)
                try c.encodeIfPresent(redirect_uri, forKey: .redirect_uri)
                try c.encodeIfPresent(webhook, forKey: .webhook)
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
        // Liabilities (APR / due dates) needs explicit end-user consent (Data Transparency).
        // Calling /liabilities/get without it → ADDITIONAL_CONSENT_REQUIRED / PRODUCT_LIABILITIES.
        //
        // • New Link: initialize with transactions + liabilities-if-supported.
        // • Relink (update mode): do NOT put liabilities in `products` (only Assets/Income/etc.
        //   use that path). Put it in `additional_consented_products` so Link collects consent.
        //   Arrays must not overlap. See Plaid update mode → “Requesting additional consented products”.
        let body = Body(
            client_id: PlaidCredentialsStore.clientID,
            secret: PlaidCredentialsStore.secret,
            client_name: clientName,
            language: "en",
            country_codes: ["US"],
            user: .init(client_user_id: userID),
            products: isUpdate ? nil : ["transactions"],
            required_if_supported_products: isUpdate ? nil : ["liabilities"],
            // Relink only — new Link already covers liabilities via required_if_supported.
            additional_consented_products: isUpdate ? ["liabilities"] : nil,
            transactions: isUpdate ? nil : .init(days_requested: 730),
            access_token: isUpdate ? accessToken : nil,
            update: isUpdate ? .init(account_selection_enabled: true) : nil,
            redirect_uri: httpsRedirect,
            webhook: PlaidCredentialsStore.plaidWebhookURL,
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
                let blob = "\(code ?? "") \(message)".lowercased()
                if blob.contains("redirect_uri") && httpsRedirect == nil {
                    throw PlaidAPIError.http(
                        status: 0,
                        code: code,
                        message: """
                        Plaid rejected the OAuth redirect URI. Add this exact URL under \
                        Plaid Dashboard → Allowed redirect URIs: \
                        \(PlaidCredentialsStore.defaultRedirectURI) \
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

    /// Successful Link result: short-lived public_token plus bank metadata.
    struct LinkSuccessPayload: Sendable {
        let publicToken: String
        let institutionName: String?
        let accountNames: [String]
    }

    /// Poll `/link/token/get` until a public_token is available (or timeout).
    /// Used when Hosted Link may not bounce via custom scheme (OAuth edge cases).
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
    /// Returns nil if the user has not finished Link yet (keep polling).
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

        // Prefer item_add_results; fall back to on_success shape.
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

    // MARK: - Public API — Tokens & Items

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

    // MARK: - Public API — Transactions

    /// One page of /transactions/sync.
    /// Cursor pagination: empty cursor = full history; next_cursor continues the delta stream.
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

    // MARK: - Public API — Item status & institutions

    /// Institution id + error status + product access for a linked Item (`/item/get`).
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
                let products: [String]?
                let billed_products: [String]?
                let available_products: [String]?
                let consented_products: [String]?
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
                ?? response.item.error?.error_message,
            products: response.item.products ?? [],
            billedProducts: response.item.billed_products ?? [],
            availableProducts: response.item.available_products ?? [],
            consentedProducts: response.item.consented_products ?? []
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

    // MARK: - Public API — Accounts & liabilities

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

    /// Shared POST helper: encode body → URLSession → decode Response or throw PlaidAPIError.
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

/// Plaid’s standard error JSON when a request fails.
struct PlaidErrorBody: Decodable {
    let error_type: String?
    let error_code: String?
    let error_message: String?
    let display_message: String?
    let request_id: String?
}

/// One page from `/transactions/sync` (added / modified / removed + cursor).
struct TransactionsSyncPage: Decodable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    /// Pass this as `cursor` on the next call.
    let next_cursor: String
    /// If true, call again with next_cursor (more pages remain).
    let has_more: Bool
    let transactions_update_status: String?
    let accounts: [PlaidAccount]?
}

struct PlaidRemovedTransaction: Decodable {
    let transaction_id: String
    let account_id: String?
}

/// Lightweight account stub sometimes included on sync pages.
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

/// Bank logo + color for UI branding.
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

/// One bank transaction from Plaid.
struct PlaidTransaction: Decodable {
    let account_id: String
    /// Plaid sign: positive = money out, negative = money in.
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

/// personal_finance_category: Plaid’s taxonomy (primary + detailed codes).
struct PlaidPFC: Decodable {
    let primary: String?
    let detailed: String?
    let confidence_level: String?
}

/// Parsed result of `/item/get` with convenience flags for Relink / products.
struct PlaidItemGetResult: Sendable {
    let itemID: String?
    let institutionID: String?
    let errorCode: String?
    let errorMessage: String?
    var products: [String] = []
    var billedProducts: [String] = []
    var availableProducts: [String] = []
    var consentedProducts: [String] = []

    /// True when the user must re-authenticate in Link update mode.
    var needsRelink: Bool {
        guard let code = errorCode?.uppercased() else { return false }
        return code == "ITEM_LOGIN_REQUIRED"
            || code == "ITEM_LOCKED"
            || code == "ITEM_NOT_SUPPORTED"
            || code == "USER_PERMISSION_REVOKED"
            || code == "PENDING_EXPIRATION"
    }

    /// True when Liabilities is initialized / billed / consented on this Item.
    var hasLiabilitiesProduct: Bool {
        let all = Set(
            (products + billedProducts + availableProducts + consentedProducts)
                .map { $0.lowercased() }
        )
        return all.contains("liabilities")
    }
}

/// Response for optional recurring streams product.
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
