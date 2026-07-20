# frozen_string_literal: true

class Api::V1::SavingsChallengesController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :create

  def show
    @enrollment = enrollment_scope.includes(goal: [ :goal_accounts, :linked_accounts ]).first
  end

  def create
    existing = enrollment_scope.includes(goal: [ :goal_accounts, :linked_accounts ]).first
    if existing
      @enrollment = existing
      render :show
      return
    end

    if SavingsChallenge::Campaign.phase == "ended"
      render_validation_error("This savings challenge has ended.")
      return
    end

    account = fundable_accounts.find(valid_uuid!(challenge_input[:account_id]))
    target_amount = positive_amount!(challenge_input[:target_amount])

    SavingsChallengeEnrollment.transaction do
      goal = current_resource_owner.family.goals.new(
        name: SavingsChallenge::Campaign::NAME,
        currency: account.currency,
        target_date: SavingsChallenge::Campaign.ends_on,
        color: "#4da568",
        icon: "target",
        notes: "Created for the #{SavingsChallenge::Campaign::NAME}."
      )
      goal.goal_accounts.build(account:)

      baseline = [ account.balance.to_d, 0.to_d ].max
      goal.target_amount = baseline + target_amount
      goal.save!

      @enrollment = current_resource_owner.family.savings_challenge_enrollments.create!(
        goal:,
        campaign_key: SavingsChallenge::Campaign::KEY,
        target_amount:,
        starting_balance: [ goal.current_balance.to_d, 0.to_d ].max,
        joined_at: Time.current
      )
    end

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_validation_error(error.record.errors.full_messages.to_sentence)
  rescue ArgumentError => error
    render_validation_error(error.message)
  end

  private
    def enrollment_scope
      current_resource_owner.family.savings_challenge_enrollments
                            .where(campaign_key: SavingsChallenge::Campaign::KEY)
    end

    def challenge_input
      params.require(:challenge).permit(:target_amount, :account_id)
    end

    def fundable_accounts
      current_resource_owner.family.accounts
                            .accessible_by(current_resource_owner)
                            .visible
                            .where(accountable_type: "Depository")
    end

    def valid_uuid!(value)
      raise ArgumentError, "Choose a valid savings account." unless valid_uuid?(value)

      value
    end

    def positive_amount!(value)
      amount = BigDecimal(value.to_s, exception: false)
      raise ArgumentError, "Enter a valid savings target." unless amount
      raise ArgumentError, "Enter a savings target greater than zero." unless amount.positive?

      amount
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def render_validation_error(message)
      render json: {
        error: "validation_failed",
        message:,
        errors: [ message ]
      }, status: :unprocessable_entity
    end
end
