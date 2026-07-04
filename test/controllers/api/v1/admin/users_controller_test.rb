# frozen_string_literal: true

require "test_helper"

class Api::V1::Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @super_admin = users(:sure_support_staff)
    @family_admin = users(:family_admin)
    @family_member = users(:family_member)

    @super_admin.api_keys.active.destroy_all
    @family_admin.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @super_admin,
      name: "Admin Users Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "admin_users_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @super_admin,
      name: "Admin Users Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "admin_users_write_#{SecureRandom.hex(8)}"
    )
    @family_admin_key = ApiKey.create!(
      user: @family_admin,
      name: "Admin Users Forbidden Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "admin_users_forbidden_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@read_key.id}")
    Redis.new.del("api_rate_limit:#{@write_key.id}")
    Redis.new.del("api_rate_limit:#{@family_admin_key.id}")
  end

  test "super admin lists users grouped by family with admin metadata" do
    family = @family_admin.family
    account = Account.create!(family: family, name: "Admin API Test", balance: 0, currency: "USD", accountable: Depository.new)
    3.times do |index|
      account.entries.create!(
        name: "Admin API Txn #{index}",
        date: Date.current,
        amount: 10,
        currency: "USD",
        entryable: Transaction.new
      )
    end

    invitation = Invitation.create!(
      family: family,
      inviter: @family_admin,
      email: "pending-admin-api@example.com",
      role: "member"
    )

    get api_v1_admin_users_url, headers: api_headers(@read_key)

    assert_response :success

    response_data = response_body
    family_payload = response_data["families"].find { |item| item["id"] == family.id }
    assert_equal 3, family_payload["entries_count"]
    assert_equal invitation.email, family_payload.dig("pending_invitations", 0, "email")
    assert_includes family_payload["users"].map { |user| user["id"] }, @family_admin.id
    assert_includes response_data.dig("filters", "roles"), "super_admin"
    assert response_data.dig("summary", "trials_expiring_in_7_days").is_a?(Integer)
  end

  test "super admin filters users by role" do
    get api_v1_admin_users_url,
        params: { role: "member" },
        headers: api_headers(@read_key)

    assert_response :success

    roles = response_body["families"].flat_map { |family| family["users"].map { |user| user["role"] } }
    assert roles.any?
    assert roles.all? { |role| role == "member" }
  end

  test "super admin updates another user's role" do
    patch api_v1_admin_user_url(@family_member),
          params: { user: { role: "admin" } },
          headers: api_headers(@write_key)

    assert_response :success
    assert_equal "admin", @family_member.reload.role
    assert_equal "User role updated successfully", response_body["message"]
    assert_equal "admin", response_body.dig("user", "role")
  end

  test "super admin cannot change their own role" do
    patch api_v1_admin_user_url(@super_admin),
          params: { user: { role: "member" } },
          headers: api_headers(@write_key)

    assert_response :forbidden
    assert_equal "You cannot change your own role", response_body["message"]
    assert_equal "super_admin", @super_admin.reload.role
  end

  test "read only key cannot update roles" do
    patch api_v1_admin_user_url(@family_member),
          params: { user: { role: "admin" } },
          headers: api_headers(@read_key)

    assert_response :forbidden
    assert_equal "member", @family_member.reload.role
  end

  test "non super admins cannot list users" do
    get api_v1_admin_users_url, headers: api_headers(@family_admin_key)

    assert_response :forbidden
    assert_equal "Users can only be managed by a super admin", response_body["message"]
  end

  test "invalid role filters return validation errors" do
    get api_v1_admin_users_url,
        params: { role: "owner" },
        headers: api_headers(@read_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response_body["error"]
  end

  test "requires authentication" do
    get api_v1_admin_users_url

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def response_body
      JSON.parse(response.body)
    end
end
