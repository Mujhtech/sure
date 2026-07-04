# frozen_string_literal: true

class Api::V1::GoalPledgesController < Api::V1::BaseController
  before_action :ensure_write_scope
  before_action :set_goal
  before_action :set_pledge, only: %i[renew destroy]

  def create
    @pledge = @goal.goal_pledges.new(pledge_params)
    @pledge.account = lookup_account(pledge_input[:account_id])
    @pledge.kind = @pledge.account&.default_pledge_kind || "transfer"
    @pledge.currency = @goal.currency

    if @pledge.save
      render :show, status: :created
    else
      render_pledge_validation_error(@pledge)
    end
  end

  def renew
    @pledge.extend!

    render :show
  rescue GoalPledge::NotOpenError
    render_validation_error("Only open pledges can be renewed")
  end

  def destroy
    @pledge.cancel!

    render :show
  rescue GoalPledge::NotOpenError
    render_validation_error("Only open pledges can be cancelled")
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_goal
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:goal_id])

      @goal = current_resource_owner.family.goals
                                    .includes(:open_pledges, goal_accounts: :account, linked_accounts: :account_providers)
                                    .find(params[:goal_id])
    end

    def set_pledge
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @pledge = @goal.goal_pledges.includes(:account, :matched_transaction).find(params[:id])
    end

    def pledge_input
      params.require(:goal_pledge)
    end

    def pledge_params
      pledge_input.permit(:amount)
    end

    def lookup_account(id)
      raise ActiveRecord::RecordNotFound, "Account not found" unless id.present? && valid_uuid?(id)

      @goal.linked_accounts.find_by(id: id) || raise(ActiveRecord::RecordNotFound, "Account not found")
    end

    def render_pledge_validation_error(pledge)
      render json: {
        error: "validation_failed",
        message: "Goal pledge could not be saved",
        errors: pledge.errors.full_messages
      }, status: :unprocessable_entity
    end
end
