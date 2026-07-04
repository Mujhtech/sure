# frozen_string_literal: true

class CreateMobileDeltaSyncTables < ActiveRecord::Migration[7.2]
  def change
    create_table :mobile_sync_events do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :entity_type, null: false
      t.uuid :entity_id
      t.string :operation, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :mobile_sync_events, [ :family_id, :id ], name: "idx_mobile_sync_events_family_revision"
    add_index :mobile_sync_events, [ :family_id, :entity_type, :entity_id ], name: "idx_mobile_sync_events_entity"
    add_index :mobile_sync_events, :occurred_at, name: "idx_mobile_sync_events_occurred_at"

    create_table :mobile_sync_operations, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.references :mobile_device, type: :uuid, foreign_key: true
      t.string :client_change_id, null: false
      t.string :entity_type, null: false
      t.string :entity_id
      t.string :operation, null: false
      t.string :status, null: false, default: "pending"
      t.bigint :base_revision
      t.jsonb :request_payload, null: false, default: {}
      t.jsonb :response_payload, null: false, default: {}
      t.text :error_message
      t.datetime :processed_at

      t.timestamps
    end

    add_index :mobile_sync_operations, [ :family_id, :client_change_id ], unique: true, name: "idx_mobile_sync_ops_client_change"
    add_index :mobile_sync_operations, [ :family_id, :status ], name: "idx_mobile_sync_ops_status"
    add_index :mobile_sync_operations, [ :family_id, :entity_type, :entity_id ], name: "idx_mobile_sync_ops_entity"
  end
end
