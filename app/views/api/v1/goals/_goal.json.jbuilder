# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

monthly_target_money = goal.monthly_target_amount ? Money.new(goal.monthly_target_amount, goal.currency) : nil

json.id goal.id
json.name goal.name
json.currency goal.currency
json.target_date goal.target_date
json.color goal.color
json.icon goal.icon
json.notes goal.notes
json.state goal.state
json.status goal.status.to_s
json.display_status goal.display_status.to_s
json.progress_basis goal.progress_basis
json.progress_percent goal.progress_percent
json.months_remaining goal.months_remaining
json.months_of_runway goal.months_of_runway

json.target_amount goal.target_amount_money.format
json.target_amount_cents money_to_minor_units.call(goal.target_amount_money)
json.current_balance goal.current_balance_money.format
json.current_balance_cents money_to_minor_units.call(goal.current_balance_money)
json.market_value goal.market_value_money.format
json.market_value_cents money_to_minor_units.call(goal.market_value_money)
json.remaining_amount goal.remaining_amount_money.format
json.remaining_amount_cents money_to_minor_units.call(goal.remaining_amount_money)
json.pace goal.pace_money.format
json.pace_cents money_to_minor_units.call(goal.pace_money)
json.monthly_target_amount monthly_target_money&.format
json.monthly_target_amount_cents money_to_minor_units.call(monthly_target_money)

json.available_events do
  json.pause goal.may_pause?
  json.resume goal.may_resume?
  json.complete goal.may_complete?
  json.archive goal.may_archive?
  json.unarchive goal.may_unarchive?
  json.reopen goal.may_reopen?
end

json.linked_accounts goal.goal_accounts.sort_by { |goal_account| goal_account.account.name.downcase } do |goal_account|
  account = goal_account.account
  allocated_money = goal_account.allocated_amount ? Money.new(goal_account.allocated_amount, goal.currency) : nil
  backing_money = goal.account_backing(account)

  json.id account.id
  json.name account.name
  json.account_type account.accountable_type&.underscore
  json.subtype account.subtype
  json.currency account.currency
  json.balance account.balance_money.format
  json.balance_cents money_to_minor_units.call(account.balance_money)
  json.whole_account goal_account.whole_account?
  json.allocated_amount allocated_money&.format
  json.allocated_amount_cents money_to_minor_units.call(allocated_money)
  json.current_contribution backing_money.format
  json.current_contribution_cents money_to_minor_units.call(backing_money)
end

json.open_pledges goal.open_pledges.reverse_chronological do |pledge|
  json.partial! "api/v1/goal_pledges/pledge", pledge: pledge
end

json.created_at goal.created_at.iso8601
json.updated_at goal.updated_at.iso8601
