# frozen_string_literal: true

class Api::V1::CurrenciesController < Api::V1::BaseController
  before_action :ensure_read_scope

  def index
    family = current_resource_owner.family
    enabled_codes = family.enabled_currency_codes
    currencies = currencies_for(family)

    render_json({
      currencies: currencies.map { |currency| currency_payload(currency, family: family, enabled_codes: enabled_codes) },
      meta: {
        enabled_only: truthy_param?(params[:enabled_only]),
        primary_currency: family.primary_currency_code,
        enabled_currencies: enabled_codes
      }
    })
  end

  def show
    family = current_resource_owner.family
    enabled_codes = family.enabled_currency_codes
    currency = Money::Currency.new(params[:id])

    render_json(currency_payload(currency, family: family, enabled_codes: enabled_codes))
  rescue Money::Currency::UnknownCurrencyError, ArgumentError
    render_json({ error: "not_found", message: "Currency not found" }, status: :not_found)
  end

  private

    def currencies_for(family)
      currencies = if truthy_param?(params[:enabled_only])
        family.enabled_currency_objects(extra: extra_currency_codes)
      else
        Money::Currency.as_options
      end

      filter_currencies(currencies)
    end

    def filter_currencies(currencies)
      query = params[:q].to_s.strip.downcase
      return currencies if query.blank?

      currencies.select do |currency|
        currency.iso_code.downcase.include?(query) || currency.name.downcase.include?(query)
      end
    end

    def extra_currency_codes
      Array(params[:extra]).flat_map { |value| value.to_s.split(",") }
    end

    def currency_payload(currency, family:, enabled_codes:)
      {
        iso_code: currency.iso_code,
        name: currency.name,
        symbol: currency.symbol,
        priority: currency.priority,
        iso_numeric: currency.iso_numeric,
        html_code: currency.html_code,
        minor_unit: currency.minor_unit,
        minor_unit_conversion: currency.minor_unit_conversion,
        smallest_denomination: currency.smallest_denomination,
        separator: currency.separator,
        delimiter: currency.delimiter,
        default_format: currency.default_format,
        default_precision: currency.default_precision,
        step: currency.step,
        enabled: enabled_codes.include?(currency.iso_code),
        primary: currency.iso_code == family.primary_currency_code
      }
    end

    def truthy_param?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
end
