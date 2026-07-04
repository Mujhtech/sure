# frozen_string_literal: true

require "test_helper"

class Api::V1::Admin::InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @super_admin = users(:sure_support_staff)
    @family_admin = users(:family_admin)
    @family = @family_admin.family

    @super_admin.api_keys.active.destroy_all
    @family_admin.api_keys.active.destroy_all

    @write_key = ApiKey.create!(
      user: @super_admin,
      name: "Admin Invitations Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "admin_invites_write_#{SecureRandom.hex(8)}"
    )
    @read_key = ApiKey.create!(
      user: @super_admin,
      name: "Admin Invitations Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "admin_invites_read_#{SecureRandom.hex(8)}"
    )
    @family_admin_key = ApiKey.create!(
      user: @family_admin,
      name: "Admin Invitations Forbidden Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "admin_invites_forbidden_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@write_key.id}")
    Redis.new.del("api_rate_limit:#{@read_key.id}")
    Redis.new.del("api_rate_limit:#{@family_admin_key.id}")
  end

  test "super admin deletes an invitation" do
    invitation = create_invitation("single-delete@example.com")

    assert_difference("Invitation.count", -1) do
      delete api_v1_admin_invitation_url(invitation), headers: api_headers(@write_key)
    end

    assert_response :success
    assert_equal invitation.id, response_body["invitation_id"]
  end

  test "super admin deletes all pending invitations for a family" do
    create_invitation("first-delete-all@example.com")
    create_invitation("second-delete-all@example.com")

    accepted = create_invitation("accepted-delete-all@example.com")
    accepted.update!(accepted_at: Time.current)

    assert_difference("Invitation.pending.where(family: @family).count", -2) do
      delete invitations_api_v1_admin_family_url(@family), headers: api_headers(@write_key)
    end

    assert_response :success
    assert_equal 2, response_body["deleted_count"]
    assert Invitation.exists?(accepted.id)
  end

  test "read only key cannot delete invitations" do
    invitation = create_invitation("read-only-delete@example.com")

    assert_no_difference("Invitation.count") do
      delete api_v1_admin_invitation_url(invitation), headers: api_headers(@read_key)
    end

    assert_response :forbidden
  end

  test "non super admins cannot delete invitations" do
    invitation = create_invitation("non-super-delete@example.com")

    delete api_v1_admin_invitation_url(invitation), headers: api_headers(@family_admin_key)

    assert_response :forbidden
    assert_equal "Invitations can only be managed by a super admin", response_body["message"]
  end

  test "returns not found for missing invitation" do
    delete "/api/v1/admin/invitations/#{SecureRandom.uuid}", headers: api_headers(@write_key)

    assert_response :not_found
  end

  private

    def create_invitation(email)
      Invitation.create!(
        family: @family,
        inviter: @family_admin,
        email: email,
        role: "member"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def response_body
      JSON.parse(response.body)
    end
end
