# frozen_string_literal: true

json.id insight.id
json.insight_type insight.insight_type
json.priority insight.priority
json.status insight.status
json.title insight.title
json.body insight.body
json.currency insight.currency
json.period_start insight.period_start
json.period_end insight.period_end
json.generated_at insight.generated_at.iso8601
json.unread unread
json.meta_line insight_meta_line(insight)
json.icon insight_icon_key(insight)
json.sentiment insight_sentiment(insight)

if (figure = insight_key_figure(insight))
  json.key_figure do
    json.value figure.first
    json.caption figure.last
  end
else
  json.key_figure nil
end

if (action = insight_action(insight))
  json.action do
    json.label action[:text]

    case insight.insight_type
    when "spending_anomaly", "savings_rate_change"
      json.route "transactions"
      json.resource_id nil
    when "idle_cash"
      json.route "account"
      json.resource_id insight.metadata&.dig("account_id")
    when "subscription_audit", "cash_flow_warning"
      json.route "recurring_transactions"
      json.resource_id nil
    when "net_worth_milestone"
      json.route "reports"
      json.resource_id nil
    when "budget_at_risk", "budget_on_track"
      budget = insight.family.budgets.find_by(start_date: insight.period_start)
      json.route budget ? "budget" : "budgets"
      json.resource_id budget&.id
    end
  end
else
  json.action nil
end
