# frozen_string_literal: true

class Api::V1::Admin::InvitationsController < Api::V1::BaseController
  before_action :ensure_write_scope
  before_action :ensure_super_admin!
  before_action :set_invitation, only: :destroy

  def destroy
    invitation_id = @invitation.id
    @invitation.destroy!

    render_json({
      message: "Invitation deleted successfully",
      invitation_id: invitation_id
    })
  end

  def destroy_all
    family = Family.find(params[:id])
    deleted_count = family.invitations.pending.destroy_all.count

    render_json({
      message: "Pending invitations deleted successfully",
      family_id: family.id,
      deleted_count: deleted_count
    })
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_super_admin!
      return if performed?
      return if current_resource_owner&.super_admin?

      render_json({
        error: "forbidden",
        message: "Invitations can only be managed by a super admin"
      }, status: :forbidden)
    end

    def set_invitation
      @invitation = Invitation.find(params[:id])
    end
end
