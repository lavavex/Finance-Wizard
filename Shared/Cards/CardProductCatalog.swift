//
//  CardProductCatalog.swift
//  Finance Wizard
//
//  Earn rates & benefits aligned with MaxRewards card pages (public reviews).
//  Points cards: stored as Ultimate Rewards multipliers (x); MaxRewards often
//  shows % at 1.25¢/pt — we convert: 3.8%→3x, 6.3%→5x, 1.9%→1.5x, 1.3%→1x.
//  Cash-back cards: percent (5 = 5%). Caps / portal-only notes included.
//  Sources: maxrewards.com card detail pages (fetched 2026-07).
//

import Foundation

/// A known consumer card / debit product with default earn rates.
/// Built-in catalog row — not user-edited storage (that lives in CardBenefitsProfile).
struct CardProductPreset: Identifiable, Hashable, Sendable {
    /// Stable product id (e.g. chase_freedom_unlimited) used as productKey on profiles.
    var id: String
    var displayName: String
    var issuer: String
    /// points vs cashback — controls how rates are labeled and valued.
    var rewardKind: RewardKind
    /// Points: x per $; cash back: percent (3 = 3%).
    var defaultRate: Double
    /// How many cents one point is worth when estimating USD (points cards).
    var pointValueCents: Double
    /// nil = unknown / not modeled; 0 = truly no fee.
    var annualFee: Double?
    /// Reward category → rate (Dining, Gas, …). Use only when the boost is really category-wide.
    var categoryRates: [String: Double]
    /// Partner merchants: one display name, many title match needles (not a whole category).
    var merchantBoosts: [MerchantBoostPartner]
    /// Human notes / source attribution shown in benefits UI.
    var notes: String
    var benefits: [CardBenefitItem]
    /// Match against Plaid officialName / name / institution (lowercase needles).
    var matchNeedles: [String]
    /// MaxRewards path for attribution (no scraping at runtime).
    var maxRewardsPath: String?

    init(
        id: String,
        displayName: String,
        issuer: String,
        rewardKind: RewardKind,
        defaultRate: Double,
        pointValueCents: Double,
        annualFee: Double?,
        categoryRates: [String: Double],
        merchantBoosts: [MerchantBoostPartner] = [],
        notes: String,
        benefits: [CardBenefitItem],
        matchNeedles: [String],
        maxRewardsPath: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.issuer = issuer
        self.rewardKind = rewardKind
        self.defaultRate = defaultRate
        self.pointValueCents = pointValueCents
        self.annualFee = annualFee
        self.categoryRates = categoryRates
        self.merchantBoosts = merchantBoosts
        self.notes = notes
        self.benefits = benefits
        self.matchNeedles = matchNeedles
        self.maxRewardsPath = maxRewardsPath
    }
}

