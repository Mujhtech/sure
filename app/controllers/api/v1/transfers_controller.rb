# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy mark_as_recurring]
  before_action :set_transfer, only: :show
  before_action :set_writable_transfer, only: %i[update destroy mark_as_recurring]

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  def create
    attrs = transfer_params
    missing_fields = %i[from_account_id to_account_id amount].select { |key| attrs[key].blank? }
    if missing_fields.any?
      render_validation_error("#{missing_fields.join(', ')} required")
      return
    end

    source_account = writable_accounts_scope.find(attrs[:from_account_id])
    destination_account = writable_accounts_scope.find(attrs[:to_account_id])

    @transfer = Transfer::Creator.new(
      family: current_resource_owner.family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: attrs[:date].present? ? Date.iso8601(attrs[:date]) : Date.current,
      amount: attrs[:amount].to_d,
      exchange_rate: attrs[:exchange_rate].presence&.to_d
    ).create

    if @transfer.persisted?
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Transfer could not be created",
        errors: @transfer.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue Money::ConversionError
    render_validation_error("Exchange rate unavailable for selected currencies and date")
  rescue ArgumentError => e
    render_validation_error(e.message.presence || "Transfer parameters are invalid")
  end

  def update
    attrs = transfer_update_params
    if attrs[:status].present? && !attrs[:status].in?(%w[confirmed rejected])
      render_validation_error("status must be one of: confirmed, rejected")
      return
    end

    if attrs[:status] == "rejected"
      @transfer.reject!
      render json: { message: "Transfer rejected successfully" }, status: :ok
      return
    end

    Transfer.transaction do
      @transfer.confirm! if attrs[:status] == "confirmed"
      update_transfer_details(attrs) if attrs.key?(:notes) || attrs.key?(:category_id)
    end

    render :show
  end

  def destroy
    @transfer.destroy!

    render json: { message: "Transfer deleted successfully" }, status: :ok
  end

  def mark_as_recurring
    if current_resource_owner.family.recurring_transactions_disabled?
      render_validation_error("Recurring transactions are disabled")
      return
    end

    source_account = @transfer.from_account
    destination_account = @transfer.to_account
    unless source_account && destination_account
      render_validation_error("Transfer is missing one of its account endpoints")
      return
    end

    existing = current_resource_owner.family.recurring_transactions.find_by(
      account_id: source_account.id,
      destination_account_id: destination_account.id,
      amount: @transfer.outflow_transaction.entry.amount,
      currency: @transfer.outflow_transaction.entry.currency
    )

    if existing
      render json: {
        error: "conflict",
        message: "Recurring transfer already exists",
        recurring_transaction_id: existing.id
      }, status: :conflict
      return
    end

    @recurring_transaction = RecurringTransaction.create_from_transfer(@transfer)
    render "api/v1/recurring_transactions/show", status: :created
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    render json: {
      error: "validation_failed",
      message: "Recurring transfer could not be created",
      errors: e.respond_to?(:record) ? e.record.errors.full_messages : [ e.message ]
    }, status: :unprocessable_entity
  end

  private

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def set_writable_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
      endpoint_ids = [ @transfer.from_account&.id, @transfer.to_account&.id ].compact
      writable_count = writable_accounts_scope.where(id: endpoint_ids).distinct.count
      raise ActiveRecord::RecordNotFound unless endpoint_ids.size == 2 && writable_count == 2
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def writable_accounts_scope
      current_resource_owner.family.accounts.writable_by(current_resource_owner).visible
    end

    def transfer_params
      params.require(:transfer).permit(:from_account_id, :to_account_id, :amount, :date, :exchange_rate)
    end

    def transfer_update_params
      params.require(:transfer).permit(:notes, :status, :category_id)
    end

    def update_transfer_details(attrs)
      category_id = attrs[:category_id]
      category = if category_id.present?
        raise ActiveRecord::RecordNotFound unless valid_uuid?(category_id)

        current_resource_owner.family.categories.find(category_id)
      end

      @transfer.outflow_transaction.update!(category_id: category&.id) if attrs.key?(:category_id)
      @transfer.update!(notes: attrs[:notes]) if attrs.key?(:notes)
    end
end
