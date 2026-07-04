# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  ADDRESS_ATTRIBUTES = %i[id line1 line2 county locality region country postal_code _destroy].freeze
  ACCOUNTABLE_ATTRIBUTES = {
    "CreditCard" => %i[id available_credit minimum_payment apr annual_fee expiration_date subtype],
    "Crypto" => %i[id subtype tax_treatment],
    "Depository" => %i[id subtype],
    "Investment" => %i[id subtype],
    "Loan" => %i[id subtype rate_type interest_rate term_months initial_balance],
    "OtherAsset" => %i[id subtype],
    "OtherLiability" => %i[id subtype],
    "Property" => [ :id, :subtype, :year_built, :area_value, :area_unit, { address_attributes: ADDRESS_ATTRIBUTES } ],
    "Vehicle" => %i[id make model year mileage_value mileage_unit]
  }.freeze
  SERIES_VIEWS = %w[balance cash_balance holdings_balance].freeze
  SERIES_INTERVALS = [ "1 day", "1 week", "1 month" ].freeze

  # Ensure proper scope authorization for read vs write access
  before_action :ensure_read_scope, only: %i[index show series]
  before_action :ensure_write_scope, only: %i[create update destroy sync unlink toggle_active toggle_exclude_from_reports set_default remove_default]
  before_action :set_readable_account, only: %i[show series]
  before_action :set_writable_account, only: %i[update destroy sync unlink toggle_active toggle_exclude_from_reports set_default remove_default]

  def index
    @per_page = safe_per_page_param

    @pagy, @accounts = pagy(
      accounts_scope.alphabetically,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "AccountsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def series
    view = series_view
    period = series_period

    render json: {
      account: {
        id: @account.id,
        name: @account.name,
        currency: @account.currency
      },
      view: view,
      period: period_payload(period),
      series: series_payload(@account.balance_series(period: period, view: view, interval: series_interval))
    }
  rescue InvalidFilterError => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "AccountsController#series error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Account series could not be loaded"
    }, status: :internal_server_error
  end

  def create
    attrs = account_create_params.to_h.symbolize_keys
    accountable_type = attrs[:accountable_type]

    unless Accountable::TYPES.include?(accountable_type)
      render_validation_error("accountable_type must be one of: #{Accountable::TYPES.join(', ')}")
      return
    end

    opening_balance_date = parse_opening_balance_date(attrs.delete(:opening_balance_date))

    Account.transaction do
      @account = current_resource_owner.family.accounts.create_and_sync(
        attrs.merge(owner: current_resource_owner),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end

    render :show, status: :created
  rescue Date::Error
    render_validation_error("opening_balance_date must be an ISO 8601 date")
  rescue ActiveRecord::RecordInvalid => e
    render_account_validation_error(e.record)
  end

  def update
    attrs = account_update_params.to_h.symbolize_keys

    if attrs[:balance].present? && attrs[:balance].to_d != @account.balance
      result = @account.set_current_balance(attrs[:balance].to_d)
      unless result.success?
        render_validation_error(result.error_message)
        return
      end
    end

    update_attrs = attrs.except(:balance)
    unless @account.update(update_attrs)
      render_account_validation_error(@account)
      return
    end

    @account.lock_saved_attributes!

    render :show
  end

  def destroy
    if @account.linked?
      render_validation_error("Linked accounts cannot be deleted. Unlink the provider first.")
      return
    end

    @account.destroy_later

    render json: { message: "Account deletion scheduled successfully" }, status: :accepted
  rescue StandardError => e
    Rails.logger.error "AccountsController#destroy error: #{e.message}"
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def unlink
    unless @account.linked?
      render_validation_error("Account is not linked to a provider")
      return
    end

    Account.transaction do
      provider_link_ids = @account.account_providers.pluck(:id)
      Holding.where(account_provider_id: provider_link_ids).update_all(account_provider_id: nil) if provider_link_ids.any?

      simplefin_account_to_destroy = @account.simplefin_account
      @account.account_providers.destroy_all
      @account.update!(plaid_account_id: nil, simplefin_account_id: nil)
      simplefin_account_to_destroy&.destroy!
    end

    @account.reload
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_account_validation_error(e.record)
  rescue StandardError => e
    Rails.logger.error "AccountsController#unlink error: #{e.message}"
    render json: {
      error: "internal_server_error",
      message: "Account could not be unlinked"
    }, status: :internal_server_error
  end

  def sync
    unless @account.syncing?
      if @account.linked?
        @account.account_providers.each do |account_provider|
          item = account_provider.adapter&.item
          item&.sync_later if item && !item.syncing?
        end
      else
        @account.sync_later
      end
    end

    render :show, status: :accepted
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end

    render :show
  end

  def toggle_exclude_from_reports
    @account.update!(exclude_from_reports: !@account.exclude_from_reports?)

    render :show
  end

  def set_default
    unless @account.eligible_for_transaction_default?
      render_validation_error("Only active manual depository and credit card accounts can be transaction defaults")
      return
    end

    current_resource_owner.update!(default_account: @account)

    render :show
  end

  def remove_default
    current_resource_owner.update!(default_account: nil)

    render :show
  end

  private

    def set_readable_account
      unless valid_uuid?(params[:id])
        render json: {
          error: "not_found",
          message: "Account not found"
        }, status: :not_found
        return
      end

      @account = accounts_scope.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
    end

    def set_writable_account
      unless valid_uuid?(params[:id])
        render json: {
          error: "not_found",
          message: "Account not found"
        }, status: :not_found
        return
      end

      @account = writable_accounts_scope.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def accounts_scope
      scope = current_resource_owner.family.accounts
                                    .accessible_by(current_resource_owner)
                                    .includes(:accountable, :owner, :account_shares, account_providers: :provider)
      include_disabled_accounts? ? scope : scope.visible
    end

    def writable_accounts_scope
      current_resource_owner.family.accounts
                            .writable_by(current_resource_owner)
                            .where.not(status: "pending_deletion")
                            .includes(:accountable, :owner, :account_shares, account_providers: :provider)
    end

    def include_disabled_accounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
    end

    def account_create_params
      permitted_account_params(:create)
    end

    def account_update_params
      permitted_account_params(:update)
    end

    def permitted_account_params(action)
      permitted = params.require(:account).permit(
        :name,
        :balance,
        :cash_balance,
        :subtype,
        :currency,
        :accountable_type,
        :opening_balance_date,
        :institution_name,
        :institution_domain,
        :notes,
        :exclude_from_reports,
        accountable_attributes: permitted_accountable_attributes_for_request
      )

      action == :create ? permitted : permitted.except(:accountable_type, :opening_balance_date)
    end

    def permitted_accountable_attributes_for_request
      type = params.dig(:account, :accountable_type).presence || @account&.accountable_type
      ACCOUNTABLE_ATTRIBUTES.fetch(type, %i[id subtype])
    end

    def parse_opening_balance_date(value)
      return Time.zone.today - 2.years if value.blank?

      Date.iso8601(value.to_s)
    end

    def series_view
      view = params[:view].presence || "balance"
      return view.to_sym if SERIES_VIEWS.include?(view)

      raise InvalidFilterError, "view must be one of: #{SERIES_VIEWS.join(', ')}"
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
      money = value.is_a?(Money) ? value : Money.new(value, @account.currency)
      money.as_json
    end

    def render_account_validation_error(account)
      render json: {
        error: "validation_failed",
        message: "Account could not be saved",
        errors: account.errors.full_messages
      }, status: :unprocessable_entity
    end
end
