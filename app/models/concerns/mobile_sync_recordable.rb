# frozen_string_literal: true

module MobileSyncRecordable
  extend ActiveSupport::Concern

  class_methods do
    def record_mobile_sync_events_as(entity_type, family: nil, entity_id: nil)
      after_create_commit do
        record_mobile_sync_event(entity_type, "upsert", family, entity_id)
      end

      after_update_commit do
        record_mobile_sync_event(entity_type, "upsert", family, entity_id)
      end

      after_destroy_commit do
        record_mobile_sync_event(entity_type, "delete", family, entity_id)
      end
    end
  end

  private

    def record_mobile_sync_event(entity_type, operation, family_method, entity_id_method)
      family = family_method ? public_send(family_method) : self.family
      entity_id = entity_id_method ? public_send(entity_id_method) : id

      MobileSyncEvent.record!(
        family: family,
        entity_type: entity_type,
        entity_id: entity_id,
        operation: operation
      )
    rescue StandardError => e
      Rails.logger.warn("Mobile sync event could not be recorded for #{self.class.name} #{id}: #{e.message}")
    end
end
