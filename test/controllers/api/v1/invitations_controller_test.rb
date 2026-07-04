# frozen_string_literal: true

require "test_helper"

class Api::V1::InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @admin_read_key = ApiKey.create!(
      user: @admin,
      name: "Invitations Read",
      scopes: [ "read" ],
      display_key: "invitations_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @admin_write_key = ApiKey.create!(
      user: @admin,
      name: "Invitations Write",
      scopes: [ "read_write" ],
      display_key: "invitations_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @member_write_key = ApiKey.create!(
      user: @member,
      name: "Invitations Member Write",
      scopes: [ "read_write" ],
      display_key: "invitations_member_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    [ @admin_read_key, @admin_write_key, @member_write_key ].each do |api_key|
      redis.del("api_rate_limit:#{api_key.id}")
    end
    redis.close
  end

  test "lists pending invitations" do
    invitation = @family.invitations.create!(
      email: "pending-invite@example.com",
      role: "member",
      inviter: @admin
    )

    get api_v1_invitations_url, headers: api_headers(@admin_read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    invitation_ids = response_data["invitations"].map { |pending_invitation| pending_invitation["id"] }
    assert_includes invitation_ids, invitation.id
  end

  test "admin creates invitation" do
    assert_difference("@family.invitations.count", 1) do
      post api_v1_invitations_url,
           params: { invitation: { email: "new-mobile-member@example.com", role: "member" } },
           headers: api_headers(@admin_write_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "new-mobile-member@example.com", response_data["email"]
    assert_equal "member", response_data["role"]
    assert_equal true, response_data["pending"]
  end

  test "shows invitation accept details without authentication" do
    invitation = @family.invitations.create!(
      email: "mobile-invite-preview@example.com",
      role: "member",
      inviter: @admin
    )

    get "/api/v1/invitations/accept/#{invitation.token}"

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal invitation.id, response_data["id"]
    assert_equal @family.id, response_data.dig("family", "id")
    assert_equal @family.name, response_data.dig("family", "name")
    assert_equal false, response_data["accepted_existing_user"]
    assert_nil response_data["token"]
  end

  test "accept details returns not found for invalid token" do
    get "/api/v1/invitations/accept/not-a-real-token"

    assert_response :not_found
  end

  test "existing user accepts invitation by token" do
    existing_user = users(:empty)
    existing_user.api_keys.active.destroy_all
    existing_user_key = ApiKey.create!(
      user: existing_user,
      name: "Invitation Accept",
      scopes: [ "read_write" ],
      display_key: "invitation_accept_#{SecureRandom.hex(8)}",
      source: "mobile"
    )
    invitation = @family.invitations.create!(
      email: existing_user.email,
      role: "member",
      inviter: @admin
    )

    assert_difference("@family.users.count", 1) do
      post "/api/v1/invitations/accept/#{invitation.token}", headers: api_headers(existing_user_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal true, response_data["accepted_existing_user"]
    assert_equal false, response_data["pending"]
    assert_equal @family.id, existing_user.reload.family_id
    assert_equal "member", existing_user.role
    assert invitation.reload.accepted_at.present?
  end

  test "accept rejects mismatched user email" do
    invitation = @family.invitations.create!(
      email: "someone-else@example.com",
      role: "member",
      inviter: @admin
    )

    post "/api/v1/invitations/accept/#{invitation.token}", headers: api_headers(@member_write_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_nil invitation.reload.accepted_at
  end

  test "admin invitation accepts existing safe user" do
    existing_user = users(:empty)

    assert_difference("@family.users.count", 1) do
      post api_v1_invitations_url,
           params: { invitation: { email: existing_user.email, role: "member" } },
           headers: api_headers(@admin_write_key)
    end

    assert_response :success
    assert_equal @family.id, existing_user.reload.family_id
    assert_equal true, JSON.parse(response.body)["accepted_existing_user"]
  end

  test "create returns validation errors" do
    assert_no_difference("@family.invitations.count") do
      post api_v1_invitations_url,
           params: { invitation: { email: "not-an-email", role: "member" } },
           headers: api_headers(@admin_write_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "non-admin cannot create invitation" do
    assert_no_difference("@family.invitations.count") do
      post api_v1_invitations_url,
           params: { invitation: { email: "blocked@example.com", role: "member" } },
           headers: api_headers(@member_write_key)
    end

    assert_response :forbidden
  end

  test "read-only key cannot create invitation" do
    assert_no_difference("@family.invitations.count") do
      post api_v1_invitations_url,
           params: { invitation: { email: "blocked@example.com", role: "member" } },
           headers: api_headers(@admin_read_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "admin deletes invitation" do
    invitation = @family.invitations.create!(
      email: "delete-invite@example.com",
      role: "member",
      inviter: @admin
    )

    assert_difference("@family.invitations.count", -1) do
      delete api_v1_invitation_url(invitation), headers: api_headers(@admin_write_key)
    end

    assert_response :success
    assert_equal "Invitation deleted successfully", JSON.parse(response.body)["message"]
  end

  test "delete returns not found for another family invitation" do
    other_invitation = families(:empty).invitations.create!(
      email: "other-family@example.com",
      role: "member",
      inviter: users(:empty)
    )

    delete api_v1_invitation_url(other_invitation), headers: api_headers(@admin_write_key)

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
