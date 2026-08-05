# frozen_string_literal: true

module FinancialReplay
  class InvalidMonthError < StandardError; end

  class InsufficientActivityError < StandardError
    def initialize
      super("Financial Replay needs a full month of activity before it can tell a story.")
    end
  end

  class IncompleteMonthError < StandardError
    attr_reader :latest_available_month

    def initialize(latest_available_month)
      @latest_available_month = latest_available_month
      super("Financial Replay is only available for completed months. The latest available month is #{latest_available_month}.")
    end
  end

  class Builder
    # A replay with fewer moves than this reads as empty and shames new users.
    MINIMUM_TRANSACTION_COUNT = 5

    def initialize(user:, month: nil, persona_refiner: PersonaRefiner)
      @user = user
      @family = user.family
      @month_start = parse_month(month)
      @month_end = @month_start.end_of_month.to_date
      @period = Period.custom(start_date: @month_start, end_date: @month_end)
      @previous_period = Period.custom(
        start_date: @month_start.prev_month.beginning_of_month.to_date,
        end_date: @month_start.prev_month.end_of_month.to_date
      )
      @persona_refiner = persona_refiner

      validate_completed_month!
    end

    # Cheap eligibility check: only counts activity, skips the full payload.
    def availability
      count = report_transactions.count + report_trades.count
      {
        month: month_start.strftime("%Y-%m"),
        transaction_count: count,
        available: count >= MINIMUM_TRANSACTION_COUNT
      }
    end

    def call
      raise InsufficientActivityError unless availability[:available]

      payload = {
        currency: family.currency,
        period: period_payload,
        summary: summary_payload,
        activity: activity_payload,
        categories: categories_payload,
        net_worth: net_worth_payload,
        budget: budget_payload,
        goal: goal_payload,
        investments: investments_payload
      }

      payload[:persona] = persona_refiner.new(
        user: user,
        month: month_start,
        metrics: persona_metrics(payload)
      ).call
      apply_category_quips(payload)
      payload
    end

    private
      attr_reader :user, :family, :month_start, :month_end, :period, :previous_period, :persona_refiner

      def parse_month(value)
        return Date.current.prev_month.beginning_of_month.to_date if value.blank?
        raise InvalidMonthError, "month must use YYYY-MM format" unless value.to_s.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)

        Date.strptime(value.to_s, "%Y-%m").beginning_of_month.to_date
      rescue Date::Error, ArgumentError
        raise InvalidMonthError, "month must use YYYY-MM format"
      end

      def validate_completed_month!
        latest = Date.current.prev_month.beginning_of_month.to_date
        return if month_start == latest

        # The replay is a limited-time monthly drop: only the most recent
        # completed month is ever served, so clients can't browse history.
        if month_start < latest
          raise InvalidMonthError, "Financial Replay is only available for the most recent completed month."
        end

        raise IncompleteMonthError, latest.strftime("%Y-%m")
      end

      def period_payload
        {
          month: month_start.strftime("%Y-%m"),
          label: month_start.strftime("%B"),
          year: month_start.year,
          start_date: month_start.iso8601,
          end_date: month_end.iso8601,
          complete: true
        }
      end

      def summary_payload
        @summary_payload ||= begin
          current_income = ensure_money(current_income_totals.total)
          current_expenses = ensure_money(current_expense_totals.total)
          previous_income = ensure_money(previous_income_totals.total)
          previous_expenses = ensure_money(previous_expense_totals.total)
          net_savings = current_income - current_expenses
          savings_rate = current_income.zero? ? 0.0 : (net_savings / current_income * 100).round(1).to_f

          {
            income: money_payload(current_income),
            expenses: money_payload(current_expenses),
            net_savings: money_payload(net_savings),
            savings_rate: savings_rate,
            income_change_percent: percentage_change(previous_income, current_income),
            expense_change_percent: percentage_change(previous_expenses, current_expenses)
          }
        end
      end

      def activity_payload
        @activity_payload ||= begin
          expenses = expense_transactions
          spending_days = expenses.map { |transaction| transaction.entry.date }.uniq.count
          tracked_days = (month_end - month_start).to_i + 1

          {
            tracked_days: tracked_days,
            transaction_count: report_transactions.count + report_trades.count,
            no_spend_days: [ tracked_days - spending_days, 0 ].max,
            average_daily_spend: money_payload(ensure_money(current_expense_totals.total) / tracked_days),
            busiest_day: busiest_day_payload(expenses),
            biggest_expense: biggest_expense_payload(expenses),
            active_recurring_count: active_recurring_count,
            weekday_totals: weekday_totals_payload(expenses)
          }
        end
      end

      # Absolute spend per weekday, Monday-first, in the family currency.
      def weekday_totals_payload(expenses)
        totals = Array.new(7, BigDecimal("0"))

        expenses.each do |transaction|
          index = (transaction.entry.date.wday + 6) % 7
          totals[index] += converted_abs_amount(transaction.entry.amount, transaction.entry.currency)
        end

        totals.map { |total| total.to_f.round(2) }
      end

      def categories_payload
        @categories_payload ||= begin
          grouped = {}

          expense_transactions.each do |transaction|
            category = transaction.category&.parent || transaction.category || Category.uncategorized
            key = category.id || category.name
            grouped[key] ||= {
              category_name: category.name,
              category_color: category.color,
              category_icon: category.lucide_icon,
              amount: BigDecimal("0"),
              count: 0
            }
            grouped[key][:amount] += converted_abs_amount(transaction.entry.amount, transaction.entry.currency)
            grouped[key][:count] += 1
          end

          grouped.values
            .sort_by { |item| -item[:amount] }
            .first(3)
            .map do |item|
              item.except(:amount).merge(total: money_payload(Money.new(item[:amount], family.currency)))
            end
        end
      end

      def busiest_day_payload(expenses)
        busiest_date, transactions = expenses
          .group_by { |transaction| transaction.entry.date }
          .max_by do |_date, grouped_transactions|
            grouped_transactions.sum { |transaction| converted_abs_amount(transaction.entry.amount, transaction.entry.currency) }
          end
        return nil unless busiest_date

        total = transactions.sum { |transaction| converted_abs_amount(transaction.entry.amount, transaction.entry.currency) }
        {
          date: busiest_date.iso8601,
          label: busiest_date.strftime("%A"),
          transaction_count: transactions.count,
          total_spend: money_payload(Money.new(total, family.currency))
        }
      end

      def biggest_expense_payload(expenses)
        transaction = expenses.max_by { |candidate| converted_abs_amount(candidate.entry.amount, candidate.entry.currency) }
        return nil unless transaction

        amount = converted_abs_amount(transaction.entry.amount, transaction.entry.currency)
        {
          name: transaction.entry.name,
          date: transaction.entry.date.iso8601,
          amount: money_payload(Money.new(amount, family.currency)),
          category_name: transaction.category&.name,
          category_icon: transaction.category&.lucide_icon
        }
      end

      def net_worth_payload
        @net_worth_payload ||= begin
          net_series = family.balance_sheet(user: user).net_worth_series(period: period)
          account_scope = BalanceSheet::HistoricalAccountScope.new(family, user: user).relation
          asset_series = balance_series(account_scope.assets, favorable_direction: "up")
          liability_series = balance_series(account_scope.liabilities, favorable_direction: "down")

          {
            current_net_worth: money_payload(series_money(net_series)),
            total_assets: money_payload(series_money(asset_series)),
            total_liabilities: money_payload(series_money(liability_series)),
            change_percent: finite_percent(net_series.trend&.percent)
          }
        end
      rescue StandardError => e
        Rails.logger.warn "FinancialReplay::Builder net worth unavailable: #{e.class}: #{e.message}"
        zero = money_payload(Money.new(0, family.currency))
        { current_net_worth: zero, total_assets: zero, total_liabilities: zero, change_percent: nil }
      end

      def balance_series(scope, favorable_direction:)
        Balance::ChartSeriesBuilder.new(
          account_ids: scope.pluck(:id),
          currency: family.currency,
          period: period,
          favorable_direction: favorable_direction
        ).balance_series
      end

      def series_money(series)
        series.last&.value || Money.new(0, family.currency)
      end

      def budget_payload
        @budget_payload ||= begin
          budget = family.budgets
            .where("start_date <= ? AND end_date >= ?", month_end, month_start)
            .order(start_date: :desc)
            .first

          if budget
            target = budget.allocated_spending
            target = budget.budgeted_spending if target.zero? && budget.budgeted_spending.present?

            if target.present? && !target.zero?
              spent = budget.actual_spending
              progress = spent.to_f / target.to_f
              percent = (progress * 100).round(1)
              {
                progress: progress.round(4),
                progress_text: "#{percent.to_i}% used",
                status: budget_status(progress),
                spent: money_payload(Money.new(spent, family.currency)),
                target: money_payload(Money.new(target, family.currency))
              }
            end
          end
        end
      rescue StandardError => e
        Rails.logger.warn "FinancialReplay::Builder budget unavailable: #{e.class}: #{e.message}"
        nil
      end

      def budget_status(progress)
        return "Comfortably on track" if progress < 0.8
        return "Close to the line" if progress < 1

        "Over plan, still recoverable"
      end

      def goal_payload
        @goal_payload ||= begin
          goal = family.goals
            .where(state: %w[active paused])
            .includes(:open_pledges, goal_accounts: :account, linked_accounts: :account_providers)
            .order(Arel.sql("CASE state WHEN 'active' THEN 0 ELSE 1 END"), :target_date, :created_at)
            .first

          if goal
            goal.pooled_allocations = Goal.pooled_allocations_for(family)
            goal.market_flows = Goal.market_flows_for(family)
            progress = [ [ goal.progress_percent.to_f / 100.0, 0 ].max, 1 ].min

            {
              name: goal.name,
              progress: progress,
              progress_text: "#{goal.progress_percent}% funded",
              current_balance: money_payload(goal.current_balance_money),
              target_amount: money_payload(goal.target_amount_money)
            }
          end
        end
      rescue StandardError => e
        Rails.logger.warn "FinancialReplay::Builder goal unavailable: #{e.class}: #{e.message}"
        nil
      end

      def investments_payload
        @investments_payload ||= begin
          statement = family.investment_statement(user: user)
          accounts = statement.investment_accounts.to_a
          if accounts.empty?
            {
              has_investments: false,
              contributions: money_payload(Money.new(0, family.currency)),
              trades_count: 0
            }
          else
            totals = statement.totals(period: period)
            {
              has_investments: true,
              contributions: money_payload(totals.contributions),
              trades_count: totals.trades_count
            }
          end
        end
      rescue StandardError => e
        Rails.logger.warn "FinancialReplay::Builder investment activity unavailable: #{e.class}: #{e.message}"
        {
          has_investments: false,
          contributions: money_payload(Money.new(0, family.currency)),
          trades_count: 0
        }
      end

      def persona_metrics(payload)
        {
          savings_rate: payload.dig(:summary, :savings_rate),
          net_savings: payload.dig(:summary, :net_savings, :amount),
          income_change_percent: payload.dig(:summary, :income_change_percent),
          expense_change_percent: payload.dig(:summary, :expense_change_percent),
          tracked_days: payload.dig(:activity, :tracked_days),
          no_spend_days: payload.dig(:activity, :no_spend_days),
          active_recurring_count: payload.dig(:activity, :active_recurring_count),
          top_categories: payload[:categories].map do |category|
            {
              name: category[:category_name],
              transactions: category[:count],
              total: category.dig(:total, :formatted)
            }
          end,
          net_worth_change_percent: payload.dig(:net_worth, :change_percent),
          budget_progress: payload.dig(:budget, :progress),
          goal_progress: payload.dig(:goal, :progress),
          has_investments: payload.dig(:investments, :has_investments),
          investment_contributions: payload.dig(:investments, :contributions, :amount),
          investment_trades_count: payload.dig(:investments, :trades_count)
        }
      end

      # The AI may hand back one playful label per top category ("12 good
      # tables"); surface them on the category items so clients can show them
      # instead of the plain transaction counts.
      def apply_category_quips(payload)
        quips = payload[:persona].delete(:category_quips)
        return if quips.blank?

        payload[:categories].each_with_index do |category, index|
          quip = quips[index]
          category[:quip] = quip if quip.present?
        end
      end

      def income_statement
        @income_statement ||= family.income_statement(user: user)
      end

      def current_income_totals
        @current_income_totals ||= income_statement.income_totals(period: period)
      end

      def current_expense_totals
        @current_expense_totals ||= income_statement.expense_totals(period: period)
      end

      def previous_income_totals
        @previous_income_totals ||= income_statement.income_totals(period: previous_period)
      end

      def previous_expense_totals
        @previous_expense_totals ||= income_statement.expense_totals(period: previous_period)
      end

      def report_transactions
        @report_transactions ||= Transaction
          .excluding_pending
          .joins(:entry)
          .joins(entry: :account)
          .where(accounts: { family_id: family.id, status: Account::VISIBLE_STATUSES })
          .merge(Account.included_in_reports)
          .where(entries: {
            entryable_type: "Transaction",
            excluded: false,
            date: period.date_range,
            account_id: user.finance_accounts.select(:id)
          })
          .where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
          .includes(entry: :account, category: :parent)
          .to_a
      end

      def report_trades
        @report_trades ||= Trade
          .joins(:entry)
          .joins(entry: :account)
          .where(accounts: { family_id: family.id, status: Account::VISIBLE_STATUSES })
          .merge(Account.included_in_reports)
          .where(entries: {
            entryable_type: "Trade",
            excluded: false,
            date: period.date_range,
            account_id: user.finance_accounts.select(:id)
          })
          .to_a
      end

      def expense_transactions
        @expense_transactions ||= report_transactions.select { |transaction| transaction.entry.amount.positive? }
      end

      def active_recurring_count
        family.recurring_transactions.accessible_by(user).active.count
      rescue StandardError => e
        Rails.logger.warn "FinancialReplay::Builder recurring count unavailable: #{e.class}: #{e.message}"
        0
      end

      def converted_abs_amount(amount, from_currency)
        Money.new(amount.abs, from_currency).exchange_to(family.currency).amount
      rescue Money::ConversionError
        amount.abs
      end

      def percentage_change(previous_value, current_value)
        return 0.0 if previous_value.zero?

        ((current_value - previous_value) / previous_value * 100).round(1).to_f
      end

      def finite_percent(value)
        value&.finite? ? value.round(1).to_f : nil
      end

      def ensure_money(value)
        value.is_a?(Money) ? value : Money.new(value, family.currency)
      end

      def money_payload(value)
        ensure_money(value).as_json
      end
  end
end
