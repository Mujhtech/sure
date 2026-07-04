# frozen_string_literal: true

require "test_helper"

class Api::V1::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_user = users(:family_member)

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "MCP Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "mcp_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "MCP Read Key",
      scopes: [ "read" ],
      display_key: "mcp_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @application = Doorkeeper::Application.create!(
      name: "Claude #{SecureRandom.hex(4)}",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    @token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: @application,
      resource_owner_id: @user.id,
      scopes: "read_write",
      expires_in: 1.year
    )

    @mobile_device = MobileDevice.create!(
      user: @user,
      device_id: "mcp-test-device-#{SecureRandom.hex(4)}",
      device_name: "Test iPhone",
      device_type: "ios"
    )
    @mobile_token = Doorkeeper::AccessToken.create!(
      application: @application,
      resource_owner_id: @user.id,
      mobile_device_id: @mobile_device.id,
      scopes: "read_write",
      expires_in: 1.year
    )
    @other_user_token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: @application,
      resource_owner_id: @other_user.id,
      scopes: "read_write",
      expires_in: 1.year
    )
  end

  test "shows MCP URL and connected non-mobile tokens" do
    get "/api/v1/mcp", headers: api_headers(@read_only_api_key)

    assert_response :success

    response_data = response_body
    assert_match %r{/mcp\z}, response_data["mcp_url"]
    token_ids = response_data["connected_tokens"].map { |token| token["id"] }
    assert_includes token_ids, @token.id
    assert_not_includes token_ids, @mobile_token.id
    assert_not_includes token_ids, @other_user_token.id

    token_payload = response_data["connected_tokens"].find { |token| token["id"] == @token.id }
    assert_equal @application.name, token_payload.dig("application", "name")
    assert_equal %w[read_write], token_payload["scopes"]
    assert_nil token_payload["revoked_at"]
    assert_not token_payload.key?("token")
    assert_not token_payload.key?("refresh_token")
  end

  test "revokes own MCP token with write scope" do
    delete "/api/v1/mcp/tokens/#{@token.id}", headers: api_headers(@api_key)

    assert_response :success

    response_data = response_body
    assert_equal "MCP token revoked", response_data["message"]
    assert_equal @token.id, response_data.dig("token", "id")
    assert @token.reload.revoked_at.present?
  end

  test "rejects token revocation with read only key" do
    delete "/api/v1/mcp/tokens/#{@token.id}", headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_nil @token.reload.revoked_at
  end

  test "does not revoke another user's MCP token" do
    delete "/api/v1/mcp/tokens/#{@other_user_token.id}", headers: api_headers(@api_key)

    assert_response :not_found
    assert_nil @other_user_token.reload.revoked_at
  end

  private

    def response_body
      JSON.parse(response.body)
    end
end
