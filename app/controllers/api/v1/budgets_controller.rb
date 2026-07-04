# frozen_string_literal: true

class Api::V1::BudgetsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update copy_previous]
  before_action :set_budget, only: %i[show update copy_previous]

  def index
    budgets_query = apply_filters(budgets_scope).order(start_date: :desc)
    @per_page = safe_per_page_param

    @pagy, @budgets = pagy(
      budgets_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  def create
    attrs = budget_create_params
    start_date = parse_budget_start_date(attrs[:start_date])
    return if performed?

    @budget = Budget.find_or_bootstrap(
      current_resource_owner.family,
      start_date: start_date,
      user: current_resource_owner
    )

    unless @budget
      render_validation_error("Budget date is outside the allowed range")
      return
    end

    updates = attrs.slice(:budgeted_spending, :expected_income)
    @budget.update!(updates) if updates.present?

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Budget could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  def update
    @budget.update!(budget_params)

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Budget could not be updated",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  def copy_previous
    if @budget.initialized?
      render_validation_error("Budget has already been initialized")
      return
    end

    source_budget = @budget.most_recent_initialized_budget
    unless source_budget
      render_validation_error("No previous initialized budget found")
      return
    end

    @budget.copy_from!(source_budget)

    render :show
  end

  private

    def set_budget
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget = budgets_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def budget_params
      params.require(:budget).permit(:budgeted_spending, :expected_income)
    end

    def budget_create_params
      params.require(:budget).permit(:start_date, :budgeted_spending, :expected_income)
    end

    def parse_budget_start_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      render_validation_error("start_date must be an ISO 8601 date")
      nil
    end

    def apply_filters(query)
      query = query.where("budgets.start_date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("budgets.end_date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end

    def budgets_scope
      current_resource_owner.family.budgets.includes(budget_categories: :category)
    end
end
