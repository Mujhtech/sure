# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

json.campaign do
  json.id SavingsChallenge::Campaign::KEY
  json.name SavingsChallenge::Campaign::NAME
  json.short_description "Build a stronger savings habit in 30 days."
  json.start_date SavingsChallenge::Campaign.starts_on
  json.end_date SavingsChallenge::Campaign.ends_on
  json.duration_days SavingsChallenge::Campaign::DURATION_DAYS
  json.phase SavingsChallenge::Campaign.phase
  json.day_number SavingsChallenge::Campaign.day_number
  json.days_remaining SavingsChallenge::Campaign.days_remaining
end

if @enrollment
  json.enrollment do
    json.id @enrollment.id
    json.goal_id @enrollment.goal_id
    json.joined_at @enrollment.joined_at.iso8601
    json.currency @enrollment.currency
    json.target_amount @enrollment.target_amount_money.format
    json.target_amount_cents money_to_minor_units.call(@enrollment.target_amount_money)
    json.starting_balance @enrollment.starting_balance_money.format
    json.starting_balance_cents money_to_minor_units.call(@enrollment.starting_balance_money)
    json.saved_amount @enrollment.current_saved_amount_money.format
    json.saved_amount_cents money_to_minor_units.call(@enrollment.current_saved_amount_money)
    json.progress_percent @enrollment.progress_percent
    json.completed @enrollment.completed?
  end
else
  json.enrollment nil
end
