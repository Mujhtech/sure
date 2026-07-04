# frozen_string_literal: true

require "test_helper"

class Api::V1::GoalPledgesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "Goal Pledges Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "goal_pledges_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Goal Pledges Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "goal_pledges_rw_#{SecureRandom.hex(8)}"
    )

    @goal = goals(:vacation_italy)
    @account = accounts(:depository)
    @pledge = goal_pledges(:open_transfer)
  end

  test "creates a pledge for a linked account" do
    assert_difference("@goal.goal_pledges.count", 1) do
      post api_v1_goal_pledges_url(@goal),
           params: { goal_pledge: { account_id: @account.id, amount: 125 } },
           headers: api_headers(@write_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal @goal.id, response_data["goal_id"]
    assert_equal @account.id, response_data.dig("account", "id")
    assert_equal 12500, response_data["amount_cents"]
    assert_equal "open", response_data["status"]
  end

  test "rejects pledge create with read only key" do
    post api_v1_goal_pledges_url(@goal),
         params: { goal_pledge: { account_id: @account.id, amount: 125 } },
         headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "rejects pledge for account not linked to goal" do
    unlinked_account = accounts(:investment)

    post api_v1_goal_pledges_url(@goal),
         params: { goal_pledge: { account_id: unlinked_account.id, amount: 125 } },
         headers: api_headers(@write_key)

    assert_response :not_found
  end

  test "renews an open pledge" do
    original_expiration = @pledge.expires_at

    patch renew_api_v1_goal_pledge_url(@goal, @pledge), headers: api_headers(@write_key)

    assert_response :success
    @pledge.reload
    assert @pledge.expires_at > original_expiration
    assert_equal "open", JSON.parse(response.body)["status"]
  end

  test "cancels an open pledge on destroy" do
    delete api_v1_goal_pledge_url(@goal, @pledge), headers: api_headers(@write_key)

    assert_response :success
    assert_equal "cancelled", JSON.parse(response.body)["status"]
    assert_equal "cancelled", @pledge.reload.status
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
