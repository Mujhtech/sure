# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

json.id pledge.id
json.goal_id pledge.goal_id
json.amount pledge.amount_money.format
json.amount_cents money_to_minor_units.call(pledge.amount_money)
json.currency pledge.currency
json.kind pledge.kind
json.status pledge.status
json.expires_at pledge.expires_at.iso8601
json.days_left pledge.days_left
json.matched_transaction_id pledge.matched_transaction_id

json.account do
  json.id pledge.account.id
  json.name pledge.account.name
  json.account_type pledge.account.accountable_type&.underscore
end

json.created_at pledge.created_at.iso8601
json.updated_at pledge.updated_at.iso8601
