# frozen_string_literal: true

require "test_helper"

class Api::V1::GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "Goals Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "goals_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Goals Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "goals_rw_#{SecureRandom.hex(8)}"
    )

    @goal = goals(:vacation_italy)
    @account = accounts(:investment)
  end

  test "lists goals scoped to the current family" do
    get api_v1_goals_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("goals")
    assert response_data.key?("pagination")
    assert_includes response_data["goals"].map { |goal| goal["id"] }, @goal.id

    goal_payload = response_data["goals"].find { |goal| goal["id"] == @goal.id }
    assert_equal "active", goal_payload["state"]
    assert_kind_of Integer, goal_payload["target_amount_cents"]
    assert goal_payload.key?("linked_accounts")
    assert goal_payload.key?("open_pledges")
  end

  test "filters goals by state" do
    get api_v1_goals_url, params: { state: "paused" }, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ goals(:car_paydown).id ], response_data["goals"].map { |goal| goal["id"] }
  end

  test "shows a goal" do
    get api_v1_goal_url(@goal), headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @goal.id, response_data["id"]
    assert_equal @goal.name, response_data["name"]
    assert response_data["available_events"].key?("pause")
  end

  test "creates a goal with linked account allocation" do
    assert_difference("@family.goals.count", 1) do
      post api_v1_goals_url,
           params: {
             goal: {
               name: "New mobile goal",
               target_amount: 1200,
               target_date: 6.months.from_now.to_date.to_s,
               color: "#4da568",
               icon: "target",
               account_ids: [ @account.id ],
               allocations: { @account.id => "500" }
             }
           },
           headers: api_headers(@write_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "New mobile goal", response_data["name"]
    assert_equal @account.id, response_data["linked_accounts"].first["id"]
    assert_equal 50000, response_data["linked_accounts"].first["allocated_amount_cents"]
  end

  test "rejects create with read only key" do
    post api_v1_goals_url,
         params: { goal: { name: "Blocked", target_amount: 100, account_ids: [ @account.id ] } },
         headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "updates goal and linked accounts" do
    patch api_v1_goal_url(@goal),
          params: {
            goal: {
              name: "Updated vacation",
              account_ids: [ @account.id ],
              allocations: { @account.id => "" }
            }
          },
          headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Updated vacation", response_data["name"]
    assert_equal [ @account.id ], response_data["linked_accounts"].map { |account| account["id"] }
    assert_equal true, response_data["linked_accounts"].first["whole_account"]
  end

  test "transitions a goal" do
    patch pause_api_v1_goal_url(@goal), headers: api_headers(@write_key)

    assert_response :success
    assert_equal "paused", JSON.parse(response.body)["state"]

    patch resume_api_v1_goal_url(@goal), headers: api_headers(@write_key)

    assert_response :success
    assert_equal "active", JSON.parse(response.body)["state"]
  end

  test "requires archived goal before destroy" do
    assert_no_difference("@family.goals.count") do
      delete api_v1_goal_url(@goal), headers: api_headers(@write_key)
    end

    assert_response :unprocessable_entity
  end

  test "destroys archived goal" do
    archived_goal = @family.goals.create!(
      name: "Archived mobile goal",
      target_amount: 100,
      currency: "USD",
      state: "archived",
      goal_accounts: [ GoalAccount.new(account: @account) ]
    )

    assert_difference("@family.goals.count", -1) do
      delete api_v1_goal_url(archived_goal), headers: api_headers(@write_key)
    end

    assert_response :ok
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
