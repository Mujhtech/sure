# frozen_string_literal: true

require "test_helper"

class Api::V1::FamilyMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @admin_read_key = ApiKey.create!(
      user: @admin,
      name: "Family Members Read",
      scopes: [ "read" ],
      display_key: "family_members_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @admin_write_key = ApiKey.create!(
      user: @admin,
      name: "Family Members Write",
      scopes: [ "read_write" ],
      display_key: "family_members_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @member_write_key = ApiKey.create!(
      user: @member,
      name: "Family Member Write",
      scopes: [ "read_write" ],
      display_key: "family_member_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    [ @admin_read_key, @admin_write_key, @member_write_key ].each do |api_key|
      redis.del("api_rate_limit:#{api_key.id}")
    end
    redis.close
  end

  test "lists family members and pending invitations" do
    invitation = @family.invitations.create!(
      email: "pending-member@example.com",
      role: "member",
      inviter: @admin
    )

    get api_v1_family_members_url, headers: api_headers(@admin_read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    member_ids = response_data["family_members"].map { |member| member["id"] }
    invitation_ids = response_data["pending_invitations"].map { |pending_invitation| pending_invitation["id"] }

    assert_includes member_ids, @admin.id
    assert_includes member_ids, @member.id
    assert_includes invitation_ids, invitation.id
  end

  test "admin removes a family member" do
    assert_difference("@family.users.count", -1) do
      delete api_v1_family_member_url(@member), headers: api_headers(@admin_write_key)
    end

    assert_response :success
    assert_equal "Family member removed successfully", JSON.parse(response.body)["message"]
  end

  test "admin cannot remove self" do
    assert_no_difference("@family.users.count") do
      delete api_v1_family_member_url(@admin), headers: api_headers(@admin_write_key)
    end

    assert_response :unprocessable_entity
    assert_equal "You cannot remove yourself from the family", JSON.parse(response.body)["message"]
  end

  test "non-admin cannot remove family member" do
    assert_no_difference("@family.users.count") do
      delete api_v1_family_member_url(@admin), headers: api_headers(@member_write_key)
    end

    assert_response :forbidden
  end

  test "read-only key cannot remove family member" do
    assert_no_difference("@family.users.count") do
      delete api_v1_family_member_url(@member), headers: api_headers(@admin_read_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
