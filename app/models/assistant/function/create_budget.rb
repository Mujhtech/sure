# frozen_string_literal: true

class Assistant::Function::CreateBudget < Assistant::Function
  class << self
    def name
      "create_budget"
    end

    def description
      <<~INSTRUCTIONS
        Creates (or initializes) the user's budget for a given month and sets its overall targets.

        Budgets are monthly: pass any date within the month (defaults to the current month).
        budgeted_spending is the total planned spending for the month; expected_income is the
        anticipated income. Both are in the family's currency and optional — omitting them
        bootstraps an empty budget the user can fill in.

        If a budget for that month already exists, its targets are updated instead (existing
        per-category allocations are kept). Use get_budget first when the user asks about
        current targets. Confirm the month and amounts with the user before calling this.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        month: {
          type: "string",
          description: "Any date in the target month (YYYY-MM-DD). Defaults to today (the current month)."
        },
        budgeted_spending: {
          type: "number",
          description: "Total planned spending for the month (positive, family currency)",
          exclusiveMinimum: 0
        },
        expected_income: {
          type: "number",
          description: "Expected income for the month (positive, family currency)",
          exclusiveMinimum: 0
        }
      }
    )
  end

  def call(params = {})
    date = params["month"].present? ? parse_date(params["month"]) : Date.current
    return error("invalid_month", "month must be a valid YYYY-MM-DD date.") unless date

    updates = {}
    [ "budgeted_spending", "expected_income" ].each do |field|
      next if params[field].nil?

      value = params[field].to_f
      return error("invalid_#{field}", "#{field} must be a positive number.") unless value.positive?
      updates[field.to_sym] = value
    end

    budget = Budget.find_or_bootstrap(family, start_date: date, user: user)
    return error("invalid_month", "That month is outside the allowed budget range (roughly two years back through next month).") unless budget

    already_existed = budget.budgeted_spending.present?
    budget.update!(updates) if updates.present?

    {
      success: true,
      budget: serialize(budget),
      message: already_existed ?
        "Budget '#{budget.name}' updated." :
        "Budget '#{budget.name}' created."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def serialize(budget)
      {
        id: budget.id,
        budget_id: budget.id,
        name: budget.name,
        period: "#{budget.start_date} – #{budget.end_date}",
        start_date: budget.start_date,
        end_date: budget.end_date,
        currency: budget.currency,
        budgeted_spending: budget.budgeted_spending,
        budgeted_spending_formatted: budget.budgeted_spending_money&.format,
        expected_income: budget.expected_income,
        expected_income_formatted: budget.expected_income_money&.format
      }
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
