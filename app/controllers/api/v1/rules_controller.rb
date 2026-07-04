# frozen_string_literal: true

class Api::V1::RulesController < Api::V1::BaseController
  include Pagy::Backend

  BOOLEAN_FILTERS = {
    "true" => true,
    "1" => true,
    "false" => false,
    "0" => false
  }.freeze
  RESOURCE_TYPES = %w[transaction].freeze

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy, :apply, :apply_all, :destroy_all, :clear_ai_cache ]
  before_action :set_rule, only: [ :show, :update, :destroy, :apply ]

  def index
    return render_invalid_resource_type_filter if invalid_resource_type_filter?

    @per_page = safe_per_page_param
    rules_query = current_resource_owner.family.rules
      .includes(:actions, conditions: :sub_conditions)
      .order(:created_at, :id)

    rules_query = rules_query.where(resource_type: params[:resource_type]) if params[:resource_type].present?
    if params[:active].present?
      active = parse_boolean_filter(params[:active])
      return if performed?

      rules_query = rules_query.where(active: active)
    end

    @pagy, @rules = pagy(
      rules_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  def create
    return if invalid_resource_type_param?

    @rule = current_resource_owner.family.rules.build(rule_params)

    if @rule.save
      render :show, status: :created
    else
      render_rule_validation_error
    end
  end

  def update
    return if invalid_resource_type_param?

    if @rule.update(rule_params)
      render :show
    else
      render_rule_validation_error
    end
  end

  def destroy
    @rule.destroy!

    render json: { message: "Rule deleted successfully" }, status: :ok
  end

  def apply
    @rule.update!(active: true)
    @rule.apply_later(ignore_attribute_locks: true)

    render :show, status: :accepted
  end

  def apply_all
    ApplyAllRulesJob.perform_later(current_resource_owner.family)

    render json: { message: "Rules apply job queued successfully" }, status: :accepted
  end

  def destroy_all
    deleted_count = current_resource_owner.family.rules.count
    current_resource_owner.family.rules.destroy_all

    render json: { message: "Rules deleted successfully", deleted_count: deleted_count }, status: :ok
  end

  def clear_ai_cache
    ClearAiCacheJob.perform_later(current_resource_owner.family)

    render json: { message: "AI cache clear job queued successfully" }, status: :accepted
  end

  private

    def set_rule
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @rule = current_resource_owner.family.rules
        .includes(:actions, conditions: :sub_conditions)
        .find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def rule_params
      params.require(:rule).permit(
        :resource_type, :effective_date, :active, :name,
        conditions_attributes: [
          :id, :condition_type, :operator, :value, :_destroy,
          sub_conditions_attributes: [ :id, :condition_type, :operator, :value, :_destroy ]
        ],
        actions_attributes: [
          :id, :action_type, :value, :_destroy
        ]
      )
    end

    def invalid_resource_type_param?
      resource_type = params.dig(:rule, :resource_type)
      return false if resource_type.blank? || resource_type.in?(RESOURCE_TYPES)

      render_invalid_resource_type_filter
      true
    end

    def render_rule_validation_error
      render json: {
        error: "validation_failed",
        message: "Rule could not be saved",
        errors: @rule.errors.full_messages
      }, status: :unprocessable_entity
    end

    def parse_boolean_filter(value)
      normalized = value.to_s.downcase
      return BOOLEAN_FILTERS[normalized] if BOOLEAN_FILTERS.key?(normalized)

      render_validation_error("active must be one of: true, false, 1, 0")
      nil
    end

    def invalid_resource_type_filter?
      params[:resource_type].present? && !params[:resource_type].in?(RESOURCE_TYPES)
    end

    def render_invalid_resource_type_filter
      render_validation_error("resource_type must be one of: #{RESOURCE_TYPES.join(", ")}")
    end
end
