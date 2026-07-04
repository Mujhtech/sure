# frozen_string_literal: true

balance_money = account.balance_money
cash_balance_money = account.cash_balance_money
accountable = account.accountable
decimal_string = ->(value) { value.nil? ? nil : value.to_d.to_s("F") }
accountable_subtype = accountable&.respond_to?(:subtype) ? accountable.subtype : nil

json.id account.id
json.name account.name
json.balance balance_money.format
json.balance_cents((balance_money.amount * balance_money.currency.minor_unit_conversion).round(0).to_i)
json.cash_balance cash_balance_money.format
json.cash_balance_cents((cash_balance_money.amount * cash_balance_money.currency.minor_unit_conversion).round(0).to_i)
json.currency account.currency
json.classification account.classification
json.account_type account.accountable_type&.underscore
json.subtype accountable_subtype
json.accountable do
  json.id accountable&.id
  json.type account.accountable_type
  json.key account.accountable_type&.underscore
  json.subtype accountable_subtype
  json.tax_treatment(accountable.tax_treatment&.to_s) if accountable&.respond_to?(:tax_treatment)

  case accountable
  when CreditCard
    json.available_credit decimal_string.call(accountable.available_credit)
    json.minimum_payment decimal_string.call(accountable.minimum_payment)
    json.apr decimal_string.call(accountable.apr)
    json.annual_fee decimal_string.call(accountable.annual_fee)
    json.expiration_date accountable.expiration_date&.iso8601
  when Loan
    json.rate_type accountable.rate_type
    json.interest_rate decimal_string.call(accountable.interest_rate)
    json.term_months accountable.term_months
    json.initial_balance decimal_string.call(accountable.initial_balance)
  when Property
    json.year_built accountable.year_built
    json.area_value accountable.area_value
    json.area_unit accountable.area_unit

    address = accountable.address
    if address.present?
      json.address do
        json.id address.id
        json.line1 address.line1
        json.line2 address.line2
        json.county address.county
        json.locality address.locality
        json.region address.region
        json.country address.country
        json.postal_code address.postal_code
      end
    else
      json.address nil
    end
  when Vehicle
    json.make accountable.make
    json.model accountable.model
    json.year accountable.year
    json.mileage_value accountable.mileage_value
    json.mileage_unit accountable.mileage_unit
  end
end
json.status account.status
json.institution_name account.institution_name
json.institution_domain account.institution_domain
json.exclude_from_reports account.exclude_from_reports?
json.default account.id == Current.user&.default_account_id
json.transaction_default_eligible account.eligible_for_transaction_default?
json.syncing account.syncing?
json.linked account.linked?
json.manual account.manual?
json.deletable !account.linked?

if account.owner.present?
  json.owner do
    json.id account.owner.id
    json.email account.owner.email
    json.display_name account.owner.display_name
    json.initials account.owner.initials
  end
else
  json.owner nil
end

current_user = Current.user
current_share = if current_user.present?
  if account.account_shares.loaded?
    account.account_shares.find { |share| share.user_id == current_user.id }
  else
    account.account_shares.find_by(user: current_user)
  end
end

json.sharing do
  json.shared account.shared?
  json.owned_by_current_user current_user.present? && account.owned_by?(current_user)
  json.current_user_permission(current_user.present? ? account.permission_for(current_user) : nil)
  json.include_in_finances current_share&.include_in_finances? || (current_user.present? && account.owned_by?(current_user))
end

json.created_at account.created_at.iso8601
json.updated_at account.updated_at.iso8601
