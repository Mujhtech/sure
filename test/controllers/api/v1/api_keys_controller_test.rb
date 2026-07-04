# frozen_string_literal: true

require "test_helper"

class Api::V1::ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_user = users(:empty)
    @user.api_keys.active.destroy_all
    @other_user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "API Keys Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "api_keys_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "API Keys Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "api_keys_write_#{SecureRandom.hex(8)}"
    )
    @other_key = ApiKey.create!(
      user: @other_user,
      name: "Other User Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "api_keys_other_#{SecureRandom.hex(8)}"
    )
  end

  test "index requires authentication" do
    get api_v1_api_keys_url

    assert_response :unauthorized
  end

  test "index lists active visible keys for the current user without secrets" do
    revoked_key = ApiKey.create!(
      user: @user,
      name: "Revoked Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "api_keys_revoked_#{SecureRandom.hex(8)}"
    )
    revoked_key.revoke!

    get api_v1_api_keys_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    api_keys = response_data["api_keys"]
    api_key_ids = api_keys.map { |api_key| api_key["id"] }

    assert_includes api_key_ids, @read_key.id
    assert_includes api_key_ids, @write_key.id
    assert_not_includes api_key_ids, @other_key.id
    assert_not_includes api_key_ids, revoked_key.id
    assert_equal %w[read read_write], response_data.dig("options", "scopes")

    read_payload = api_keys.find { |api_key| api_key["id"] == @read_key.id }
    assert_equal "API Keys Read Key", read_payload["name"]
    assert_equal [ "read" ], read_payload["scopes"]
    assert_equal "mobile", read_payload["source"]
    assert_equal true, read_payload["active"]
    assert_equal true, read_payload["current"]
    assert read_payload["last_used_at"].present?
    assert_not read_payload.key?("plain_key")
    assert_not read_payload.key?("display_key")
  end

  test "show returns one API key without the stored secret" do
    get api_v1_api_key_url(@write_key), headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    payload = response_data["api_key"]

    assert_equal @write_key.id, payload["id"]
    assert_equal "API Keys Write Key", payload["name"]
    assert_equal [ "read_write" ], payload["scopes"]
    assert_equal false, payload["current"]
    assert_not payload.key?("plain_key")
    assert_not payload.key?("display_key")
  end

  test "show returns not found for another user's API key" do
    get api_v1_api_key_url(@other_key), headers: api_headers(@read_key)

    assert_response :not_found
  end

  test "create requires write scope" do
    assert_no_difference("ApiKey.count") do
      post api_v1_api_keys_url,
           params: { api_key: { name: "Blocked", scopes: "read" } },
           headers: api_headers(@read_key)
    end

    assert_response :forbidden
  end

  test "create returns the new plain key once" do
    assert_difference -> { @user.api_keys.count }, 1 do
      post api_v1_api_keys_url,
           params: { api_key: { name: "Native App Key", scopes: "read" } },
           headers: api_headers(@write_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    payload = response_data["api_key"]

    assert_equal "Native App Key", payload["name"]
    assert_equal [ "read" ], payload["scopes"]
    assert_equal "mobile", payload["source"]
    assert payload["plain_key"].present?
    assert_equal ApiKey.find_by_value(payload["plain_key"]).id, payload["id"]
  end

  test "create returns validation errors" do
    assert_no_difference("ApiKey.count") do
      post api_v1_api_keys_url,
           params: { api_key: { name: "", scopes: "read" } },
           headers: api_headers(@write_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert response_data["errors"].present?
  end

  test "destroy requires write scope" do
    delete api_v1_api_key_url(@write_key), headers: api_headers(@read_key)

    assert_response :forbidden
    assert_not @write_key.reload.revoked?
  end

  test "destroy revokes the selected API key" do
    delete api_v1_api_key_url(@read_key), headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "API key revoked", response_data["message"]
    assert_equal @read_key.id, response_data.dig("api_key", "id")
    assert_equal false, response_data.dig("api_key", "active")
    assert @read_key.reload.revoked?
    assert_not @write_key.reload.revoked?
  end
end
