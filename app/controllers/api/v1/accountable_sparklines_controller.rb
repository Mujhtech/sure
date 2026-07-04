# frozen_string_literal: true

class Api::V1::AccountableSparklinesController < Api::V1::BaseController
  SERIES_INTERVALS = [ "1 day", "1 week", "1 month" ].freeze

  before_action :ensure_read_scope

  def show
    accountable = Accountable.from_type(params[:accountable_type].to_s.classify)
    unless accountable
      render json: { error: "not_found", message: "Account type not found" }, status: :not_found
      return
    end

    period = series_period
    render json: {
      accountable_type: accountable.name.underscore,
      name: accountable.display_name,
      period: period_payload(period),
      series: series_payload(build_series(accountable, period))
    }
  rescue InvalidFilterError => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "AccountableSparklinesController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Account type series could not be loaded"
    }, status: :internal_server_error
  end

  private

    def family
      current_resource_owner.family
    end

    def account_scope(accountable)
      current_resource_owner.finance_accounts.visible.where(accountable_type: accountable.name)
    end

    def account_identity_rows(accountable)
      account_scope(accountable)
        .left_outer_joins(:account_providers)
        .pluck(:id, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id"))
    end

    def build_series(accountable, period)
      rows = account_identity_rows(accountable)
      account_ids = rows.map(&:first).uniq
      return empty_series(period, accountable) if account_ids.empty?

      if requires_normalized_aggregation?(accountable, rows)
        Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(
          account_ids: account_ids,
          currency: family.currency,
          period: period,
          favorable_direction: accountable.favorable_direction,
          interval: series_interval || period.interval
        )
      else
        Balance::ChartSeriesBuilder.new(
          account_ids: account_ids,
          currency: family.currency,
          period: period,
          favorable_direction: accountable.favorable_direction,
          interval: series_interval
        ).balance_series
      end
    end

    def requires_normalized_aggregation?(accountable, rows)
      return false unless %w[Investment Crypto].include?(accountable.name)

      rows.any? do |_account_id, plaid_account_id, simplefin_account_id, account_provider_id|
        plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?
      end
    end

    def empty_series(period, accountable)
      Series.new(
        start_date: period.start_date,
        end_date: period.end_date,
        interval: series_interval || period.interval,
        values: [],
        favorable_direction: accountable.favorable_direction
      )
    end

    def series_interval
      interval = params[:interval].presence
      return nil if interval.blank?
      return interval if SERIES_INTERVALS.include?(interval)

      raise InvalidFilterError, "interval must be one of: #{SERIES_INTERVALS.join(', ')}"
    end

    def series_period
      if params[:start_date].present? || params[:end_date].present?
        end_date = parse_series_date(:end_date) || Date.current
        start_date = parse_series_date(:start_date) || (end_date - 30.days)
        start_date, end_date = end_date, start_date if start_date > end_date

        Period.custom(start_date: start_date, end_date: end_date)
      elsif params[:period].present?
        Period.from_key(params[:period].to_s)
      else
        Period.last_30_days
      end
    rescue Period::InvalidKeyError
      raise InvalidFilterError, "period must be one of: #{Period::PERIODS.keys.join(', ')}"
    end

    def parse_series_date(key)
      value = params[key]
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "#{key} must be an ISO 8601 date"
    end

    def period_payload(period)
      {
        start_date: period.start_date.iso8601,
        end_date: period.end_date.iso8601,
        interval: period.interval
      }
    end

    def series_payload(series)
      {
        start_date: series.start_date.iso8601,
        end_date: series.end_date.iso8601,
        interval: series.interval,
        trend: trend_payload(series.trend),
        values: series.values.map do |value|
          {
            date: value.date.iso8601,
            date_formatted: value.date_formatted,
            value: money_payload(value.value),
            trend: trend_payload(value.trend)
          }
        end
      }
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

    def money_payload(value)
      money = value.is_a?(Money) ? value : Money.new(value, family.currency)
      money.as_json
    end
end
