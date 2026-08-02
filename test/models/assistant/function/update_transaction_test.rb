require "test_helper"

class Assistant::Function::UpdateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::UpdateTransaction.new(@user)
    @entry = entries(:transaction)
    @transaction = @entry.transaction
    @category = @family.categories.first
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "update_transaction", definition[:name]
    assert_equal %w[transaction_id], definition[:params_schema][:required]
  end

  test "updates category by name" do
    result = @fn.call("transaction_id" => @transaction.id, "category" => @category.name)

    assert result[:success], result[:message]
    assert_equal @category.id, @transaction.reload.category_id
    assert_equal @category.name, result[:transaction][:category]
  end

  test "clears category with 'none'" do
    @transaction.update!(category: @category)

    result = @fn.call("transaction_id" => @transaction.id, "category" => "none")

    assert result[:success], result[:message]
    assert_nil @transaction.reload.category_id
  end

  test "updates name, notes, date and amount with nature" do
    result = @fn.call(
      "transaction_id" => @transaction.id,
      "name" => "Renamed coffee",
      "notes" => "Morning run",
      "date" => "2026-07-20",
      "amount" => 12.5,
      "nature" => "expense"
    )

    assert result[:success], result[:message]
    @entry.reload
    assert_equal "Renamed coffee", @entry.name
    assert_equal "Morning run", @entry.notes
    assert_equal Date.new(2026, 7, 20), @entry.date
    assert_equal 12.5, @entry.amount
  end

  test "requires nature when changing amount" do
    result = @fn.call("transaction_id" => @transaction.id, "amount" => 12.5)

    assert_not result[:success]
    assert_equal "nature_required", result[:error]
  end

  test "replaces tags and clears with empty array" do
    tag = @family.tags.first

    result = @fn.call("transaction_id" => @transaction.id, "tags" => [ tag.name ])
    assert result[:success], result[:message]
    assert_equal [ tag.id ], @transaction.reload.tag_ids

    result = @fn.call("transaction_id" => @transaction.id, "tags" => [])
    assert result[:success], result[:message]
    assert_empty @transaction.reload.tag_ids
  end

  test "toggles excluded flag" do
    result = @fn.call("transaction_id" => @transaction.id, "excluded" => true)

    assert result[:success], result[:message]
    assert @entry.reload.excluded
  end

  test "rejects unknown transaction and non-uuid ids" do
    result = @fn.call("transaction_id" => SecureRandom.uuid)
    assert_equal "transaction_not_found", result[:error]

    result = @fn.call("transaction_id" => "not-a-uuid")
    assert_equal "transaction_not_found", result[:error]
  end

  test "rejects transactions from other families" do
    other_family_transaction = Transaction.joins(entry: :account).where.not(accounts: { family_id: @family.id }).first
    skip "no other-family transaction fixture" unless other_family_transaction

    result = @fn.call("transaction_id" => other_family_transaction.id, "category" => @category.name)
    assert_equal "transaction_not_found", result[:error]
  end

  test "rejects when nothing to update" do
    result = @fn.call("transaction_id" => @transaction.id)
    assert_equal "nothing_to_update", result[:error]
  end
end
