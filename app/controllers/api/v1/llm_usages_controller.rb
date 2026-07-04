# frozen_string_literal: true

class Api::V1::LlmUsagesController < Api::V1::BaseController
  before_action :ensure_read_scope

  DEFAULT_WINDOW = 30.days
  MAX_LIMIT = 100

  def show
    family = current_resource_owner.family
    end_date = safe_date_param(:end_date) || Date.current
    start_date = safe_date_param(:start_date) || (end_date - DEFAULT_WINDOW)

    if start_date > end_date
      start_date = end_date - DEFAULT_WINDOW
    end

    start_time = start_date.beginning_of_day
    end_time = end_date.end_of_day
    usages = family.llm_usages
                   .for_date_range(start_time, end_time)
                   .recent
                   .limit(safe_limit_param)
    statistics = LlmUsage.statistics_for_family(family, start_date: start_time, end_date: end_time)

    render_json({
      period: {
        start_date: start_date.iso8601,
        end_date: end_date.iso8601
      },
      statistics: statistics_payload(statistics),
      llm_usages: usages.map { |usage| usage_payload(usage) },
      meta: {
        limit: safe_limit_param,
        count: usages.length
      }
    })
  end

  private
    def safe_date_param(key)
      return nil if params[key].blank?

      parse_date_param(key)
    end

    def safe_limit_param
      limit = params[:limit].to_i
      case limit
      when 1..MAX_LIMIT then limit
      when (MAX_LIMIT + 1).. then MAX_LIMIT
      else MAX_LIMIT
      end
    end

    def statistics_payload(statistics)
      {
        total_requests: statistics[:total_requests],
        requests_with_cost: statistics[:requests_with_cost],
        total_prompt_tokens: statistics[:total_prompt_tokens],
        total_completion_tokens: statistics[:total_completion_tokens],
        total_tokens: statistics[:total_tokens],
        total_cost: statistics[:total_cost],
        avg_cost: statistics[:avg_cost],
        by_operation: statistics[:by_operation],
        by_model: statistics[:by_model]
      }
    end

    def usage_payload(usage)
      {
        id: usage.id,
        provider: usage.provider,
        model: usage.model,
        operation: usage.operation,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: usage.total_tokens,
        cache_creation_tokens: usage.cache_creation_tokens,
        cache_read_tokens: usage.cache_read_tokens,
        estimated_cost: usage.estimated_cost&.to_s,
        formatted_cost: usage.formatted_cost,
        failed: usage.failed?,
        http_status_code: usage.http_status_code,
        error_message: usage.error_message,
        created_at: usage.created_at.iso8601,
        updated_at: usage.updated_at.iso8601
      }
    end
end
