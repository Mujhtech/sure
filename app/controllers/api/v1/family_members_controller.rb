# frozen_string_literal: true

class Api::V1::FamilyMembersController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :index
  before_action :ensure_write_scope, only: :destroy
  before_action :ensure_admin, only: :destroy

  def index
    @family_members = current_resource_owner.family.users.order(:created_at)
    @pending_invitations = current_resource_owner.family.invitations.pending.order(:created_at)

    render :index
  end

  def destroy
    member = current_resource_owner.family.users.find(params[:id])

    if member == current_resource_owner
      render_validation_error("You cannot remove yourself from the family")
      return
    end

    if member.owned_accounts.where.not(family_id: current_resource_owner.family_id).exists?
      render_validation_error("Family member owns data in another family and cannot be removed")
      return
    end

    member_email = member.email
    member.destroy!
    current_resource_owner.family.invitations.find_by(email: member_email)&.destroy

    render json: {
      message: "Family member removed successfully"
    }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Family member not found"
    }, status: :not_found
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_admin
      return if current_resource_owner.admin?

      render json: {
        error: "forbidden",
        message: "Family member management requires a family admin"
      }, status: :forbidden
    end
end
