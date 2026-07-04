# frozen_string_literal: true

class Api::V1::ExchangeRatesController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    unless params[:from].present? && params[:to].present?
      render_json({ error: "bad_request", message: "from and to currencies are required" }, status: :bad_request)
      return
    end

    from_currency = normalize_currency_param(params[:from])
    to_currency = normalize_currency_param(params[:to])
    date = exchange_rate_date

    if from_currency == to_currency
      render_json(exchange_rate_payload(from_currency: from_currency, to_currency: to_currency, date: date, rate: 1.0, same_currency: true))
      return
    end

    rate_obj = ExchangeRate.find_or_fetch_rate(from: from_currency, to: to_currency, date: date)

    unless rate_obj
      render_json({ error: "not_found", message: "Exchange rate not found" }, status: :not_found)
      return
    end

    rate_value = rate_obj.is_a?(Numeric) ? rate_obj : rate_obj.rate

    render_json(exchange_rate_payload(from_currency: from_currency, to_currency: to_currency, date: date, rate: rate_value.to_f, same_currency: false))
  rescue Money::Currency::UnknownCurrencyError
    render_json({ error: "bad_request", message: "Invalid currency code" }, status: :bad_request)
  rescue ArgumentError
    render_json({ error: "bad_request", message: "date must be an ISO 8601 date" }, status: :bad_request)
  rescue StandardError
    render_json({ error: "exchange_rate_unavailable", message: "Failed to fetch exchange rate" }, status: :bad_request)
  end

  private

    def normalize_currency_param(value)
      Money::Currency.new(value).iso_code
    end

    def exchange_rate_date
      params[:date].present? ? Date.iso8601(params[:date].to_s) : Date.current
    end

    def exchange_rate_payload(from_currency:, to_currency:, date:, rate:, same_currency:)
      {
        from_currency: from_currency,
        to_currency: to_currency,
        date: date.iso8601,
        rate: rate,
        same_currency: same_currency
      }
    end
end
