# frozen_string_literal: true

class Api::V1::BudgetCategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: :update
  before_action :set_budget_category, only: %i[show update]

  def index
    budget_categories_query = apply_filters(budget_categories_scope)
      .order("budgets.start_date DESC", "categories.name ASC")
    @per_page = safe_per_page_param
    @include_derived_amounts = include_derived_amounts?

    @pagy, @budget_categories = pagy(
      budget_categories_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  def update
    @budget_category.update_budgeted_spending!(budgeted_spending_param)

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Budget category could not be updated",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  private

    def set_budget_category
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget_category = budget_categories_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def budgeted_spending_param
      params.require(:budget_category)
            .permit(:budgeted_spending)
            .fetch(:budgeted_spending, nil)
            .presence || 0
    end

    def budget_categories_scope
      BudgetCategory
        .joins(:budget, :category)
        .where(budgets: { family_id: current_resource_owner.family_id })
        .includes({ budget: { budget_categories: { category: :parent } } }, category: :parent)
    end

    def apply_filters(query)
      if params[:budget_id].present?
        raise InvalidFilterError, "budget_id must be a valid UUID" unless valid_uuid?(params[:budget_id])

        query = query.where(budget_id: params[:budget_id])
      end

      if params[:category_id].present?
        raise InvalidFilterError, "category_id must be a valid UUID" unless valid_uuid?(params[:category_id])

        query = query.where(category_id: params[:category_id])
      end

      query = query.where("budgets.start_date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("budgets.end_date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end

    def include_derived_amounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_derived_amounts]) == true
    end
end
