# frozen_string_literal: true

class Api::V1::HoldingsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :update, :destroy, :unlock_cost_basis, :remap_security, :reset_security, :sync_prices ]
  before_action :set_readable_holding, only: [ :show ]
  before_action :set_writable_holding, only: [ :update, :destroy, :unlock_cost_basis, :remap_security, :reset_security, :sync_prices ]

  def index
    holdings_query = accessible_holdings

    holdings_query = apply_filters(holdings_query)
    holdings_query = holdings_query.includes(:account, :security).chronological

    @pagy, @holdings = pagy(
      holdings_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )
    @per_page = safe_per_page_param

    render :index
  rescue ArgumentError => e
    render_validation_error(e.message, [ e.message ])
  rescue => e
    log_and_render_error("index", e)
  end

  def show
    render :show
  rescue => e
    log_and_render_error("show", e)
  end

  def update
    total_cost_basis = parse_nonnegative_decimal!(holding_update_params[:cost_basis], "cost_basis")
    return if performed?

    unless @holding.qty.positive?
      render_validation_error("cost_basis cannot be set for holdings with zero quantity", [ "quantity must be greater than zero" ])
      return
    end

    # Cost basis is submitted as the total position basis, while holdings store
    # the per-share value.
    @holding.set_manual_cost_basis!(total_cost_basis / @holding.qty)

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error("Holding could not be updated", e.record.errors.full_messages)
  rescue => e
    log_and_render_error("update", e)
  end

  def unlock_cost_basis
    @holding.unlock_cost_basis!

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error("Holding cost basis could not be unlocked", e.record.errors.full_messages)
  rescue => e
    log_and_render_error("unlock_cost_basis", e)
  end

  def destroy
    unless @holding.account.can_delete_holdings?
      render_validation_error("Holding cannot be deleted because it is managed by a connected provider", [ "disconnect the provider or delete from the provider before deleting this holding" ])
      return
    end

    @holding.destroy_holding_and_entries!

    render json: { message: "Holding deleted successfully" }, status: :ok
  rescue => e
    log_and_render_error("destroy", e)
  end

  def remap_security
    security_combobox_id = selected_security_id

    if security_combobox_id.blank?
      render_validation_error("security_id is required", [ "security_id must use SYMBOL|EXCHANGE|PROVIDER format" ])
      return
    end

    parsed = Security.parse_combobox_id(security_combobox_id)
    if parsed[:ticker].blank?
      render_validation_error("Security not found", [ "ticker is required" ])
      return
    end

    original_id = @holding.id
    original_account_id = @holding.account_id
    original_date = @holding.date
    original_currency = @holding.currency

    new_security = Security.find_or_initialize_by(
      ticker: parsed[:ticker],
      exchange_operating_mic: parsed[:exchange_operating_mic]
    )
    new_security.price_provider = parsed[:price_provider] if parsed[:price_provider].present?
    new_security.offline = false
    new_security.failed_fetch_count = 0
    new_security.failed_fetch_at = nil
    new_security.save!

    @holding.remap_security!(new_security)

    account = Account.find(original_account_id)
    materialize_holding_balances(account, new_security.id)
    @holding = remapped_holding(account, original_id, new_security, original_date, original_currency)

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error("Security could not be remapped", e.record.errors.full_messages)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Holding not found after remap" }, status: :not_found
  rescue => e
    log_and_render_error("remap_security", e)
  end

  def sync_prices
    security = @holding.security

    if security.offline?
      render_validation_error("Security is offline and cannot sync prices", [ "security is offline" ])
      return
    end

    prices_updated, provider_error = security.import_provider_prices(
      start_date: 31.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    )
    security.import_provider_details

    if prices_updated.to_i.zero?
      render_validation_error(provider_error.presence || "Provider returned no prices", [ provider_error.presence || "no prices were updated" ])
      return
    end

    materialize_holding_balances(@holding.account, @holding.security_id)
    @holding.reload

    render :show
  rescue => e
    log_and_render_error("sync_prices", e)
  end

  def reset_security
    unless @holding.provider_security.present?
      render_validation_error("Holding has no provider security to reset to", [ "provider_security_id is blank" ])
      return
    end

    @holding.reset_security_to_provider!

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error("Security could not be reset", e.record.errors.full_messages)
  rescue => e
    log_and_render_error("reset_security", e)
  end

  private

