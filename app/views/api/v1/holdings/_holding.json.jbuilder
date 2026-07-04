# frozen_string_literal: true

json.id holding.id
json.date holding.date
json.qty holding.qty
json.price Money.new(holding.price, holding.currency).format
json.amount holding.amount_money.format
json.currency holding.currency
json.cost_basis holding.cost_basis&.to_s("F")
json.cost_basis_source holding.cost_basis_source
json.cost_basis_locked holding.cost_basis_locked?
json.security_locked holding.security_locked?
json.can_delete holding.account.can_delete_holdings?
json.can_sync_prices !holding.security.offline?

json.account do
  json.id holding.account.id
  json.name holding.account.name
  json.account_type holding.account.accountable_type.underscore
end

json.security do
  json.id holding.security.id
  json.ticker holding.security.ticker
  json.name holding.security.name
  json.exchange_operating_mic holding.security.exchange_operating_mic
  json.offline holding.security.offline?
end

if holding.provider_security.present?
  json.provider_security do
    json.id holding.provider_security.id
    json.ticker holding.provider_security.ticker
    json.name holding.provider_security.name
    json.exchange_operating_mic holding.provider_security.exchange_operating_mic
  end
else
  json.provider_security nil
end

avg = holding.avg_cost
json.avg_cost avg ? avg.format : nil

json.created_at holding.created_at.iso8601
json.updated_at holding.updated_at.iso8601