/// Built-in product list + lookup / profile factory helpers.
enum CardProductCatalog {
    /// All built-in personal products we ship rates for.
    /// Dense data below: each CardProductPreset is one card’s defaults (comments on groups only).
    static let all: [CardProductPreset] = [
        // MARK: - Chase (MaxRewards)
        // Points in Ultimate Rewards “x”; cash-back cards use percent.

        CardProductPreset(
            id: "chase_freedom_unlimited",
            displayName: "Chase Freedom Unlimited®",
            issuer: "Chase",
            rewardKind: .points,
            defaultRate: 1.5, // MaxRewards 1.9% @ 1.25¢ ≈ 1.5x
            pointValueCents: 1.25,
            annualFee: 0,
            categoryRates: [
                "Travel (Portal)": 5, // MaxRewards ~6.3% at 1.25c/pt
                "Dining": 3, // takeout / eligible delivery
                "Drugstores": 3
            ],
            notes: """
            Source: maxrewards.com/credit-cards/chase-freedom-unlimited
            • 5x travel via Chase Travel · 3x dining & drugstores · 1.5x everything else
            • Valuation shown on MaxRewards at 1.25¢/UR point
            • DoorDash promo credits require enrollment
            """,
            benefits: [
                .init(title: "No annual fee", detail: "$0"),
                .init(title: "DoorDash non-restaurant promo", detail: "Periodic promo credit (enrollment; ~$40/yr on MaxRewards)"),
                .init(title: "Complimentary DashPass", detail: "DoorDash / Caviar after activation (terms)"),
                .init(title: "Purchase Protection", detail: "Up to 120 days, $500/item (terms)"),
                .init(title: "Auto Rental CDW", detail: "Secondary in U.S. (terms)"),
                .init(title: "Extended Warranty", detail: "+1 year on eligible warranties ≤3 years"),
                .init(title: "Ultimate Rewards", detail: "Pair with Sapphire to transfer / boost value")
            ],
            matchNeedles: ["freedom unlimited"],
            maxRewardsPath: "/credit-cards/chase-freedom-unlimited"
        ),

        CardProductPreset(
            id: "chase_freedom_flex",
            displayName: "Chase Freedom Flex®",
            issuer: "Chase",
            rewardKind: .points,
            defaultRate: 1, // 1.3% @ 1.25¢
            pointValueCents: 1.25,
            annualFee: 0,
            categoryRates: [
                "Travel (Portal)": 5,
                "Dining": 3,
                "Drugstores": 3,
                "Gas": 5 // rotating quarterly often — edit when inactive
            ],
            notes: """
            Source: maxrewards.com/credit-cards/chase-freedom-flex
            • 5x Chase Travel · 3x drugstores · 1x base · rotating 5% quarterly (up to $1,500)
            • Set Gas (or other) to 5x only while that quarterly category is active
            • 3% foreign transaction fee
            """,
            benefits: [
                .init(title: "No annual fee", detail: "$0"),
                .init(title: "5% rotating categories", detail: "Activate each quarter in Chase; $1,500 cap"),
                .init(title: "DoorDash non-restaurant promo", detail: "Enrollment; MaxRewards ~$40/yr"),
                .init(title: "Complimentary DashPass", detail: "DoorDash / Caviar (terms)"),
                .init(title: "Purchase Protection", detail: "Up to 120 days, $500/item"),
                .init(title: "Auto Rental CDW", detail: "Secondary in U.S."),
                .init(title: "Extended Warranty", detail: "+1 year on eligible warranties"),
                .init(title: "World Elite Mastercard", detail: "Concierge access (terms)")
            ],
            matchNeedles: ["freedom flex"],
            maxRewardsPath: "/credit-cards/chase-freedom-flex"
        ),

        CardProductPreset(
            id: "chase_sapphire_preferred",
            displayName: "Chase Sapphire Preferred®",
            issuer: "Chase",
            rewardKind: .points,
            defaultRate: 1, // 1.3% @ 1.25¢
            pointValueCents: 1.25,
            annualFee: 95,
            categoryRates: [
                "Travel (Portal)": 5,
                "Travel (Other)": 2,
                "Dining": 3,
                "Gas": 3,
                "Online Grocery": 3,
                "Streaming": 3
            ],
            notes: """
            Source: maxrewards.com/credit-cards/chase-sapphire-preferred
            MaxRewards earn table (at 1.25c/pt): Chase Travel 6.3%; dining / gas-EV / online grocery / streaming 3.8%; other travel 2.5%; other 1.3%.
            Mapped to portal 5x, other travel 2x, dining/gas/online grocery/streaming 3x, base 1x.
            """,
            benefits: [
                .init(title: "$50 hotel credit (×2)", detail: "Chase Travel hotels; semi-annual"),
                .init(title: "DoorDash DashPass", detail: "Complimentary after activation"),
                .init(title: "DoorDash promo credit", detail: "Non-restaurant promos; enrollment"),
                .init(title: "Global Entry / TSA PreCheck", detail: "Application fee statement credit"),
                .init(title: "Primary rental car CDW", detail: "Up to $60,000; decline the counter CDW"),
                .init(title: "No foreign transaction fee", detail: "")
            ],
            matchNeedles: ["sapphire preferred"],
            maxRewardsPath: "/credit-cards/chase-sapphire-preferred"
        ),

        CardProductPreset(
            id: "chase_sapphire_reserve",
            displayName: "Chase Sapphire Reserve®",
            issuer: "Chase",
            rewardKind: .points,
            defaultRate: 1, // 1.3% @ 1.25¢
            pointValueCents: 1.25,
            annualFee: 795,
            categoryRates: [
                "Travel (Portal)": 8, // Chase Travel / The Edit 10% ≈ 8x @ 1.25¢; direct flights/hotels 4x — see notes
                "Dining": 3 // 3.8% worldwide ≈ 3x
            ],
            notes: """
            Source: maxrewards.com/credit-cards/chase-sapphire-reserve
            MaxRewards: Chase Travel / The Edit 10%; flights & hotels booked direct 5%; dining 3.8%; other 1.3% (at 1.25¢/pt → ~8x / 4x / 3x / 1x).
            Travel default set to 8x for portal-heavy use; set to 4x if you mostly book airlines/hotels direct.
            """,
            benefits: [
                .init(title: "$300 Travel credit", detail: "Annual travel purchases"),
                .init(title: "$500 The Edit hotel credit", detail: "Select hotels; enrollment may be required"),
                .init(title: "Southwest credit", detail: "When offered on Reserve"),
                .init(title: "$300 StubHub credit", detail: "Annual; terms apply"),
                .init(title: "$300 dining credit", detail: "Annual; terms apply"),
                .init(title: "DoorDash credit", detail: "Promo / credit when offered"),
                .init(title: "DoorDash DashPass", detail: "Complimentary after activation"),
                .init(title: "Shops at Chase credit", detail: "Select retail"),
                .init(title: "Apple TV+ / Apple Music", detail: "Subscription benefit; enrollment"),
                .init(title: "Lyft credit", detail: "When offered"),
                .init(title: "Peloton credit", detail: "Equipment credit when offered"),
                .init(title: "Global Entry / TSA PreCheck", detail: "Application fee statement credit"),
                .init(title: "Primary rental car CDW", detail: "Up to $75,000 U.S. & abroad"),
                .init(title: "Trip delay reimbursement", detail: "Up to $500/traveler after 6+ hours"),
                .init(title: "Sapphire Lounges / Reserve Suites", detail: "Where available"),
                .init(title: "No foreign transaction fee", detail: "")
            ],
            matchNeedles: ["sapphire reserve"],
            maxRewardsPath: "/credit-cards/chase-sapphire-reserve"
        ),

        CardProductPreset(
            id: "chase_prime_visa",
            displayName: "Prime Visa",
            issuer: "Chase",
            rewardKind: .cashback,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 0,
            categoryRates: [
                "Travel (Portal)": 5, // Chase Travel is a booking channel, not a single storefront
                "Dining": 2,
                "Gas": 2,
                "Transit": 2
            ],
            merchantBoosts: [
                MerchantBoostPartner(
                    id: "amazon",
                    displayName: "Amazon",
                    matchNeedles: [
                        "amazon.com", "amzn.com", "amzn", "amazon fresh",
                        "amazon prime", "amazon marketplace", "amazon"
                    ],
                    rate: 5
                ),
                MerchantBoostPartner(
                    id: "whole_foods",
                    displayName: "Whole Foods",
                    matchNeedles: ["whole foods", "wholefoods", "whole foods market"],
                    rate: 5
                )
            ],
            notes: """
            Source: maxrewards.com/credit-cards/prime-visa
            • 5% Amazon.com, Amazon Fresh, Whole Foods, Chase Travel (eligible Prime)
            • 2% gas stations, restaurants, local transit & commuting (incl. rideshare)
            • 1% all other · $0 AF · no foreign transaction fee
            Amazon is one partner with multiple title matches (amazon.com, amzn.com, …).
            """,
            benefits: [
                .init(title: "No annual fee", detail: "$0"),
                .init(title: "No foreign transaction fee", detail: ""),
                .init(title: "5% Chase Travel (Prime)", detail: "Flights, hotels, cars via Chase Travel"),
                .init(title: "Purchase Protection", detail: "120 days, up to $500/item"),
                .init(title: "Extended Warranty", detail: "+1 year on eligible warranties"),
                .init(title: "Baggage Delay Insurance", detail: "Up to $100/day for 3 days"),
                .init(title: "Travel Accident Insurance", detail: "Up to $500,000 when fare charged to card"),
                .init(title: "Visa Signature Luxury Hotel Collection", detail: "Upgrades / Wi‑Fi when available")
            ],
            matchNeedles: ["prime visa", "amazon prime"],
            maxRewardsPath: "/credit-cards/prime-visa"
        ),

        CardProductPreset(
            id: "chase_amazon_visa",
            displayName: "Amazon Visa (no Prime)",
            issuer: "Chase",
            rewardKind: .cashback,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 0,
            categoryRates: [
                "Travel (Other)": 3, // portal / travel book — not merchant-specific
                "Dining": 2,
                "Gas": 2
            ],
            merchantBoosts: [
                MerchantBoostPartner(
                    id: "amazon",
                    displayName: "Amazon",
                    matchNeedles: [
                        "amazon.com", "amzn.com", "amzn", "amazon fresh", "amazon"
                    ],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "whole_foods",
                    displayName: "Whole Foods",
                    matchNeedles: ["whole foods", "wholefoods"],
                    rate: 3
                )
            ],
            notes: "Without Prime: 3% Amazon/Whole Foods/Chase Travel (Amazon is one partner, many title matches); 2% gas, restaurants; 1% other.",
            benefits: [
                .init(title: "No annual fee", detail: "$0")
            ],
            matchNeedles: ["amazon visa"],
            maxRewardsPath: nil
        ),

        // MARK: - Amex (MaxRewards)

        CardProductPreset(
            id: "amex_blue_cash_everyday",
            displayName: "Blue Cash Everyday®",
            issuer: "American Express",
            rewardKind: .cashback,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 0,
            categoryRates: [
                "Groceries": 3, // U.S. supermarkets, up to $6k/yr
                "Gas": 3, // U.S. gas, up to $6k/yr
                "Online Retail": 3 // U.S. online retail, up to $6k/yr
            ],
            notes: """
            Source: maxrewards.com/credit-cards/blue-cash-everyday
            • 3% U.S. supermarkets, U.S. gas, U.S. online retail (each up to $6,000/yr then 1%)
            • 1% everywhere else · $0 AF
            """,
            benefits: [
                .init(title: "No annual fee", detail: "$0"),
                .init(title: "Home Chef credit", detail: "MaxRewards lists ~$15/mo ($180/yr); enrollment"),
                .init(title: "Disney streaming credit", detail: "MaxRewards lists ~$84/yr; enrollment"),
                .init(title: "Purchase Protection", detail: "Up to 90 days; limits apply"),
                .init(title: "Car Rental Loss & Damage", detail: "Secondary; exclusions apply"),
                .init(title: "Amex Special Ticket Access", detail: "Presales / reserved tickets (terms)"),
                .init(title: "Reward Dollars", detail: "Statement credit or Amazon.com checkout")
            ],
            matchNeedles: ["blue cash everyday", "blue cash everyday®"],
            maxRewardsPath: "/credit-cards/blue-cash-everyday"
        ),

        CardProductPreset(
            id: "amex_blue_cash_preferred",
            displayName: "Blue Cash Preferred®",
            issuer: "American Express",
            rewardKind: .cashback,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 95,
            categoryRates: [
                "Groceries": 6,
                "Streaming": 6,
                "Gas": 3
            ],
            notes: "6% U.S. supermarkets (cap $6k/yr), 6% select streaming, 3% gas/transit; $95 AF. Confirm current Amex terms.",
            benefits: [
                .init(title: "Disney Bundle credit", detail: "Enrollment required"),
                .init(title: "Annual fee", detail: "$95 (often waived year 1)")
            ],
            matchNeedles: ["blue cash preferred"],
            maxRewardsPath: nil
        ),

        CardProductPreset(
            id: "amex_gold",
            displayName: "American Express® Gold Card",
            issuer: "American Express",
            rewardKind: .points,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 325,
            categoryRates: [
                "Dining": 4,
                "Groceries": 4
            ],
            notes: "4x restaurants + U.S. supermarkets (cap). Credits need enrollment. Not pulled from MaxRewards in this pass.",
            benefits: [
                .init(title: "Dining credit", detail: "Monthly at enrolled partners"),
                .init(title: "Uber Cash", detail: "Enrollment required")
            ],
            matchNeedles: ["amex gold", "american express gold", "gold card"],
            maxRewardsPath: nil
        ),

        CardProductPreset(
            id: "amex_green",
            displayName: "American Express® Green Card",
            issuer: "American Express",
            rewardKind: .points,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 150,
            categoryRates: [
                "Travel (Other)": 3,
                "Dining": 3,
                "Gas": 3
            ],
            notes: "3x travel, transit, restaurants (confirm current Amex terms).",
            benefits: [],
            matchNeedles: ["amex green", "green card"],
            maxRewardsPath: nil
        ),

        CardProductPreset(
            id: "amex_platinum",
            displayName: "The Platinum Card®",
            issuer: "American Express",
            rewardKind: .points,
            defaultRate: 1,
            pointValueCents: 1,
            annualFee: 695,
            categoryRates: [
                "Travel (Portal)": 5,
                "Travel (Other)": 5
            ],
            notes: "5x flights/hotels with complex rules. High AF / credits — edit for your usage.",
            benefits: [
                .init(title: "Lounge access", detail: "Centurion / Priority Pass (terms)"),
                .init(title: "Statement credits", detail: "Airline, Uber, digital, etc.")
            ],
            matchNeedles: ["platinum card", "amex platinum"],
            maxRewardsPath: nil
        ),

        // MARK: - Apple (MaxRewards)

        CardProductPreset(
            id: "apple_card",
            displayName: "Apple Card",
            issuer: "Apple / Goldman Sachs",
            rewardKind: .cashback,
            // App assumption: 2% Daily Cash on all spend unless a higher category applies.
            // (Titanium 1% / partner 3% can still be edited per-txn or as temporary boosts.)
            defaultRate: 2,
            pointValueCents: 1,
            annualFee: 0,
            categoryRates: [:], // partners are merchants, not “all Drugstores”
            merchantBoosts: [
                // One partner chip each; needles only when they're the same merchant brand
                MerchantBoostPartner(
                    id: "walgreens",
                    displayName: "Walgreens",
                    matchNeedles: ["walgreens"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "duane_reade",
                    displayName: "Duane Reade",
                    matchNeedles: ["duane reade", "duanereade"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "nike",
                    displayName: "Nike",
                    matchNeedles: ["nike"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "uber",
                    displayName: "Uber",
                    matchNeedles: ["uber", "uber eats", "ubereats"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "panera",
                    displayName: "Panera",
                    matchNeedles: ["panera"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "exxon_mobil",
                    displayName: "ExxonMobil",
                    matchNeedles: ["exxon", "mobil", "exxonmobil"],
                    rate: 3
                ),
                MerchantBoostPartner(
                    id: "ace_hardware",
                    displayName: "Ace Hardware",
                    matchNeedles: ["ace hardware", "ace hdwe"],
                    rate: 3
                ),
                // Apple.com and Apple Store are the same partner
                MerchantBoostPartner(
                    id: "apple",
                    displayName: "Apple",
                    matchNeedles: ["apple.com", "apple store", "apple.com/bill"],
                    rate: 3
                )
            ],
            notes: """
            Finance Wizard default: 2% Daily Cash (Everything Else).
            3% only at partner merchants (each partner has multiple title matches).
            Amazon is 2% on Apple Card (use Prime Visa for Amazon earn).
            """,
            benefits: [
                .init(title: "No annual fee", detail: "$0"),
                .init(title: "No foreign transaction fee", detail: ""),
                .init(title: "No late fees", detail: ""),
                .init(title: "Daily Cash", detail: "2% base; 3% at partner merchants")
            ],
            matchNeedles: ["apple card"],
            maxRewardsPath: "/credit-cards/apple-card"
        ),

        // MARK: - X Money (not on MaxRewards; user-specified)

        CardProductPreset(
            id: "x_money",
            displayName: "X Money",
            issuer: "X Money",
            rewardKind: .cashback,
            defaultRate: 3,
            pointValueCents: 1,
            annualFee: 0,
            // Flat 3% lives on default / Everything Else — do not stamp every category at 3%.
            categoryRates: [:],
            notes: """
            3% cash back on debit card purchases (Visa). Modeled as Everything Else / default —
            not a separate boost on Dining, Shopping, etc. ACH / transfers / EPAY bill-pay do not earn
            (account ACH multiplier forced to 0 on Sync).
            """,
            benefits: [
                .init(title: "Debit rewards only", detail: "3% on card spend; ACH earns 0%"),
                .init(title: "No annual fee", detail: "")
            ],
            matchNeedles: ["x money", "xmoney"],
            maxRewardsPath: nil
        )
    ]

    /// Look up one product by its stable id (or nil if unknown).
    static func product(id: String) -> CardProductPreset? {
        all.first { $0.id == id }
    }

    /// All products whose issuer string contains `issuer` (case-insensitive).
    static func products(issuer: String) -> [CardProductPreset] {
        all.filter { $0.issuer.localizedCaseInsensitiveContains(issuer) }
    }

    /// Best automatic match for a linked BankAccount (or nil if ambiguous).
    static func match(account: BankAccount) -> CardProductPreset? {
        let hay = [
            account.officialName ?? "",
            account.name,
            account.institutionName,
            account.displayName
        ]
        .joined(separator: " ")
        .lowercased()

        // Longer needles are more specific (e.g. "sapphire reserve" beats "reserve").
        let scored: [(CardProductPreset, Int)] = all.compactMap { product in
            let hit = product.matchNeedles.first { hay.contains($0.lowercased()) }
            guard let hit else { return nil }
            return (product, hit.count)
        }
        .sorted { $0.1 > $1.1 }

        if let best = scored.first {
            // Short needle + multiple candidates → too ambiguous; leave unmatched
            if best.1 <= 5, scored.count != 1 { return nil }
            return best.0
        }

        // Special case: depository X Money is not always in name needles
        if account.isDepository,
           account.institutionName.localizedCaseInsensitiveContains("x money") {
            return product(id: "x_money")
        }
        return nil
    }

    /// Match a free-text payment method label (transactions without a linked account id).
    static func match(paymentMethod: String) -> CardProductPreset? {
        let hay = paymentMethod.lowercased()
        if hay.contains("apple card") { return product(id: "apple_card") }
        if hay.contains("x money") { return product(id: "x_money") }
        return all.first { p in
            p.matchNeedles.contains { hay.contains($0.lowercased()) }
        }
    }

    /// Build a benefits profile from a product preset (ready to save under `id`).
    /// Copies rates/benefits and strips flat defaults so storage stays compact.
    static func makeProfile(id: String, product: CardProductPreset) -> CardBenefitsProfile {
        var profile = CardBenefitsProfile.empty(id: id)
        profile.rewardKind = product.rewardKind
        profile.defaultMultiplier = product.defaultRate
        profile.pointValueCents = product.pointValueCents
        profile.annualFee = product.annualFee
        // Only store category keys that actually differ from the default rate
        // (so Apple Card 2% / X Money 3% don’t fan out into every reward category).
        // filter on a dictionary keeps pairs where the closure returns true.
        profile.categoryMultipliers = product.categoryRates.filter {
            abs($0.value - product.defaultRate) > 0.000_1
        }
        profile.merchantBoosts = product.merchantBoosts.filter {
            abs($0.rate - product.defaultRate) > 0.000_1
        }
        // Prefer nil over empty array for optional Codable fields
        if profile.merchantBoosts?.isEmpty == true {
            profile.merchantBoosts = nil
        }
        profile.merchantMultipliers = nil
        profile.notes = product.notes
        profile.benefits = product.benefits
        profile.productKey = product.id
        profile.productDisplayName = product.displayName
        profile.compactRatesMatchingDefault()
        return profile
    }
}
