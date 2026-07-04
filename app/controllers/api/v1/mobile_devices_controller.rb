# frozen_string_literal: true

class Api::V1::MobileDevicesController < Api::V1::BaseController
  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: :destroy
  before_action :set_mobile_device, only: %i[show destroy]

  def index
    devices = current_resource_owner.mobile_devices.order(last_seen_at: :desc, created_at: :desc)

    render json: {
      mobile_devices: devices.map { |device| mobile_device_payload(device) }
    }
  end

  def show
    render json: mobile_device_payload(@mobile_device)
  end

  def destroy
    revoked_count = @mobile_device.active_tokens.count
    @mobile_device.revoke_all_tokens!

    render json: {
      message: "Mobile device tokens revoked",
      mobile_device: mobile_device_payload(@mobile_device),
      revoked_token_count: revoked_count
    }
  end

  private
    def set_mobile_device
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @mobile_device = current_resource_owner.mobile_devices.find(params[:id])
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def current_mobile_device_id
      doorkeeper_token&.mobile_device_id
    end

    def mobile_device_payload(device)
      {
        id: device.id,
        name: device.device_name,
        device_type: device.device_type,
        os_version: device.os_version,
        app_version: device.app_version,
        active: device.last_seen_at.present? && device.active?,
        current: current_mobile_device_id.present? && device.id == current_mobile_device_id,
        active_token_count: device.active_tokens.count,
        last_seen_at: device.last_seen_at&.iso8601,
        created_at: device.created_at.iso8601,
        updated_at: device.updated_at.iso8601
      }
    end
end
