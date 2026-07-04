# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionSplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @user.api_keys.active.destroy_all
    @read_write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    @read_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @entry = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: @account
    )
    @transaction = @entry.transaction
  end

  test "creates split transaction lines" do
    assert_difference("Entry.count", 2) do
      post api_v1_transaction_split_url(@transaction),
           params: {
             split: {
               splits: [
                 { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id },
                 { name: "Household", amount: "-30", category_id: "" }
               ]
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("split", "parent")
    assert_equal 2, response_data.dig("split", "lines").size
    assert @entry.reload.excluded?
  end

  test "shows split details" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get api_v1_transaction_split_url(@transaction), headers: api_headers(@read_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("split", "parent")
    assert_equal 2, response_data.dig("split", "lines").size
  end

  test "rejects mismatched split amounts" do
    assert_no_difference("Entry.count") do
      post api_v1_transaction_split_url(@transaction),
           params: {
             split: {
               splits: [
                 { name: "Part 1", amount: "-60" },
                 { name: "Part 2", amount: "-20" }
               ]
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "updates existing split lines" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch api_v1_transaction_split_url(@transaction),
          params: {
            split: {
              splits: [
                { name: "Food", amount: "-50", category_id: categories(:food_and_drink).id },
                { name: "Transport", amount: "-30" },
                { name: "Other", amount: "-20" }
              ]
            }
          },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 3, response_data.dig("split", "lines").size
    assert_equal 3, @entry.reload.child_entries.count
  end

  test "destroys split from child transaction id" do
    children = @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    child_transaction = children.first.transaction

    assert_difference("Entry.count", -2) do
      delete api_v1_transaction_split_url(child_transaction), headers: api_headers(@read_write_api_key)
    end

    assert_response :success
    assert_not @entry.reload.excluded?
    assert_not @entry.split_parent?
  end

  test "rejects split mutation with read-only api key" do
    post api_v1_transaction_split_url(@transaction),
         params: {
           split: {
             splits: [
               { name: "Groceries", amount: "-70" },
               { name: "Household", amount: "-30" }
             ]
           }
         },
         headers: api_headers(@read_api_key)

    assert_response :forbidden
  end
end
