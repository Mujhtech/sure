# frozen_string_literal: true

class Api::V1::FamilySettingsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :update

  def show
    @family = current_resource_owner.family
  end

  def update
    unless current_resource_owner.admin?
      render_json({ error: "forbidden", message: "Family settings can only be changed by an admin" }, status: :forbidden)
      return
    end

    @family = current_resource_owner.family

    if @family.update(family_settings_params)
      render :show
    else
      render_json({
        error: "validation_failed",
        message: "Family settings could not be updated",
        errors: @family.errors.full_messages
      }, status: :unprocessable_entity)
    end
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def family_settings_params
      source = params[:family].present? ? params.require(:family) : params
      source.permit(
        :name,
        :currency,
        :locale,
        :date_format,
        :country,
        :timezone,
        :month_start_day,
        :moniker,
        :default_account_sharing,
        enabled_currencies: []
      )
    end
end
