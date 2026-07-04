# frozen_string_literal: true

class MobileSyncOperation < ApplicationRecord
  ENTITY_TYPES = %w[transaction].freeze
  OPERATIONS = %w[create update delete].freeze
  STATUSES = %w[pending accepted rejected conflict].freeze

  belongs_to :family
  belongs_to :user
  belongs_to :mobile_device, optional: true

  validates :client_change_id, presence: true, uniqueness: { scope: :family_id }
  validates :entity_type, presence: true, inclusion: { in: ENTITY_TYPES }
  validates :operation, presence: true, inclusion: { in: OPERATIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }

  def terminal?
    status.in?(%w[accepted rejected conflict])
  end
end
