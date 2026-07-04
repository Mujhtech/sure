# frozen_string_literal: true

class Api::V1::GoalsController < Api::V1::BaseController
  include Pagy::Backend

  FUNDABLE_TYPES = %w[Depository Investment].freeze
  STATES = %w[active paused completed archived].freeze
  TRANSITIONS = %i[pause resume complete archive unarchive reopen].freeze

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy pause resume complete archive unarchive reopen]
  before_action :set_goal, only: %i[show update destroy pause resume complete archive unarchive reopen]

  def index
    goals_query = goals_scope.alphabetically
    goals_query = apply_filters(goals_query)

    @per_page = safe_per_page_param
    @pagy, @goals = pagy(goals_query, page: safe_page_param, limit: @per_page)
    attach_goal_calculation_context(@goals)

    render :index
  end

  def show
    attach_goal_calculation_context([ @goal ])

    render :show
  end

  def create
    @goal = current_resource_owner.family.goals.new(goal_params)
    accounts = lookup_accounts(goal_input[:account_ids])
    @goal.currency = accounts.first&.currency || current_resource_owner.family.primary_currency_code if @goal.currency.blank?

    Goal.transaction do
      accounts.each do |account|
        @goal.goal_accounts.build(account: account, allocated_amount: submitted_allocations[account.id.to_s])
      end

      @goal.save!
    end

    attach_goal_calculation_context([ @goal ])
    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_goal_validation_error(e.record)
  end

  def update
    account_ids = goal_input[:account_ids]
    accounts_supplied = goal_input.key?(:account_ids)
    accounts = accounts_supplied ? lookup_accounts(account_ids) : []

    if accounts_supplied && accounts.empty?
      @goal.errors.add(:base, :at_least_one_linked_account_required)
      render_goal_validation_error(@goal)
      return
    end

    Goal.transaction do
      @goal.update!(goal_params)
      sync_linked_accounts!(@goal, accounts, submitted_allocations) if accounts_supplied
    end

    attach_goal_calculation_context([ @goal ])
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_goal_validation_error(e.record)
  end

  def destroy
    unless @goal.archived?
      render_validation_error("Goal must be archived before it can be deleted")
      return
    end

    @goal.destroy!

    render json: { message: "Goal deleted successfully" }, status: :ok
  end

  TRANSITIONS.each do |event|
    define_method(event) do
      perform_transition!(event)
    end
  end

  private

    def set_goal
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @goal = goals_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def goals_scope
      current_resource_owner.family.goals.includes(:open_pledges, goal_accounts: :account, linked_accounts: :account_providers)
    end

    def apply_filters(query)
      if params[:state].present?
        unless STATES.include?(params[:state])
          raise InvalidFilterError, "state must be one of: #{STATES.join(', ')}"
        end

        query = query.where(state: params[:state])
      end

      if params[:search].present?
        query = query.where("goals.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s)}%")
      end

      query
    end

    def goal_input
      params.require(:goal)
    end

    def goal_params
      goal_input.permit(:name, :target_amount, :target_date, :color, :icon, :notes)
    end

    def lookup_accounts(ids)
      ids = Array(ids).reject(&:blank?)
      return [] if ids.empty?

      unless ids.all? { |id| valid_uuid?(id) }
        raise ActiveRecord::RecordNotFound, "Account not found"
      end

      accounts = current_resource_owner.family.accounts
                                       .accessible_by(current_resource_owner)
                                       .where(accountable_type: FUNDABLE_TYPES)
                                       .visible
                                       .where(id: ids)
                                       .to_a
      raise ActiveRecord::RecordNotFound, "Account not found" unless accounts.size == ids.uniq.size

      accounts
    end

    def sync_linked_accounts!(goal, accounts, allocations = {})
      desired_ids = accounts.map(&:id).to_set
      current_ids = goal.goal_accounts.pluck(:account_id).to_set
      removable_ids = current_resource_owner.family.accounts
                                      .accessible_by(current_resource_owner)
                                      .where(id: current_ids.to_a)
                                      .pluck(:id)
                                      .to_set

      ((current_ids & removable_ids) - desired_ids).each do |id|
        goal.goal_accounts.where(account_id: id).destroy_all
      end
      goal.goal_accounts.reload

      accounts.each do |account|
        existing = goal.goal_accounts.find { |goal_account| goal_account.account_id == account.id }
        if existing
          existing.allocated_amount = allocations[account.id.to_s] if allocations.key?(account.id.to_s)
        else
          goal.goal_accounts.build(account: account, allocated_amount: allocations[account.id.to_s])
        end
      end

      goal.save!
    end

    def submitted_allocations
      raw = params.dig(:goal, :allocations)
      return {} if raw.blank?

      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      hash.each_with_object({}) do |(account_id, amount), memo|
        memo[account_id.to_s] = amount.to_s.strip.presence
      end
    end

    def perform_transition!(event)
      unless @goal.aasm.may_fire_event?(event)
        render_validation_error("Goal cannot #{event} from its current state")
        return
      end

      @goal.public_send("#{event}!")
      attach_goal_calculation_context([ @goal ])

      render :show
    end

    def attach_goal_calculation_context(goals)
      goals = goals.to_a
      return if goals.empty?

      pooled = Goal.pooled_allocations_for(current_resource_owner.family)
      flows = Goal.market_flows_for(current_resource_owner.family)
      goals.each do |goal|
        goal.pooled_allocations = pooled
        goal.market_flows = flows
      end
    end

    def render_goal_validation_error(goal)
      render json: {
        error: "validation_failed",
        message: "Goal could not be saved",
        errors: goal.errors.full_messages
      }, status: :unprocessable_entity
    end
end
