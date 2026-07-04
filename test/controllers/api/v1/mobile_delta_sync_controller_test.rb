# frozen_string_literal: true

require "test_helper"

class Api::V1::MobileDeltaSyncControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:empty)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Mobile Delta Sync Test Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "mobile_delta_sync_#{SecureRandom.hex(8)}"
    )

    @account = @family.accounts.create!(
      name: "Mobile Delta Checking",
      balance: 0,
      currency: "USD",
      classification: "asset",
      accountable: Depository.create!,
      owner: @user
    )
  end

  test "returns an initial local cache snapshot" do
    post api_v1_mobile_delta_sync_url, params: {
      device_id: "ios-test-device",
      cursor: nil,
      changes: []
    }, headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)

    assert body["next_cursor"].present?
    assert_equal [], body["accepted"]
    assert_includes body.dig("changes", "accounts").map { |account| account["id"] }, @account.id
    assert body.dig("changes", "transactions").is_a?(Array)
    assert body.dig("changes", "categories").is_a?(Array)
    assert body.dig("changes", "merchants").is_a?(Array)
    assert body.dig("changes", "tags").is_a?(Array)
    assert_equal [], body.dig("changes", "deleted")
  end

  test "treats zero cursor as an incremental sync cursor" do
    MobileSyncEvent.where(family: @family).delete_all

    post api_v1_mobile_delta_sync_url, params: {
      device_id: "ios-test-device",
      cursor: "0",
      changes: []
    }, headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal "0", body["next_cursor"]
    assert_equal [], body.dig("changes", "accounts")
    assert_equal [], body.dig("changes", "transactions")
    assert_equal [], body.dig("changes", "categories")
    assert_equal [], body.dig("changes", "merchants")
    assert_equal [], body.dig("changes", "tags")
    assert_equal [], body.dig("changes", "deleted")
  end

  test "accepts manual transaction creates idempotently" do
    client_change_id = SecureRandom.uuid
    payload = {
      account_id: @account.id,
      date: Date.current.iso8601,
      amount: "42.50",
      nature: "expense",
      name: "Offline coffee",
      currency: "USD"
    }

    assert_difference("Transaction.count", 1) do
      post api_v1_mobile_delta_sync_url, params: {
        device_id: "ios-test-device",
        changes: [
          {
            client_change_id: client_change_id,
            entity_type: "transaction",
            entity_id: "local-#{client_change_id}",
            operation: "create",
            payload: payload
          }
        ]
      }, headers: api_headers(@api_key)
    end

    assert_response :success
    first_body = JSON.parse(response.body)
    accepted = first_body["accepted"].first
    assert_equal "accepted", accepted["status"]
    assert accepted["server_entity_id"].present?
    assert_equal "Offline coffee", accepted.dig("entity", "name")

    assert_no_difference("Transaction.count") do
      post api_v1_mobile_delta_sync_url, params: {
        device_id: "ios-test-device",
        cursor: first_body["next_cursor"],
        changes: [
          {
            client_change_id: client_change_id,
            entity_type: "transaction",
            entity_id: "local-#{client_change_id}",
            operation: "create",
            payload: payload
          }
        ]
      }, headers: api_headers(@api_key)
    end

    assert_response :success
    replay_body = JSON.parse(response.body)
    assert_equal accepted["server_entity_id"], replay_body["accepted"].first["server_entity_id"]
  end

  test "returns delete tombstones after cursor" do
    transaction = @account.entries.create!(
      name: "Offline delete",
      date: Date.current,
      amount: 12,
      currency: "USD",
      entryable: Transaction.new,
      source: "mobile_delta_sync",
      external_id: SecureRandom.uuid
    ).transaction

    post api_v1_mobile_delta_sync_url, params: {
      device_id: "ios-test-device",
      cursor: nil,
      changes: []
    }, headers: api_headers(@api_key)
    assert_response :success
    cursor = JSON.parse(response.body)["next_cursor"]

    post api_v1_mobile_delta_sync_url, params: {
      device_id: "ios-test-device",
      cursor: cursor,
      changes: [
        {
          client_change_id: SecureRandom.uuid,
          entity_type: "transaction",
          entity_id: transaction.id,
          operation: "delete",
          base_revision: cursor,
          payload: {}
        }
      ]
    }, headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "accepted", body["accepted"].first["status"]
    tombstones = body.dig("changes", "deleted")
    assert_includes tombstones.map { |tombstone| tombstone["entity_id"] }, transaction.id
  end

  test "rejects read-only keys" do
    read_only_key = ApiKey.create!(
      user: @user,
      name: "Mobile Delta Read Only",
      scopes: [ "read" ],
      source: "web",
      display_key: "mobile_delta_read_only_#{SecureRandom.hex(8)}"
    )

    post api_v1_mobile_delta_sync_url, params: {
      device_id: "ios-test-device",
      changes: []
    }, headers: api_headers(read_only_key)

    assert_response :forbidden
  end
end
