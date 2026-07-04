# frozen_string_literal: true

class Api::V1::AccountSharingsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :update
  before_action :set_account

  def show
    load_sharing_context
    render :show
  end

  def update
    if finance_inclusion_requested?
      update_finance_inclusion
      return if performed?
    elsif @account.owned_by?(current_resource_owner)
      update_member_shares
    else
      render_forbidden("Only the account owner can update account sharing")
      return
    end

    load_sharing_context
    render :show
  rescue ActionController::ParameterMissing => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Account sharing could not be updated",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  private

    def set_account
      unless valid_uuid?(params[:account_id])
        render json: {
          error: "not_found",
          message: "Account not found"
        }, status: :not_found
        return
      end

      @account = current_resource_owner.family.accounts
                                       .accessible_by(current_resource_owner)
                                       .where.not(status: "pending_deletion")
                                       .includes(:owner, account_shares: :user)
                                       .find(params[:account_id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
    end

    def load_sharing_context
      @family_members = current_resource_owner.family.users
                                      .where.not(id: @account.owner_id)
                                      .where(active: true)
                                      .order(:email)
      @account_shares_by_user_id = @account.account_shares.index_by(&:user_id)
      @current_user_share = @account_shares_by_user_id[current_resource_owner.id]
    end

    def update_member_shares
      AccountShare.transaction do
        sharing_members_params.each do |member_params|
          user = eligible_members.find_by(id: member_params[:user_id])
          next unless user

          share = @account.account_shares.find_by(user: user)

          if ActiveModel::Type::Boolean.new.cast(member_params[:shared])
            permission = permitted_permission(member_params[:permission], share)

            if share
              share.update!(permission: permission)
            else
              @account.account_shares.create!(user: user, permission: permission, include_in_finances: true)
            end
          elsif share
            share.destroy!
          end
        end
      end
    end

    def update_finance_inclusion
      share = @account.account_shares.find_by!(user: current_resource_owner)
      include_value = sharing_params[:include_in_finances]

      share.update!(include_in_finances: ActiveModel::Type::Boolean.new.cast(include_value))
    rescue ActiveRecord::RecordNotFound
      render_forbidden("Only shared users can update finance inclusion for this account")
    end

    def eligible_members
      @eligible_members ||= current_resource_owner.family.users
                                          .where.not(id: @account.owner_id)
                                          .where(active: true)
    end

    def sharing_params
      params.require(:sharing).permit(:include_in_finances, members: [ :user_id, :shared, :permission ])
    end

    def sharing_members_params
      members = sharing_params[:members] || []
      members.respond_to?(:values) ? members.values : Array.wrap(members)
    end

    def finance_inclusion_requested?
      sharing = params[:sharing]
      sharing.respond_to?(:key?) && sharing.key?(:include_in_finances) && !@account.owned_by?(current_resource_owner)
    end

    def permitted_permission(requested_permission, existing_share)
      if AccountShare::PERMISSIONS.include?(requested_permission)
        requested_permission
      else
        existing_share&.permission || "read_only"
      end
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def render_forbidden(message)
      render json: {
        error: "forbidden",
        message: message
      }, status: :forbidden
    end
end
