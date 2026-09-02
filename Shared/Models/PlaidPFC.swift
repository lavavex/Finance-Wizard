//
//  PlaidPFC.swift
//  Finance Wizard
//
//  Plaid's personal_finance_category (primary + detailed + confidence).
//
//  Lives in Shared/ rather than beside the API client because the classifier that reads it
//  (PlaidCategoryMapper) is compiled into the widget too — see that file's header.
//

import Foundation

struct PlaidPFC: Decodable, Sendable {
    let primary: String?
    let detailed: String?
    let confidence_level: String?
}
