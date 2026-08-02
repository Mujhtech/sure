require "test_helper"

class Assistant::Function::CreateTransactionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateTransaction.new(@user)
    @account = accounts(:depository)
    @category = @family.categories.first
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "create_transaction", definition[:name]
    assert_equal %w[account name amount nature], definition[:params_schema][:required]
  end

  test "creates an expense with positive signed amount" do
    result = nil

    assert_difference "@account.entries.count" do
      result = @fn.call(
        "account" => @account.name,
        "name" => "Dinner at Nobu",
        "amount" => 40.5,
        "nature" => "expense",
        "category" => @category.name,
        "notes" => "Team dinner"
      )
    end

    assert result[:success], result[:message]
    entry = @account.entries.find(result[:transaction][:entry_id])
    assert_equal 40.5, entry.amount
    assert_equal Date.current, entry.date
    assert_equal @category.id, entry.transaction.category_id
    assert_equal "Team dinner", entry.notes
    assert_equal "expense", result[:transaction][:nature]
  end

  test "creates income with negative signed amount and explicit date" do
    result = @fn.call(
      "account" => @account.name,
      "name" => "Freelance payment",
      "amount" => 500,
      "nature" => "income",
      "date" => "2026-07-15"
    )

    assert result[:success], result[:message]
    entry = @account.entries.find(result[:transaction][:entry_id])
    assert_equal(-500, entry.amount)
    assert_equal Date.new(2026, 7, 15), entry.date
    assert_equal "income", result[:transaction][:nature]
  end

  test "resolves account case-insensitively and rejects unknown accounts" do
    result = @fn.call("account" => @account.name.upcase, "name" => "x", "amount" => 1, "nature" => "expense")
    assert result[:success], result[:message]

    result = @fn.call("account" => "No Such Account", "name" => "x", "amount" => 1, "nature" => "expense")
    assert_not result[:success]
    assert_equal "account_not_found", result[:error]
    assert_includes result[:message], @account.name
  end

  test "rejects non-positive amount and invalid date" do
    result = @fn.call("account" => @account.name, "name" => "x", "amount" => 0, "nature" => "expense")
    assert_equal "invalid_amount", result[:error]

    result = @fn.call("account" => @account.name, "name" => "x", "amount" => 5, "nature" => "expense", "date" => "bad")
    assert_equal "invalid_date", result[:error]
  end

  test "rejects unknown category and tag" do
    result = @fn.call("account" => @account.name, "name" => "x", "amount" => 5, "nature" => "expense", "category" => "Nope")
    assert_equal "category_not_found", result[:error]

    result = @fn.call("account" => @account.name, "name" => "x", "amount" => 5, "nature" => "expense", "tags" => [ "Nope" ])
    assert_equal "tag_not_found", result[:error]
  end

  test "enqueues account sync after creation" do
    assert_enqueued_with(job: SyncJob) do
      @fn.call("account" => @account.name, "name" => "Synced", "amount" => 5, "nature" => "expense")
    end
  end
end
