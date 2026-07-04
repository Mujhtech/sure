# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountSharingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family
    @account = @family.accounts.create!(
      owner: @owner,
      name: "API Sharing Checking",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )

    @owner.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @owner_read_key = ApiKey.create!(
      user: @owner,
      name: "Sharing Owner Read",
      scopes: [ "read" ],
      display_key: "sharing_owner_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @owner_write_key = ApiKey.create!(
      user: @owner,
      name: "Sharing Owner Write",
      scopes: [ "read_write" ],
      display_key: "sharing_owner_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @member_write_key = ApiKey.create!(
      user: @member,
      name: "Sharing Member Write",
      scopes: [ "read_write" ],
      display_key: "sharing_member_write_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    [ @owner_read_key, @owner_write_key, @member_write_key ].each do |api_key|
      redis.del("api_rate_limit:#{api_key.id}")
    end
    redis.close
  end

  test "owner can view account sharing state" do
    get "/api/v1/accounts/#{@account.id}/sharing", headers: api_headers(@owner_read_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @account.id, response_data["account"]["id"]
    assert_equal true, response_data["account"]["owned_by_current_user"]
    assert_equal "owner", response_data["account"]["current_user_permission"]
    assert_includes response_data["permissions"], "read_only"

    member = response_data["family_members"].find { |family_member| family_member["id"] == @member.id }
    assert_not_nil member
    assert_equal false, member["share"]["shared"]
  end

  test "owner can create and update member account share" do
    patch "/api/v1/accounts/#{@account.id}/sharing",
          params: {
            sharing: {
              members: [
                { user_id: @member.id, shared: true, permission: "read_write" }
              ]
            }
          },
          headers: api_headers(@owner_write_key)

    assert_response :success
    share = @account.account_shares.find_by!(user: @member)
    assert_equal "read_write", share.permission
    assert_equal true, share.include_in_finances?

    response_data = JSON.parse(response.body)
    member = response_data["family_members"].find { |family_member| family_member["id"] == @member.id }
    assert_equal true, member["share"]["shared"]
    assert_equal "read_write", member["share"]["permission"]

    patch "/api/v1/accounts/#{@account.id}/sharing",
          params: {
            sharing: {
              members: [
                { user_id: @member.id, shared: true, permission: "full_control" }
              ]
            }
          },
          headers: api_headers(@owner_write_key)

    assert_response :success
    assert_equal "full_control", share.reload.permission
  end

  test "owner can remove member account share" do
    @account.share_with!(@member, permission: "read_only")

    assert_difference("@account.account_shares.count", -1) do
      patch "/api/v1/accounts/#{@account.id}/sharing",
            params: {
              sharing: {
                members: [
                  { user_id: @member.id, shared: false }
                ]
              }
            },
            headers: api_headers(@owner_write_key)
    end

    assert_response :success
    assert_nil @account.account_shares.find_by(user: @member)
  end

  test "owner update ignores users outside the family" do
    outsider = users(:empty)

    assert_no_difference("@account.account_shares.count") do
      patch "/api/v1/accounts/#{@account.id}/sharing",
            params: {
              sharing: {
                members: [
                  { user_id: outsider.id, shared: true, permission: "read_only" }
                ]
              }
            },
            headers: api_headers(@owner_write_key)
    end

    assert_response :success
  end

  test "read-only api key cannot update sharing" do
    patch "/api/v1/accounts/#{@account.id}/sharing",
          params: {
            sharing: {
              members: [
                { user_id: @member.id, shared: true, permission: "read_only" }
              ]
            }
          },
          headers: api_headers(@owner_read_key)

    assert_response :forbidden
    assert_nil @account.account_shares.find_by(user: @member)
  end

  test "shared user can update own finance inclusion" do
    share = @account.share_with!(@member, permission: "read_only")

    patch "/api/v1/accounts/#{@account.id}/sharing",
          params: { sharing: { include_in_finances: false } },
          headers: api_headers(@member_write_key)

    assert_response :success
    assert_equal false, share.reload.include_in_finances?

    response_data = JSON.parse(response.body)
    assert_equal share.id, response_data["current_user_share"]["id"]
    assert_equal false, response_data["current_user_share"]["include_in_finances"]
  end

  test "shared user cannot update account members" do
    @account.share_with!(@member, permission: "read_write")

    patch "/api/v1/accounts/#{@account.id}/sharing",
          params: {
            sharing: {
              members: [
                { user_id: @member.id, shared: true, permission: "full_control" }
              ]
            }
          },
          headers: api_headers(@member_write_key)

    assert_response :forbidden
    assert_equal "read_write", @account.account_shares.find_by!(user: @member).permission
  end

  test "returns not found for inaccessible account" do
    other_family_account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Other Family Sharing",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    get "/api/v1/accounts/#{other_family_account.id}/sharing", headers: api_headers(@owner_read_key)

    assert_response :not_found
  end

  test "returns not found for malformed account id" do
    get "/api/v1/accounts/not-a-uuid/sharing", headers: api_headers(@owner_read_key)

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
