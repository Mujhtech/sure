# frozen_string_literal: true

class Api::V1::FinancialReplaysController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    render_json(
      FinancialReplay::Builder.new(
        user: current_resource_owner,
        month: params[:month]
      ).call
    )
  rescue FinancialReplay::InsufficientActivityError => e
    render_json({
      error: "insufficient_activity",
      message: e.message
    }, status: :unprocessable_entity)
  rescue FinancialReplay::InvalidMonthError => e
    render_json({
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity)
  rescue FinancialReplay::IncompleteMonthError => e
    render_json({
      error: "month_not_complete",
      message: e.message,
      latest_available_month: e.latest_available_month
    }, status: :unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error "FinancialReplaysController#show error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render_json({
      error: "internal_server_error",
      message: "Financial Replay could not be loaded"
    }, status: :internal_server_error)
  end

  def availability
    render_json(
      FinancialReplay::Builder.new(user: current_resource_owner).availability
    )
  rescue StandardError => e
    Rails.logger.error "FinancialReplaysController#availability error: #{e.class}: #{e.message}"

    render_json({
      error: "internal_server_error",
      message: "Financial Replay availability could not be checked"
    }, status: :internal_server_error)
  end
end
