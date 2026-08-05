# frozen_string_literal: true

class Api::V1::InsightsController < Api::V1::BaseController
  include InsightsHelper

  before_action :require_insights_preview!
  before_action :ensure_read_scope, only: :index
  before_action :ensure_write_scope, only: %i[dismiss undismiss refresh]
  before_action :set_insight, only: %i[dismiss undismiss]

  def index
    @insights = current_resource_owner.family.insights.visible.ordered.to_a
    @unread_ids = @insights.select(&:active?).map(&:id).to_set

    render :index

    if ActiveModel::Type::Boolean.new.cast(params.fetch(:mark_read, true))
      current_resource_owner.family.insights.active.update_all(
        status: "read",
        read_at: Time.current,
        updated_at: Time.current
      )
    end
  end

  def dismiss
    @insight.dismiss!
    render json: { insight: insight_payload(@insight) }
  end

  def undismiss
    @insight.undismiss!
    render json: { insight: insight_payload(@insight) }
  end

  def refresh
    GenerateInsightsJob.perform_later(family_id: current_resource_owner.family_id)
    render json: { message: I18n.t("insights.refresh.queued") }, status: :accepted
  end

  private
    def require_insights_preview!
      return if current_resource_owner.preview_features_enabled?

      render json: {
        error: "preview_feature_disabled",
        message: I18n.t("preview.not_enabled")
      }, status: :forbidden
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_insight
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @insight = current_resource_owner.family.insights.find(params[:id])
    end

    def insight_payload(insight)
      {
        id: insight.id,
        status: insight.status,
        read_at: insight.read_at&.iso8601,
        dismissed_at: insight.dismissed_at&.iso8601
      }
    end
end
