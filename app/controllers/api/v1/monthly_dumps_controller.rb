# frozen_string_literal: true

class Api::V1::MonthlyDumpsController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    render_json(
      MonthlyDump::Builder.new(
        user: current_resource_owner,
        month: params[:month]
      ).call
    )
  rescue MonthlyDump::InvalidMonthError => e
    render_json({
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity)
  rescue MonthlyDump::IncompleteMonthError => e
    render_json({
      error: "month_not_complete",
      message: e.message,
      latest_available_month: e.latest_available_month
    }, status: :unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error "MonthlyDumpsController#show error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render_json({
      error: "internal_server_error",
      message: "Monthly Dump could not be loaded"
    }, status: :internal_server_error)
  end
end
