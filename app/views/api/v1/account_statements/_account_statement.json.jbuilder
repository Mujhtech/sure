# frozen_string_literal: true

json.id account_statement.id
json.filename account_statement.filename
json.content_type account_statement.content_type
json.byte_size account_statement.byte_size
json.source account_statement.source
json.upload_status account_statement.upload_status
json.review_status account_statement.review_status
json.institution_name_hint account_statement.institution_name_hint
json.account_name_hint account_statement.account_name_hint
json.account_last4_hint account_statement.account_last4_hint
json.period_start_on account_statement.period_start_on&.iso8601
json.period_end_on account_statement.period_end_on&.iso8601
json.opening_balance account_statement.opening_balance&.to_s
json.closing_balance account_statement.closing_balance&.to_s
json.currency account_statement.statement_currency
json.parser_confidence account_statement.parser_confidence&.to_s
json.match_confidence account_statement.match_confidence&.to_s
json.manageable account_statement.manageable_by?(current_resource_owner)
json.download_path download_api_v1_account_statement_path(account_statement)

if account_statement.account.present?
  json.account do
    json.id account_statement.account.id
    json.name account_statement.account.name
    json.account_type account_statement.account.accountable_type.underscore
  end
else
  json.account nil
end

if account_statement.suggested_account.present?
  json.suggested_account do
    json.id account_statement.suggested_account.id
    json.name account_statement.suggested_account.name
    json.account_type account_statement.suggested_account.accountable_type.underscore
  end
else
  json.suggested_account nil
end

json.reconciliation_checks account_statement.reconciliation_checks do |check|
  json.key check[:key]
  json.statement_amount check[:statement_amount].to_s
  json.ledger_amount check[:ledger_amount].to_s
  json.difference check[:difference].to_s
  json.status check[:status]
end

json.created_at account_statement.created_at.iso8601
json.updated_at account_statement.updated_at.iso8601
