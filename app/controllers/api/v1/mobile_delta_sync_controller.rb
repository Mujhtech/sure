# frozen_string_literal: true

class Api::V1::MobileDeltaSyncController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :create
  before_action :ensure_write_scope, only: :create

  def create
    mobile_device = resolve_mobile_device
    result = MobileDeltaSync::Processor.new(
      user: current_resource_owner,
      mobile_device: mobile_device
    ).call(
      cursor: params[:cursor],
      changes: sync_changes
    )

    render json: result.merge(server_time: Time.current.iso8601), status: :ok
  rescue MobileDeltaSync::Processor::ValidationError => e
    render_validation_error(e.message)
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def sync_changes
      changes = params[:changes]
      return [] if changes.blank?

      Array.wrap(changes).reject { |change| change.respond_to?(:blank?) && change.blank? }
    end

    def resolve_mobile_device
      token_device = doorkeeper_token&.mobile_device_id && current_resource_owner.mobile_devices.find_by(id: doorkeeper_token.mobile_device_id)
      return token_device if token_device

      device_params = params[:device] || {}
      device_id = params[:device_id].presence || device_params[:device_id].presence
      return nil if device_id.blank?

      MobileDevice.upsert_device!(
        current_resource_owner,
        device_id: device_id,
        device_name: device_params[:device_name].presence || params[:device_name].presence || "Mobile device",
        device_type: device_params[:device_type].presence || params[:device_type].presence || "ios",
        os_version: device_params[:os_version].presence || params[:os_version].presence,
        app_version: device_params[:app_version].presence || params[:app_version].presence
      )
    end
end
