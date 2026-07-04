# frozen_string_literal: true

class Api::V1::InviteCodesController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :index
  before_action :ensure_write_scope, only: %i[create destroy]
  before_action :ensure_self_hosted_mode
  before_action :ensure_super_admin
  before_action :set_invite_code, only: :destroy

  def index
    invite_codes = InviteCode.order(created_at: :desc)

    render_json({
      invite_codes: invite_codes.map { |invite_code| invite_code_payload(invite_code) }
    })
  end

  def create
    invite_code = InviteCode.create!

    render_json({ invite_code: invite_code_payload(invite_code) }, status: :created)
  end

  def destroy
    @invite_code.destroy!

    render_json({ message: "Invite code deleted successfully" })
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_self_hosted_mode
      return if self_hosted?

      render_json({ error: "forbidden", message: "Invite codes are only available in self-hosted mode" }, status: :forbidden)
    end

    def ensure_super_admin
      return if performed?
      return if current_resource_owner.super_admin?

      render_json({ error: "forbidden", message: "Invite codes can only be managed by a super admin" }, status: :forbidden)
    end

    def set_invite_code
      @invite_code = InviteCode.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_json({ error: "not_found", message: "Invite code not found" }, status: :not_found)
    end

    def invite_code_payload(invite_code)
      {
        id: invite_code.id,
        token: invite_code.token,
        created_at: invite_code.created_at.iso8601,
        updated_at: invite_code.updated_at.iso8601
      }
    end
end
