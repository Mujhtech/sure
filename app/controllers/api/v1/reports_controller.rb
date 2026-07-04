# frozen_string_literal: true

class Api::V1::ReportsController < Api::V1::BaseController
  PERIOD_TYPES = %w[monthly quarterly ytd last_6_months custom].freeze
  SORT_COLUMNS = %w[amount count].freeze
  SORT_DIRECTIONS = %w[asc desc].freeze

  before_action :ensure_read_scope

  def show
    setup_period!

    income_statement = family.income_statement(user: current_resource_owner)
    current_income_totals = income_statement.income_totals(period: @period)
    current_expense_totals = income_statement.expense_totals(period: @period)
    previous_income_totals = income_statement.income_totals(period: @previous_period)
    previous_expense_totals = income_statement.expense_totals(period: @previous_period)

    render_json({
      currency: family.currency,
      period: period_payload,
      summary: summary_payload(
        current_income_totals,
        current_expense_totals,
        previous_income_totals,
        previous_expense_totals
      ),
      trends: trends_payload(income_statement),
      net_worth: net_worth_payload,
      transactions_breakdown: transactions_breakdown_payload,
      investments: investments_payload
    })
  rescue InvalidFilterError => e
    render_json({
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error "ReportsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render_json({
      error: "internal_server_error",
      message: "Report data could not be loaded"
    }, status: :internal_server_error)
  end

  def export_transactions
    setup_period!

    export_data = monthly_transaction_breakdown_for_export
    csv_data = transactions_breakdown_csv(export_data)

    send_data csv_data,
              filename: "transactions_breakdown_#{@period.start_date.strftime('%Y%m%d')}_to_#{@period.end_date.strftime('%Y%m%d')}.csv",
              type: "text/csv; charset=utf-8",
              disposition: "attachment"
  rescue InvalidFilterError => e
    render_json({
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error "ReportsController#export_transactions error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render_json({
      error: "internal_server_error",
      message: "Report export could not be generated"
    }, status: :internal_server_error)
  end

  private

    def family
      current_resource_owner.family
    end

    def setup_period!
      @period_type = params[:period_type].presence || "monthly"
      unless PERIOD_TYPES.include?(@period_type)
        raise InvalidFilterError, "period_type must be one of: #{PERIOD_TYPES.join(', ')}"
      end

      @start_date = parse_report_date_param(:start_date) || default_start_date
      @end_date = parse_report_date_param(:end_date) || default_end_date
      @start_date, @end_date = @end_date, @start_date if @start_date > @end_date

      @period = Period.custom(start_date: @start_date, end_date: @end_date)
      @previous_period = previous_period_for(@period)
    end

    def parse_report_date_param(key)
      value = params[key]
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "#{key} must be an ISO 8601 date"
    end

    def default_start_date
      case @period_type
      when "monthly"
        Date.current.beginning_of_month.to_date
      when "quarterly"
        Date.current.beginning_of_quarter.to_date
      when "ytd"
        Date.current.beginning_of_year.to_date
      when "last_6_months"
        (Date.current.end_of_month + 1.day - 6.months).beginning_of_month.to_date
      else
        1.month.ago.to_date
      end
    end

    def default_end_date
      case @period_type
      when "monthly", "last_6_months"
        Date.current.end_of_month.to_date
      when "quarterly"
        Date.current.end_of_quarter.to_date
      else
        Date.current
      end
    end

    def previous_period_for(period)
      duration = (period.end_date - period.start_date).to_i
      previous_end = period.start_date - 1.day

      Period.custom(start_date: previous_end - duration.days, end_date: previous_end)
    end

    def period_payload
      {
        type: @period_type,
        start_date: @period.start_date.iso8601,
        end_date: @period.end_date.iso8601,
        previous_start_date: @previous_period.start_date.iso8601,
        previous_end_date: @previous_period.end_date.iso8601
      }
    end

    def summary_payload(current_income_totals, current_expense_totals, previous_income_totals, previous_expense_totals)
      current_income = ensure_money(current_income_totals.total)
      current_expenses = ensure_money(current_expense_totals.total)
      previous_income = ensure_money(previous_income_totals.total)
      previous_expenses = ensure_money(previous_expense_totals.total)

      {
        current_income: money_payload(current_income),
        income_change_percent: percentage_change(previous_income, current_income),
        current_expenses: money_payload(current_expenses),
        expense_change_percent: percentage_change(previous_expenses, current_expenses),
        net_savings: money_payload(current_income - current_expenses),
        budget_percent: budget_performance_percent
      }
    end

    def trends_payload(income_statement)
      trends = []
      current_month = @period.start_date.beginning_of_month
      end_of_period = @period.end_date.end_of_month

      while current_month <= end_of_period
        month_start = current_month.to_date
        month_end = [ current_month.end_of_month.to_date, @period.end_date ].min
        month_period = Period.custom(start_date: month_start, end_date: month_end)
        income = ensure_money(income_statement.income_totals(period: month_period).total)
        expenses = ensure_money(income_statement.expense_totals(period: month_period).total)

        trends << {
          month: month_start.strftime("%b %Y"),
          start_date: month_start.iso8601,
          end_date: month_end.iso8601,
          current_month: month_start.month == Date.current.month && month_start.year == Date.current.year,
          income: money_payload(income),
          expenses: money_payload(expenses),
          net: money_payload(income - expenses)
        }

        current_month = current_month.next_month
      end

      trends
    end

    def net_worth_payload
      balance_sheet = family.balance_sheet(user: current_resource_owner)
      currency = family.currency
      trend = balance_sheet.net_worth_series(period: @period)&.trend

      {
        current_net_worth: money_payload(Money.new(balance_sheet.net_worth, currency)),
        total_assets: money_payload(Money.new(balance_sheet.assets.total, currency)),
        total_liabilities: money_payload(Money.new(balance_sheet.liabilities.total, currency)),
        trend: trend_payload(trend),
        asset_groups: account_group_payloads(balance_sheet.assets.account_groups),
        liability_groups: account_group_payloads(balance_sheet.liabilities.account_groups)
      }
    end

    def account_group_payloads(groups)
      groups.map do |group|
        total = Money.new(group.total, family.currency)
        next if total.zero?

        { name: group.name, total: money_payload(total) }
      end.compact
    end

    def transactions_breakdown_payload
      grouped_data = grouped_transaction_breakdown
      sort_logic = breakdown_sort_logic

      grouped_data.values.map do |parent_data|
        subcategories = parent_data[:subcategories].values.sort_by(&sort_logic).map do |subcategory|
          breakdown_category_payload(subcategory)
        end

        breakdown_category_payload(parent_data).merge(subcategories: subcategories)
      end.sort_by { |item| sort_value_for_payload(item) }
    end

    def grouped_transaction_breakdown
      grouped_data = {}
      family_currency = family.currency
      init_category_group = lambda do |id, name, color, icon, type|
        {
          category_id: id,
          category_name: name,
          category_color: color,
          category_icon: icon,
          type: type,
          total: BigDecimal("0"),
          count: 0,
          subcategories: {}
        }
      end

      init_subcategory = lambda do |category|
        {
          category_id: category.id,
          category_name: category.name,
          category_color: category.color,
          category_icon: category.lucide_icon,
          total: BigDecimal("0"),
          count: 0
        }
      end

      process_entry = lambda do |category, entry, trade|
        type = entry.amount > 0 ? "expense" : "income"
        converted_amount = converted_abs_amount(entry.amount, entry.currency, family_currency)
        parent_key = nil

        if category.nil?
          fallback = trade ? Category.other_investments : Category.uncategorized
          fallback_id = trade ? "other_investments" : "uncategorized"
          parent_key = [ fallback_id, type ]
          grouped_data[parent_key] ||= init_category_group.call(fallback_id, fallback.name, fallback.color, fallback.lucide_icon, type)
        elsif category.parent_id.present?
          parent = category.parent
          parent_key = [ parent.id, type ]
          grouped_data[parent_key] ||= init_category_group.call(parent.id, parent.name, parent.color || Category::UNCATEGORIZED_COLOR, parent.lucide_icon, type)
          grouped_data[parent_key][:subcategories][category.id] ||= init_subcategory.call(category)
          grouped_data[parent_key][:subcategories][category.id][:count] += 1
          grouped_data[parent_key][:subcategories][category.id][:total] += converted_amount
        else
          parent_key = [ category.id, type ]
          grouped_data[parent_key] ||= init_category_group.call(category.id, category.name, category.color || Category::UNCATEGORIZED_COLOR, category.lucide_icon, type)
        end

        grouped_data[parent_key][:count] += 1
        grouped_data[parent_key][:total] += converted_amount
      end

      report_transactions.each do |transaction|
        process_entry.call(transaction.category, transaction.entry, false)
      end

      report_trades.each do |trade|
        process_entry.call(trade.category, trade.entry, true)
      end

      grouped_data
    end

    def report_transactions
      scope = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: family.id, status: Account::VISIBLE_STATUSES })
        .merge(Account.included_in_reports)
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
        .includes(entry: :account, category: :parent)

      apply_transaction_filters(scope)
    end

    def report_trades
      scope = Trade
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: family.id, status: Account::VISIBLE_STATUSES })
        .merge(Account.included_in_reports)
        .where(entries: { entryable_type: "Trade", excluded: false, date: @period.date_range })
        .includes(entry: :account, category: :parent)

      apply_entry_filters(scope)
    end

    def monthly_transaction_breakdown_for_export
      months = []
      current_month = @period.start_date.beginning_of_month
      end_of_period = @period.end_date.end_of_month

      while current_month <= end_of_period
        months << current_month.to_date
        current_month = current_month.next_month
      end

      breakdown = {}

      report_transactions.each do |transaction|
        entry = transaction.entry
        type = entry.amount.positive? ? "expense" : "income"
        category_name = transaction.category&.name || Category.uncategorized.name
        month_key = entry.date.beginning_of_month.to_date
        converted_amount = converted_abs_amount(entry.amount, entry.currency, family.currency)
        key = [ category_name, type ]

        breakdown[key] ||= { category: category_name, type: type, months: {}, total: BigDecimal("0") }
        breakdown[key][:months][month_key] ||= BigDecimal("0")
        breakdown[key][:months][month_key] += converted_amount
        breakdown[key][:total] += converted_amount
      end

      rows = breakdown.values
      {
        months: months,
        income: rows.select { |row| row[:type] == "income" }.sort_by { |row| -row[:total] },
        expenses: rows.select { |row| row[:type] == "expense" }.sort_by { |row| -row[:total] }
      }
    end

    def transactions_breakdown_csv(export_data)
      require "csv"

      CSV.generate do |csv|
        month_headers = export_data[:months].map { |month| month.strftime("%b %Y") }
        csv << [ "Category", *month_headers, "Total" ]

        append_export_section(csv, "INCOME", export_data[:income], export_data[:months])
        csv << [] if export_data[:income].any? && export_data[:expenses].any?
        append_export_section(csv, "EXPENSES", export_data[:expenses], export_data[:months])
      end
    end

    def append_export_section(csv, title, rows, months)
      return if rows.empty?

      csv << [ title, *Array.new(months.length + 1, "") ]

      rows.each do |row_data|
        month_amounts = months.map { |month| Money.new(row_data[:months][month] || 0, family.currency).format }

        csv << [
          row_data[:category],
          *month_amounts,
          Money.new(row_data[:total], family.currency).format
        ]
      end

      total_month_amounts = months.map do |month|
        month_total = rows.sum { |row_data| row_data[:months][month] || 0 }
        Money.new(month_total, family.currency).format
      end

      csv << [
        "TOTAL #{title}",
        *total_month_amounts,
        Money.new(rows.sum { |row_data| row_data[:total] }, family.currency).format
      ]
    end

    def apply_transaction_filters(scope)
      scope = apply_entry_filters(scope)

      if params[:filter_tag_id].present?
        validate_uuid_param!(:filter_tag_id)
        scope = scope.joins(:taggings).where(taggings: { tag_id: params[:filter_tag_id] })
      end

      scope
    end

    def apply_entry_filters(scope)
      finance_account_ids = current_resource_owner.finance_accounts.select(:id)
      scope = scope.where(entries: { account_id: finance_account_ids })

      if params[:filter_category_id].present?
        validate_uuid_param!(:filter_category_id)
        category_id = params[:filter_category_id]
        subcategory_ids = family.categories.where(parent_id: category_id).pluck(:id)
        scope = scope.where(category_id: [ category_id ] + subcategory_ids)
      end

      if params[:filter_account_id].present?
        validate_uuid_param!(:filter_account_id)
        scope = scope.where(entries: { account_id: params[:filter_account_id] })
      end

      if params[:filter_amount_min].present?
        scope = scope.where("ABS(entries.amount) >= ?", decimal_filter!(:filter_amount_min))
      end

      if params[:filter_amount_max].present?
        scope = scope.where("ABS(entries.amount) <= ?", decimal_filter!(:filter_amount_max))
      end

      if params[:filter_date_start].present?
        filter_start = parse_report_date_param(:filter_date_start)
        scope = scope.where("entries.date >= ?", filter_start) if filter_start >= @period.start_date
      end

      if params[:filter_date_end].present?
        filter_end = parse_report_date_param(:filter_date_end)
        scope = scope.where("entries.date <= ?", filter_end) if filter_end <= @period.end_date
      end

      scope
    end

    def validate_uuid_param!(key)
      return if valid_uuid?(params[key])

      raise InvalidFilterError, "#{key} must be a valid UUID"
    end

    def decimal_filter!(key)
      BigDecimal(params[key].to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "#{key} must be a number"
    end

    def converted_abs_amount(amount, from_currency, to_currency)
      Money.new(amount.abs, from_currency).exchange_to(to_currency).amount
    rescue Money::ConversionError
      amount.abs
    end

    def breakdown_sort_logic
      sort_by = SORT_COLUMNS.include?(params[:sort_by]) ? params[:sort_by] : "amount"
      sort_direction = SORT_DIRECTIONS.include?(params[:sort_direction]) ? params[:sort_direction] : "desc"

      lambda do |item|
        value = sort_by == "count" ? item[:count] : item[:total]
        sort_direction == "asc" ? value : -value
      end
    end

    def sort_value_for_payload(item)
      sort_by = SORT_COLUMNS.include?(params[:sort_by]) ? params[:sort_by] : "amount"
      sort_direction = SORT_DIRECTIONS.include?(params[:sort_direction]) ? params[:sort_direction] : "desc"
      value = sort_by == "count" ? item[:count] : BigDecimal(item.dig(:total, :amount).to_s)

      sort_direction == "asc" ? value : -value
    end

    def breakdown_category_payload(item)
      {
        category_id: item[:category_id].to_s,
        category_name: item[:category_name],
        category_color: item[:category_color],
        category_icon: item[:category_icon],
        type: item[:type],
        total: money_payload(Money.new(item[:total], family.currency)),
        count: item[:count]
      }
    end

    def investments_payload
      investment_statement = family.investment_statement(user: current_resource_owner)
      investment_accounts = investment_statement.investment_accounts.to_a

      return { has_investments: false } if investment_accounts.empty?

      period_totals = investment_statement.totals(period: @period)
      investment_flows = InvestmentFlowStatement.new(family, user: current_resource_owner).period_totals(period: @period)

      {
        has_investments: true,
        portfolio_value: money_payload(investment_statement.portfolio_value_money),
        unrealized_trend: trend_payload(investment_statement.unrealized_gains_trend),
        period_return_trend: trend_payload(investment_statement.period_return_trend(period: @period)),
        period_totals: {
          contributions: money_payload(period_totals.contributions),
          withdrawals: money_payload(period_totals.withdrawals),
          dividends: money_payload(period_totals.dividends),
          interest: money_payload(period_totals.interest),
          net_flow: money_payload(period_totals.net_flow),
          trades_count: period_totals.trades_count
        },
        flows: {
          contributions: money_payload(investment_flows.contributions),
          withdrawals: money_payload(investment_flows.withdrawals),
          net_flow: money_payload(investment_flows.net_flow)
        },
        top_holdings: investment_statement.top_holdings(limit: 5).map { |holding| holding_payload(holding) },
        accounts: investment_accounts.map { |account| investment_account_payload(account) },
        gains_by_tax_treatment: gains_by_tax_treatment_payload(investment_statement)
      }
    end

    def gains_by_tax_treatment_payload(investment_statement)
      build_gains_by_tax_treatment(investment_statement).transform_values do |data|
        {
          holdings_count: data[:holdings].size,
          sell_trades_count: data[:sell_trades].size,
          unrealized_gain: money_payload(data[:unrealized_gain]),
          realized_gain: money_payload(data[:realized_gain]),
          total_gain: money_payload(data[:total_gain])
        }
      end
    end

    def build_gains_by_tax_treatment(investment_statement)
      currency = family.currency
      current_holdings = investment_statement.current_holdings.includes(account: :accountable).to_a
      holdings_by_treatment = current_holdings.group_by { |holding| holding.account.tax_treatment || :taxable }

      sell_trades = family.trades
        .joins(entry: :account)
        .where(entries: { date: @period.date_range, account_id: current_resource_owner.finance_accounts.select(:id) })
        .merge(Account.included_in_reports)
        .where("trades.qty < 0")
        .includes(:security, entry: { account: :accountable })
        .to_a

      account_ids = sell_trades.map { |trade| trade.entry.account_id }.uniq
      holdings_by_account = Holding
        .where(account_id: account_ids)
        .where("date <= ?", @period.date_range.end)
        .order(date: :desc)
        .group_by(&:account_id)

      sell_trades.each do |trade|
        trade.instance_variable_set(:@preloaded_holdings, holdings_by_account[trade.entry.account_id] || [])
      end

      trades_by_treatment = sell_trades.group_by { |trade| trade.entry.account.tax_treatment || :taxable }
      current_rates = ExchangeRate.rates_for(
        current_holdings.map(&:currency).compact.uniq.reject { |currency_code| currency_code == currency },
        to: currency,
        date: Date.current
      )
      trade_currencies = sell_trades.map(&:currency).compact.uniq.reject { |currency_code| currency_code == currency }
      rates_by_trade_date = sell_trades.map { |trade| trade.entry.date }.uniq.each_with_object({}) do |date, memo|
        memo[date] = ExchangeRate.rates_for(trade_currencies, to: currency, date: date)
      end

      %i[taxable tax_deferred tax_exempt tax_advantaged].each_with_object({}) do |treatment, hash|
        holdings = holdings_by_treatment[treatment] || []
        trades = trades_by_treatment[treatment] || []
        next if holdings.empty? && trades.empty?

        unrealized = holdings.sum do |holding|
          trend = holding.trend
          trend ? convert_numeric_amount(trend.value, holding.currency, current_rates) : 0
        end

        realized = trades.sum do |trade|
          gain = trade.realized_gain_loss
          gain ? convert_numeric_amount(gain.value, trade.currency, rates_by_trade_date[trade.entry.date] || {}) : 0
        end

        hash[treatment] = {
          holdings: holdings,
          sell_trades: trades,
          unrealized_gain: Money.new(unrealized, currency),
          realized_gain: Money.new(realized, currency),
          total_gain: Money.new(unrealized + realized, currency)
        }
      end
    end

    def convert_numeric_amount(value, from_currency, rates)
      numeric = value.is_a?(Money) ? value.amount : value
      from_currency == family.currency ? numeric : numeric * (rates[from_currency] || 1)
    end

    def investment_account_payload(account)
      {
        id: account.id,
        name: account.name,
        account_type: account.accountable_type&.underscore,
        subtype: account.subtype,
        tax_treatment: account.tax_treatment,
        balance: money_payload(account.balance_money),
        cash_balance: money_payload(account.cash_balance_money),
        currency: account.currency
      }
    end

    def holding_payload(holding)
      {
        id: holding.id,
        date: holding.date.iso8601,
        qty: holding.qty.to_s,
        amount: money_payload(holding.amount_money),
        currency: holding.currency,
        weight: holding.weight,
        trend: trend_payload(holding.trend),
        account: {
          id: holding.account.id,
          name: holding.account.name
        },
        security: {
          id: holding.security.id,
          ticker: holding.security.ticker,
          name: holding.security.name,
          exchange_operating_mic: holding.security.exchange_operating_mic
        }
      }
    end

    def budget_performance_percent
      return nil unless @period_type == "monthly"
      return nil unless @period.start_date.beginning_of_month.to_date == Date.current.beginning_of_month.to_date

      budget = Budget.find_or_bootstrap(family, start_date: @period.start_date.beginning_of_month.to_date, user: current_resource_owner)
      return 0 if budget.nil? || budget.allocated_spending.zero?

      (budget.actual_spending / budget.allocated_spending * 100).round(1)
    rescue StandardError
      nil
    end

    def percentage_change(previous_value, current_value)
      return 0 if previous_value.zero?

      ((current_value - previous_value) / previous_value * 100).round(1)
    end

    def ensure_money(value)
      value.is_a?(Money) ? value : Money.new(value, family.currency)
    end

    def money_payload(value, currency = family.currency)
      return nil if value.nil?

      money = value.is_a?(Money) ? value : Money.new(value, currency)
      money.as_json
    end

    def trend_payload(trend)
      return nil unless trend

      percent = trend.percent
      {
        value: money_payload(trend.value),
        percent: percent.finite? ? percent : nil,
        percent_formatted: trend.percent_formatted,
        current: money_payload(trend.current),
        previous: money_payload(trend.previous),
        color: trend.color,
        icon: trend.icon
      }
    end
end
