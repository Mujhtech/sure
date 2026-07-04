# frozen_string_literal: true

class Api::V1::DebugLogsController < Api::V1::BaseController
  include Pagy::Backend

  FILTER_ID_PARAMS = %i[family_id account_id user_id account_provider_id].freeze

  before_action :ensure_read_scope
  before_action :ensure_super_admin!
  before_action :set_debug_log_entry, only: :show

  def index
    debug_logs_query = apply_filters(DebugLogEntry.includes(:family, :account, :user, :account_provider).recent)
    @per_page = safe_per_page_param

    @pagy, debug_logs = pagy(
      debug_logs_query,
      page: safe_page_param,
      limit: @per_page
    )

    render_json({
      debug_logs: debug_logs.map { |debug_log| debug_log_payload(debug_log) },
      filters: filter_options_payload,
      pagination: pagination_payload
    })
  end

  def show
    render_json({
      debug_log: debug_log_payload(@debug_log_entry)
    })
  end

  private

    def set_debug_log_entry
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @debug_log_entry = DebugLogEntry
        .includes(:family, :account, :user, :account_provider)
        .find(params[:id])
    end

    def ensure_super_admin!
      return if current_resource_owner&.super_admin?

      render_json({
        error: "forbidden",
        message: "You must be a super admin to access debug logs"
      }, status: :forbidden)
    end

    def apply_filters(scope)
      filter_params = debug_filter_params
      start_date = safe_parse_date(filter_params[:start_date])
      end_date = safe_parse_date(filter_params[:end_date])

      scope = scope.with_category(filter_params[:category])
      scope = scope.with_level(filter_params[:level])
      scope = scope.with_source(filter_params[:source])
      scope = scope.with_provider_key(filter_params[:provider_key])

      FILTER_ID_PARAMS.each do |key|
        value = safe_uuid(filter_params[key])
        scope = scope.where(key => value) if value.present?
      end

      scope = scope.where("created_at >= ?", start_date.beginning_of_day) if start_date.present?
      scope = scope.where("created_at < ?", end_date.next_day.beginning_of_day) if end_date.present?
      scope
    end

    def debug_filter_params
      params.permit(:category, :level, :source, :provider_key, :start_date, :end_date, *FILTER_ID_PARAMS)
    end

    def safe_parse_date(value)
      Date.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end

    def safe_uuid(value)
      return if value.blank?

      uuid = value.to_s.strip
      uuid.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i) ? uuid : nil
    end

    def debug_log_payload(debug_log)
      {
        id: debug_log.id,
        category: debug_log.category,
        level: debug_log.level,
        message: debug_log.message,
        source: debug_log.source,
        provider_key: debug_log.provider_key,
        metadata: debug_log.metadata || {},
        family: family_payload(debug_log.family),
        account: account_payload(debug_log.account),
        user: user_payload(debug_log.user),
        account_provider: account_provider_payload(debug_log.account_provider),
        created_at: debug_log.created_at.iso8601,
        updated_at: debug_log.updated_at.iso8601
      }
    end

    def family_payload(family)
      return nil unless family

      {
        id: family.id,
        name: family.name
      }
    end

    def account_payload(account)
      return nil unless account

      {
        id: account.id,
        name: account.name,
        account_type: account.accountable_type&.underscore
      }
    end

    def user_payload(user)
      return nil unless user

      {
        id: user.id,
        email: user.email,
        name: user.display_name,
        role: user.role
      }
    end

    def account_provider_payload(account_provider)
      return nil unless account_provider

      {
        id: account_provider.id,
        account_id: account_provider.account_id,
        provider_type: account_provider.provider_type,
        provider_id: account_provider.provider_id
      }
    end

    def filter_options_payload
      {
        categories: DebugLogEntry.distinct.order(:category).pluck(:category),
        levels: DebugLogEntry::LEVELS,
        sources: DebugLogEntry.distinct.order(:source).pluck(:source),
        provider_keys: DebugLogEntry.where.not(provider_key: [ nil, "" ]).distinct.order(:provider_key).pluck(:provider_key)
      }
    end

    def pagination_payload
      {
        page: @pagy.page,
        per_page: @per_page,
        total_count: @pagy.count,
        total_pages: @pagy.pages
      }
    end
end
