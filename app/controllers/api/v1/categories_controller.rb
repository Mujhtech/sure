# frozen_string_literal: true

class Api::V1::CategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy replace_and_destroy bootstrap destroy_all merge]
  before_action :set_category, only: %i[show update destroy replace_and_destroy]

  def index
    family = current_resource_owner.family
    categories_query = family.categories.includes(:parent, :subcategories).alphabetically

    # Apply filters
    categories_query = apply_filters(categories_query)

    # Handle pagination with Pagy
    @pagy, @categories = pagy(
      categories_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index
  rescue => e
    Rails.logger.error "CategoriesController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "CategoriesController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family
    attrs = category_params

    return unless validate_parent_id!(attrs[:parent_id])

    @category = family.categories.new(attrs)
    @category.lucide_icon = Category.suggested_icon(@category.name) if @category.lucide_icon.blank?

    if @category.save
      render :show, status: :created
    else
      render json: {
        error: "unprocessable_entity",
        message: @category.errors.full_messages.join(", ")
      }, status: :unprocessable_entity
    end
  end

  def update
    attrs = category_params
    return unless validate_parent_id!(attrs[:parent_id], category: @category)

    @category.assign_attributes(attrs)
    @category.lucide_icon = Category.suggested_icon(@category.name) if @category.lucide_icon.blank?

    if @category.save
      render :show
    else
      render json: {
        error: "unprocessable_entity",
        message: @category.errors.full_messages.join(", ")
      }, status: :unprocessable_entity
    end
  end

  def destroy
    @category.destroy!

    render json: { message: "Category deleted successfully" }, status: :ok
  end

  def replace_and_destroy
    replacement = replacement_category
    return if performed?

    reassigned_transactions_count = @category.transactions.count
    deleted_category = category_payload(@category)

    @category.replace_and_destroy!(replacement)

    render json: {
      message: "Category replaced and deleted successfully",
      reassigned_transactions_count: reassigned_transactions_count,
      deleted_category: deleted_category,
      replacement_category: replacement && category_payload(replacement.reload)
    }, status: :ok
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    render_validation_error(record_error_message(e))
  end

  def destroy_all
    current_resource_owner.family.categories.destroy_all

    render json: {
      message: "Categories deleted successfully",
      categories_count: current_resource_owner.family.categories.count
    }, status: :ok
  end

  def bootstrap
    current_resource_owner.family.categories.bootstrap!

    render json: {
      message: "Categories bootstrapped successfully",
      categories_count: current_resource_owner.family.categories.count
    }, status: :ok
  end

  def merge
    family = current_resource_owner.family
    merge_params = category_merge_params
    target_id = merge_params[:target_id].to_s
    source_ids = Array(merge_params[:source_ids]).map(&:to_s).reject(&:blank?).uniq

    if target_id.present? && source_ids.include?(target_id)
      render_validation_error("Target category cannot also be a source category")
      return
    end

    target = family.categories.find_by(id: target_id)
    unless target
      render_validation_error("Target category not found")
      return
    end

    unless source_ids.any?
      render_validation_error("No source categories selected")
      return
    end

    sources = family.categories.where(id: source_ids).to_a
    if sources.size != source_ids.size
      render_validation_error("One or more source categories were not found")
      return
    end

    merger = Category::Merger.new(family: family, target_category: target, source_categories: sources)
    unless merger.merge!
      render_validation_error("No source categories selected")
      return
    end

    @category = target.reload
    @merged_count = merger.merged_count

    render :merge
  rescue Category::Merger::UnauthorizedCategoryError => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    render_validation_error(record_error_message(e))
  end

  private

    def set_category
      family = current_resource_owner.family
      @category = family.categories.includes(:parent, :subcategories).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Category not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:read_write)
    end

    def category_params
      permitted = params.require(:category).permit(:name, :color, :icon, :lucide_icon, :parent_id)
      icon = permitted.delete(:icon)
      permitted[:lucide_icon] = icon if icon.present?
      permitted
    end

    def category_merge_params
      params.permit(:target_id, source_ids: [])
    end

    def replacement_category
      replacement_category_id = params[:replacement_category_id].presence ||
                                params.dig(:category, :replacement_category_id).presence

      return nil if replacement_category_id.blank?

      unless valid_uuid?(replacement_category_id)
        render_validation_error("replacement_category_id is invalid")
        return
      end

      if replacement_category_id == @category.id
        render_validation_error("Replacement category cannot be the same as the category being destroyed")
        return
      end

      replacement = current_resource_owner.family.categories.find_by(id: replacement_category_id)
      unless replacement
        render_validation_error("Replacement category not found")
        return
      end

      replacement
    end

    def validate_parent_id!(parent_id, category: nil)
      return true if parent_id.blank?

      family = current_resource_owner.family
      if category && parent_id == category.id
        render json: {
          error: "unprocessable_entity",
          message: "Parent cannot be the category itself"
        }, status: :unprocessable_entity
        return false
      end

      unless family.categories.exists?(id: parent_id)
        render json: {
          error: "unprocessable_entity",
          message: "Parent must be a category in your family"
        }, status: :unprocessable_entity
        return false
      end

      true
    end

    def apply_filters(query)
      # Filter for root categories only (no parent)
      if params[:roots_only].present? && ActiveModel::Type::Boolean.new.cast(params[:roots_only])
        query = query.roots
      end

      # Filter by parent_id
      if params[:parent_id].present?
        query = query.where(parent_id: params[:parent_id])
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

    def record_error_message(error)
      record = error.respond_to?(:record) ? error.record : nil
      record&.errors&.full_messages&.to_sentence.presence || error.message
    end

    def category_payload(category)
      {
        id: category.id,
        name: category.name,
        color: category.color,
        icon: category.lucide_icon,
        parent: category.parent && {
          id: category.parent.id,
          name: category.parent.name
        },
        subcategories_count: category.subcategories.size,
        created_at: category.created_at.iso8601,
        updated_at: category.updated_at.iso8601
      }
    end
end
