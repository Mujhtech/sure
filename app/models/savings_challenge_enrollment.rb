# frozen_string_literal: true

class SavingsChallengeEnrollment < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :goal

  validates :campaign_key, presence: true, uniqueness: { scope: :family_id }
  validates :target_amount, numericality: { greater_than: 0 }
  validates :starting_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :joined_at, presence: true
  validate :goal_belongs_to_family

  monetize :target_amount, :starting_balance

  def current_saved_amount
    [ goal.current_balance.to_d - starting_balance.to_d, 0.to_d ].max
  end

  def current_saved_amount_money
    Money.new(current_saved_amount, currency)
  end

  def progress_percent
    return 0 unless target_amount.to_d.positive?

    ((current_saved_amount / target_amount.to_d) * 100).round.clamp(0, 100)
  end

  def completed?
    current_saved_amount >= target_amount
  end

  def currency
    goal.currency
  end

  private
    def goal_belongs_to_family
      return if goal.nil? || family.nil? || goal.family_id == family_id

      errors.add(:goal, "must belong to the same family")
    end
end
