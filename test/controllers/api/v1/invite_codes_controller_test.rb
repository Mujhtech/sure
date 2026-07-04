# frozen_string_literal: true

require "test_helper"

class Api::V1::InviteCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    InviteCode.destroy_all

    @super_admin = users(:sure_support_staff)
    @family_admin = users(:family_admin)
    @super_admin.api_keys.active.destroy_all
    @family_admin.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @super_admin,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @super_admin,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @family_admin_api_key = ApiKey.create!(
      user: @family_admin,
      name: "Family Admin Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "family_admin_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
    Redis.new.del("api_rate_limit:#{@family_admin_api_key.id}")
  end

  test "lists invite codes for super admin" do
    invite_code = InviteCode.create!

    get api_v1_invite_codes_url, headers: api_headers(@read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal [ invite_code.id ], response_body["invite_codes"].map { |code| code["id"] }
    assert_equal invite_code.token, response_body.dig("invite_codes", 0, "token")
  end

  test "creates invite code for super admin" do
    assert_difference("InviteCode.count", 1) do
      post api_v1_invite_codes_url, headers: api_headers(@api_key)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal InviteCode.last.id, response_body.dig("invite_code", "id")
    assert_equal InviteCode.last.token, response_body.dig("invite_code", "token")
  end

  test "deletes invite code for super admin" do
    invite_code = InviteCode.create!

    assert_difference("InviteCode.count", -1) do
      delete api_v1_invite_code_url(invite_code), headers: api_headers(@api_key)
    end

    assert_response :success
    assert_equal "Invite code deleted successfully", JSON.parse(response.body)["message"]
  end

  test "rejects create with read only key" do
    assert_no_difference("InviteCode.count") do
      post api_v1_invite_codes_url, headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
  end

  test "rejects non super admin" do
    get api_v1_invite_codes_url, headers: api_headers(@family_admin_api_key)

    assert_response :forbidden
    assert_equal "Invite codes can only be managed by a super admin", JSON.parse(response.body)["message"]
  end

  test "rejects when not self hosted" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)

    get api_v1_invite_codes_url, headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_equal "Invite codes are only available in self-hosted mode", JSON.parse(response.body)["message"]
  end

  test "returns not found for missing invite code" do
    delete "/api/v1/invite_codes/#{SecureRandom.uuid}", headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication" do
    get api_v1_invite_codes_url

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