<<<<<<< HEAD
    def set_readable_holding
      @holding = find_holding(readable_holdings_scope)
    end

    def set_writable_holding
      @holding = find_holding(writable_holdings_scope)
    end

    def find_holding(scope)
      unless valid_uuid?(params[:id])
        raise ActiveRecord::RecordNotFound
      end

      scope.find(params[:id])
=======
    def set_holding
      @holding = accessible_holdings.find(params[:id])
>>>>>>> main
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Holding not found" }, status: :not_found
    end

    # Holdings restricted to accounts the token owner can access (owned or shared),
    # not the whole family. Mirrors Api::V1::BalancesController and the web
    # HoldingsController, both of which scope through Account.accessible_by.
    def accessible_holdings
      Holding
        .joins(:account)
        .where(accounts: { status: %w[draft active], id: accessible_account_ids })
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def readable_holdings_scope
      current_resource_owner.family.holdings
                            .joins(:account)
                            .merge(Account.accessible_by(current_resource_owner))
                            .where(accounts: { status: %w[draft active] })
    end

    def writable_holdings_scope
      current_resource_owner.family.holdings
                            .joins(:account)
                            .merge(Account.writable_by(current_resource_owner))
                            .where(accounts: { status: %w[draft active] })
    end

    def apply_filters(query)
      if params[:account_id].present?
        query = query.where(account_id: params[:account_id])
      end
      if params[:account_ids].present?
        query = query.where(account_id: Array(params[:account_ids]))
      end
      if params[:date].present?
        query = query.where(date: parse_date!(params[:date], "date"))
      end
      if params[:start_date].present?
        query = query.where("holdings.date >= ?", parse_date!(params[:start_date], "start_date"))
      end
      if params[:end_date].present?
        query = query.where("holdings.date <= ?", parse_date!(params[:end_date], "end_date"))
      end
      if params[:security_id].present?
        query = query.where(security_id: params[:security_id])
      end
      query
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25
      end
    end

    def parse_date!(value, param_name)
      Date.parse(value)
    rescue Date::Error, ArgumentError, TypeError
      raise ArgumentError, "Invalid #{param_name} format"
    end

    def holding_update_params
      params.require(:holding).permit(:cost_basis)
    end

    def selected_security_id
      params[:security_id].presence || params.dig(:holding, :security_id)
    end

    def parse_nonnegative_decimal!(raw, field)
      value_raw = raw.to_s.strip
      if value_raw.blank?
        render_validation_error("#{field} is required", [ "#{field} must be present" ])
        return nil
      end

      value = BigDecimal(value_raw)
      if value.negative?
        render_validation_error("#{field} must be greater than or equal to zero", [ "#{field} must be non-negative" ])
        return nil
      end

      value
    rescue ArgumentError
      render_validation_error("#{field} must be a valid number", [ "#{field} must be numeric" ])
      nil
    end

    def materialize_holding_balances(account, security_id)
      strategy = account.linked? ? :reverse : :forward
      Balance::Materializer.new(account, strategy: strategy, security_ids: [ security_id ]).materialize_balances
    end

    def remapped_holding(account, original_id, new_security, original_date, original_currency)
      account.holdings.find_by(id: original_id) ||
        account.holdings.find_by(security: new_security, date: original_date, currency: original_currency) ||
        account.holdings.where(security: new_security).order(date: :desc).first!
    end

    def render_validation_error(message, errors)
      render json: {
        error: "validation_failed",
        message: message,
        errors: errors
      }, status: :unprocessable_entity
    end

    def log_and_render_error(action, exception)
      Rails.logger.error "HoldingsController##{action} error: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")
      render json: {
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error
    end
end
