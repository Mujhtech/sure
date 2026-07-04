# frozen_string_literal: true

class Api::V1::TransactionSplitsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: %i[create update destroy]
  before_action :set_transaction
  before_action :ensure_write_permission!, only: %i[create update destroy]
  before_action :resolve_to_parent!, only: %i[show update destroy]

  def show
    render_transaction
  end

  def create
    unless @entry.transaction.splittable?
      render_validation_error("Transaction cannot be split")
      return
    end

    splits = normalized_splits
    return if performed?

    children = @entry.split!(splits)
    @entry.sync_account_later
    @transaction = @entry.transaction
    @split_children = children

    render_transaction(status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_split_error(e)
  end

  def update
    unless @entry.split_parent?
      render_validation_error("Transaction is not a split parent")
      return
    end

    splits = normalized_splits
    return if performed?

    Entry.transaction do
      @entry.unsplit!
      @split_children = @entry.split!(splits)
    end
    @entry.sync_account_later
    @transaction = @entry.transaction

    render_transaction
  rescue ActiveRecord::RecordInvalid => e
    render_split_error(e)
  end

  def destroy
    unless @entry.split_parent?
      render_validation_error("Transaction is not a split parent")
      return
    end

    @entry.unsplit!
    @entry.sync_account_later
    @transaction = @entry.transaction

    render_transaction
  end

  private

    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      @transaction = current_resource_owner.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:transaction_id])
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_write_permission!
      return if @entry.account.permission_for(current_resource_owner).in?(%i[owner full_control])

      render json: {
        error: "forbidden",
        message: "You do not have permission to split this transaction"
      }, status: :forbidden
    end

    def resolve_to_parent!
      return unless @entry.split_child?

      @entry = @entry.parent_entry
      @transaction = @entry.transaction
    end

    def normalized_splits
      raw_splits = split_params[:splits]
      raw_splits = raw_splits.values if raw_splits.respond_to?(:values)
      raw_splits = Array(raw_splits)

      if raw_splits.empty?
        render_validation_error("At least one split line is required")
        return []
      end

      validate_category_ids!(raw_splits)
      return [] if performed?

      raw_splits.map.with_index do |split, index|
        name = split[:name].to_s.strip
        if name.blank?
          render_validation_error("Split line #{index + 1} name is required")
          return []
        end

        {
          name: name,
          amount: parse_display_amount!(split[:amount], index) * -1,
          category_id: split[:category_id].presence,
          excluded: split[:excluded]
        }
      end
    end

    def validate_category_ids!(raw_splits)
      category_ids = raw_splits.filter_map { |split| split[:category_id].presence }.uniq
      return if category_ids.empty?

      existing_ids = current_resource_owner.family.categories.where(id: category_ids).pluck(:id)
      missing_ids = category_ids - existing_ids

      render_validation_error("Category not found: #{missing_ids.join(', ')}") if missing_ids.any?
    end

    def parse_display_amount!(raw, index)
      value = raw.to_s.strip
      if value.blank?
        render_validation_error("Split line #{index + 1} amount is required")
        return 0
      end

      BigDecimal(value)
    rescue ArgumentError
      render_validation_error("Split line #{index + 1} amount must be a valid number")
      0
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id, :excluded ])
    end

    def render_transaction(status: :ok)
      render template: "api/v1/transactions/show", status: status
    end

    def render_split_error(error)
      render json: {
        error: "validation_failed",
        message: error.message,
        errors: [ error.message ]
      }, status: :unprocessable_entity
    end
end
