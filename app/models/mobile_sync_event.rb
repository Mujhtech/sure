# frozen_string_literal: true

class MobileSyncEvent < ApplicationRecord
  ENTITY_TYPES = %w[account transaction category merchant tag].freeze
  OPERATIONS = %w[upsert delete].freeze

  belongs_to :family

  validates :entity_type, presence: true, inclusion: { in: ENTITY_TYPES }
  validates :operation, presence: true, inclusion: { in: OPERATIONS }
  validates :occurred_at, presence: true

  before_validation :set_occurred_at, on: :create

  scope :after_revision, ->(revision) { where("id > ?", revision.to_i) }

  def self.record!(family:, entity_type:, entity_id:, operation:, metadata: {})
    return unless family

    create!(
      family: family,
      entity_type: entity_type,
      entity_id: entity_id,
      operation: operation,
      metadata: metadata || {},
      occurred_at: Time.current
    )
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.match?(/mobile_sync_events/i)

    Rails.logger.warn("Mobile sync event skipped because table is unavailable: #{e.message}")
  end

  def revision
    id
  end

  private

    def set_occurred_at
      self.occurred_at ||= Time.current
    end
end
