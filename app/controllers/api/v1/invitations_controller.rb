# frozen_string_literal: true

class Api::V1::InvitationsController < Api::V1::BaseController
  skip_before_action :authenticate_request!, only: :accept_details
  skip_before_action :check_api_key_rate_limit, only: :accept_details
  skip_before_action :log_api_access, only: :accept_details

  before_action :ensure_read_scope, only: :index
  before_action :ensure_write_scope, only: %i[create destroy accept]
  before_action :ensure_admin, only: %i[create destroy]

  def index
    @invitations = current_resource_owner.family.invitations.pending.order(:created_at)

    render :index
  end

  def create
    @invitation = current_resource_owner.family.invitations.build(invitation_params)
    @invitation.inviter = current_resource_owner

    if @invitation.save
      handle_saved_invitation
    else
      render_invitation_validation_error(@invitation)
    end
  end

  def destroy
    invitation = current_resource_owner.family.invitations.find(params[:id])
    invitation.destroy!

    render json: {
      message: "Invitation deleted successfully"
    }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Invitation not found"
    }, status: :not_found
  end

  def accept_details
    @invitation = pending_invitation_from_token
    return render_invitation_not_found unless @invitation

    @accepted_existing_user = false
    render :show
  end

  def accept
    @invitation = pending_invitation_from_token
    return render_invitation_not_found unless @invitation

    if @invitation.accept_for(current_resource_owner)
      @accepted_existing_user = true
      render :show
    else
      render_invitation_acceptance_error(@invitation, current_resource_owner)
    end
  end

  private

    def handle_saved_invitation
      existing_user = User.find_by(email: @invitation.email.to_s.strip.downcase)

      if existing_user && @invitation.would_orphan_owned_accounts?(existing_user)
        @invitation.destroy
        render json: {
          error: "validation_failed",
          message: "Existing user owns data in another family and cannot be moved",
          errors: [ "Existing user owns data in another family and cannot be moved" ]
        }, status: :unprocessable_entity
      elsif existing_user && @invitation.accept_for(existing_user)
        @invitation.reload
        @accepted_existing_user = true
        render :show, status: :ok
      elsif existing_user
        @invitation.destroy
        render json: {
          error: "validation_failed",
          message: "Existing user could not be added to this family",
          errors: [ "Existing user could not be added to this family" ]
        }, status: :unprocessable_entity
      else
        InvitationMailer.invite_email(@invitation).deliver_later unless self_hosted?
        @accepted_existing_user = false
        render :show, status: :created
      end
    end

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end

    def render_invitation_validation_error(invitation)
      render json: {
        error: "validation_failed",
        message: "Invitation could not be created",
        errors: invitation.errors.full_messages
      }, status: :unprocessable_entity
    end

    def pending_invitation_from_token
      token = params[:token].to_s.presence
      return nil if token.blank?

      Invitation.pending.find_by(token: token)
    end

    def render_invitation_not_found
      render json: {
        error: "not_found",
        message: "Invitation not found"
      }, status: :not_found
    end

    def render_invitation_acceptance_error(invitation, user)
      message = if user.blank? || invitation.email.to_s.strip.downcase != user.email.to_s.strip.downcase
        "Invitation email does not match the current user"
      elsif invitation.would_orphan_owned_accounts?(user)
        "Existing user owns data in another family and cannot be moved"
      else
        "Invitation could not be accepted"
      end

      render json: {
        error: "validation_failed",
        message: message,
        errors: [ message ]
      }, status: :unprocessable_entity
    end

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
        message: "Invitations require a family admin"
      }, status: :forbidden
    end
end
