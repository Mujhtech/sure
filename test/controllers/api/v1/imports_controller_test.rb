# frozen_string_literal: true

require "test_helper"

class Api::V1::ImportsControllerTest < ActionDispatch::IntegrationTest
  SAMPLE_QIF = <<~QIF
    !Type:Bank
    D1/ 2'24
    T-12.50
    PCoffee Shop
    LCafes/Mobile
    ^
    D1/ 3'24
    T-20.00
    PGrocery Store
    LGroceries/Weekly
    ^
  QIF

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @import = imports(:transaction)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @diagnostic_category_name = "Diagnostic Groceries #{SecureRandom.hex(4)}"
    @diagnostic_import = @family.imports.create!(
      type: "TransactionImport",
      status: "pending",
      account: @account,
      raw_file_str: "date,amount,name,category,tags\n01/15/2024,-10.00,Grocery Run,#{@diagnostic_category_name},Food|Weekly",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      category_col_label: "category",
      tags_col_label: "tags"
    )
    @diagnostic_row = @diagnostic_import.rows.create!(
      source_row_number: 7,
      date: "01/15/2024",
      amount: "-10.00",
      currency: "USD",
      name: "Grocery Run",
      category: @diagnostic_category_name,
      entity_type: "checking",
      tags: "Food|Weekly"
    )
    @invalid_diagnostic_row = @diagnostic_import.rows.build(
      source_row_number: 8,
      date: "not-a-date",
      amount: "not-a-number",
      currency: "BAD",
      name: "Bad Row"
    )
    @invalid_diagnostic_row.save!(validate: false)

    @diagnostic_category = @family.categories.create!(
      name: @diagnostic_category_name,
      color: "#407706",
      lucide_icon: "shopping-basket"
    )
    Import::CategoryMapping.create!(
      import: @diagnostic_import,
      key: @diagnostic_category_name,
      mappable: @diagnostic_category
    )
    Import::AccountTypeMapping.create!(
      import: @diagnostic_import,
      key: "checking",
      value: "Depository"
    )
  end

  test "should list imports" do
    get api_v1_imports_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_not_empty json_response["data"]
    assert_equal @family.imports.count, json_response["meta"]["total_count"]

    import_data = json_response["data"].detect { |data| data["id"] == @import.id }
    assert_not_nil import_data
    assert_equal @import.uploaded?, import_data["status_detail"]["uploaded"]
    assert_equal @import.configured?, import_data["status_detail"]["configured"]
    assert_equal @import.complete? || @import.failed? || @import.revert_failed?, import_data["status_detail"]["terminal"]
  end

  test "should show import" do
    get api_v1_import_url(@import), headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    rows = @import.rows.to_a
    valid_rows_count = rows.count(&:valid?)
    invalid_rows_count = rows.length - valid_rows_count

    assert_equal @import.id, json_response["data"]["id"]
    assert_equal @import.status, json_response["data"]["status"]
    assert json_response["data"].key?("status_detail")
    assert_equal @import.uploaded?, json_response["data"]["status_detail"]["uploaded"]
    assert_equal @import.configured?, json_response["data"]["status_detail"]["configured"]
    assert_equal @import.cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count),
                 json_response["data"]["status_detail"]["cleaned"]
    assert_equal @import.publishable_from_validation_stats?(invalid_rows_count: invalid_rows_count),
                 json_response["data"]["status_detail"]["publishable"]
    assert_equal @import.revertable?, json_response["data"]["status_detail"]["revertable"]
    assert_equal @import.rows_count, json_response["data"]["stats"]["rows_count"]
    assert_equal valid_rows_count, json_response["data"]["stats"]["valid_rows_count"]
    assert_equal invalid_rows_count, json_response["data"]["stats"]["invalid_rows_count"]
    assert_equal @import.mappings.count, json_response["data"]["stats"]["mappings_count"]
    assert_equal @import.mappings.where(mappable_id: nil).count,
                 json_response["data"]["stats"]["unassigned_mappings_count"]
  end

  test "should download sample CSV for CSV-backed import" do
    get "/api/v1/imports/#{@diagnostic_import.id}/sample_csv", headers: api_headers(@read_only_api_key)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_match "transaction_sample.csv", response.headers["Content-Disposition"]
    assert_includes response.body, "date*,amount*,name"
    assert_includes response.body, "Grocery Store"
  end

  test "should require authentication for sample CSV download" do
    get "/api/v1/imports/#{@diagnostic_import.id}/sample_csv"

    assert_response :unauthorized
  end

  test "should require read scope for sample CSV download" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Sample CSV Key",
      scopes: [],
      source: "web",
      display_key: "no_read_sample_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get "/api/v1/imports/#{@diagnostic_import.id}/sample_csv", headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  test "should reject sample CSV download for non CSV-backed import" do
    qif_import = create_qif_import

    get "/api/v1/imports/#{qif_import.id}/sample_csv", headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "unsupported_import_type", json_response["error"]
  end

  test "should not expose another family's sample CSV" do
    other_family = Family.create!(name: "Other Sample CSV Family", currency: "USD", locale: "en")
    other_import = other_family.imports.create!(type: "TransactionImport", raw_file_str: "date,amount,name")

    get "/api/v1/imports/#{other_import.id}/sample_csv", headers: api_headers(@api_key)

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "not_found", json_response["error"]
  end

  test "should show PDF import processing details" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: Rack::Test::UploadedFile.new(
        Rails.root.join("test/fixtures/files/imports/sample_bank_statement.pdf"),
        "application/pdf"
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)
    pdf_import.update!(
      status: "pending",
      ai_summary: "Bank statement with extracted transactions",
      document_type: "bank_statement",
      extracted_data: {
        "transactions" => [
          {
            "date" => "2024-01-15",
            "amount" => "-50.00",
            "name" => "Coffee Shop",
            "category" => "Food & Drink",
            "notes" => "Morning coffee"
          }
        ]
      },
      rows_count: 1
    )

    get api_v1_import_url(pdf_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    pdf_details = json_response.dig("data", "pdf_import")

    assert_equal true, pdf_details["pdf_uploaded"]
    assert_equal "sample_bank_statement.pdf", pdf_details["pdf_filename"]
    assert_equal true, pdf_details["ai_processed"]
    assert_equal "bank_statement", pdf_details["document_type"]
    assert_equal "Bank statement with extracted transactions", pdf_details["ai_summary"]
    assert_equal true, pdf_details["statement_with_transactions"]
    assert_equal true, pdf_details["has_extracted_transactions"]
    assert_equal 1, pdf_details["extracted_transactions_count"]
    assert_equal true, pdf_details["rows_ready_for_review"]
    assert_equal statement.id, pdf_details.dig("account_statement", "id")
    assert_equal download_api_v1_account_statement_path(statement), pdf_details.dig("account_statement", "download_path")
  end

  test "should show Sure import verification" do
    sure_import = @family.imports.create!(type: "SureImport")
    sure_import.ndjson_file.attach(
      io: StringIO.new(build_ndjson([
        { type: "Account", data: {
          id: "account-1",
          name: "API Verified Checking",
          balance: "100.00",
          currency: "USD",
          accountable_type: "Depository"
        } },
        { type: "Valuation", data: {
          id: "valuation-1",
          account_id: "account-1",
          date: "2024-01-14",
          amount: "100.00",
          currency: "USD",
          kind: "opening_anchor"
        } }
      ])),
      filename: "sure.ndjson",
      content_type: "application/x-ndjson"
    )
    sure_import.sync_ndjson_rows_count!
    sure_import.publish

    get api_v1_import_url(sure_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    verification = json_response.dig("data", "verification")

    assert_equal 1, verification.dig("expected_record_counts", "accounts")
    assert_equal 1, verification.dig("expected_record_counts", "valuations")
    assert_equal "matched", verification.dig("readback", "status")
    assert_equal 1, verification.dig("readback", "actual_delta_counts", "accounts")
    assert_equal 1, verification.dig("readback", "actual_delta_counts", "valuations")
    assert_equal 0, verification.dig("readback", "checked_counts", "balances")
    assert_empty verification.dig("readback", "mismatches")
  end

  test "should update import account assignment" do
    import = @family.imports.create!(
      type: "TransactionImport",
      status: "pending",
      raw_file_str: "date,amount,name\n01/15/2024,-10.00,Grocery Run"
    )

    patch api_v1_import_url(import),
          params: { import: { account_id: @account.id } },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal @account.id, import.reload.account_id
    assert_equal @account.id, JSON.parse(response.body).dig("data", "account_id")
  end

  test "should update pdf import account and linked statement" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: Rack::Test::UploadedFile.new(
        Rails.root.join("test/fixtures/files/imports/sample_bank_statement.pdf"),
        "application/pdf"
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)

    patch api_v1_import_url(pdf_import),
          params: { account_id: @account.id },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal @account.id, pdf_import.reload.account_id
    assert_equal @account.id, statement.reload.account_id
  end

  test "should reject import account assignment with read-only key" do
    import = @family.imports.create!(type: "TransactionImport", status: "pending")

    patch api_v1_import_url(import),
          params: { import: { account_id: @account.id } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_nil import.reload.account_id
  end

  test "should reject import account assignment outside family" do
    other_account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Other Import Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    import = @family.imports.create!(type: "TransactionImport", status: "pending")

    patch api_v1_import_url(import),
          params: { import: { account_id: other_account.id } },
          headers: api_headers(@api_key)

    assert_response :not_found
    assert_nil import.reload.account_id
  end

  test "should list sanitized import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@read_only_api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal 2, json_response["meta"]["total_count"]
    row_data = json_response["data"].find { |row| row["id"] == @diagnostic_row.id }

    assert_not_nil row_data
    assert_equal true, row_data["valid"]
    assert_equal 7, row_data["row_number"]
    assert_equal "Grocery Run", row_data.dig("fields", "name")
    assert_equal @diagnostic_category_name, row_data.dig("fields", "category")
    assert_equal @diagnostic_category.id, row_data.dig("mappings", "category", "mappable", "id")
    assert_equal "Depository", row_data.dig("mappings", "account_type", "value")
    tag_mapping = row_data.dig("mappings", "tags").find { |mapping| mapping["key"] == "Weekly" }
    assert_not_nil tag_mapping
    assert_nil tag_mapping["value"]
    assert_not row_data.key?("raw_file_str")
    refute_includes response.body, @diagnostic_import.raw_file_str
  end

  test "should include validation errors for invalid import rows" do
    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    row_data = json_response["data"].find { |row| row["id"] == @invalid_diagnostic_row.id }

    assert_not_nil row_data
    assert_equal false, row_data["valid"]
    assert_not_empty row_data["errors"]
  end

  test "should paginate import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import),
        params: { page: 1, per_page: 1 },
        headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal 1, json_response["data"].length
    assert_equal 2, json_response["meta"]["total_count"]
    assert_equal 1, json_response["meta"]["per_page"]
  end

  test "should list import row diagnostics in source row order" do
    @diagnostic_import.rows.create!(
      source_row_number: 6,
      date: "01/14/2024",
      amount: "-5.00",
      currency: "USD",
      name: "Earlier Source Row"
    )

    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal [ 6, 7, 8 ], json_response["data"].map { |row| row["row_number"] }
  end

  test "should update import configuration and regenerate rows" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/configuration",
          params: {
            import: {
              date_col_label: "date",
              amount_col_label: "amount",
              name_col_label: "name",
              category_col_label: "category",
              tags_col_label: "tags",
              date_format: "%m/%d/%Y",
              rows_to_skip: 0
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @diagnostic_import.id, json_response.dig("data", "id")
    assert_equal "date", json_response.dig("data", "configuration", "date_col_label")
    assert_equal 1, @diagnostic_import.reload.rows_count
    assert_equal "Grocery Run", @diagnostic_import.rows.first.name
  end

  test "should refresh import configuration rows_to_skip only" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/configuration",
          params: {
            refresh_only: true,
            import: { rows_to_skip: 2 }
          },
          headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 2, @diagnostic_import.reload.rows_to_skip
    assert_equal 2, json_response.dig("data", "stats", "rows_count")
  end

  test "should reject import configuration update with read-only API key" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/configuration",
          params: { import: { rows_to_skip: 1 } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should apply suggested import template" do
    @family.imports.create!(
      type: "TransactionImport",
      status: "complete",
      account: @account,
      raw_file_str: "posted,amount,description\n01/10/2024,-12.00,Coffee",
      date_col_label: "posted",
      amount_col_label: "amount",
      name_col_label: "description",
      category_col_label: "category",
      tags_col_label: "labels",
      date_format: "%m/%d/%Y",
      number_format: "1,234.56",
      signage_convention: "inflows_positive",
      rows_to_skip: 1
    )

    post "/api/v1/imports/#{@diagnostic_import.id}/apply_template", headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    @diagnostic_import.reload
    assert_equal "posted", @diagnostic_import.date_col_label
    assert_equal "description", @diagnostic_import.name_col_label
    assert_equal "labels", @diagnostic_import.tags_col_label
    assert_equal "%m/%d/%Y", @diagnostic_import.date_format
    assert_equal 1, @diagnostic_import.rows_to_skip
    assert_equal "posted", json_response.dig("data", "configuration", "date_col_label")
  end

  test "should reject apply template with read-only API key" do
    post "/api/v1/imports/#{@diagnostic_import.id}/apply_template", headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return validation error when no suggested import template exists" do
    other_account = @family.accounts.create!(
      name: "Template-less Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    import = @family.imports.create!(
      type: "TransactionImport",
      status: "pending",
      account: other_account,
      raw_file_str: "date,amount,name\n01/10/2024,-12.00,Coffee"
    )

    post "/api/v1/imports/#{import.id}/apply_template", headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "template_not_found", json_response["error"]
  end

  test "should update import row and resync mappings" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/rows/#{@diagnostic_row.id}",
          params: {
            import_row: {
              name: "Updated Grocery Run",
              category: "Mobile Groceries",
              tags: "Mobile|Edited"
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal @diagnostic_row.id, json_response.dig("data", "id")
    assert_equal "Updated Grocery Run", json_response.dig("data", "fields", "name")
    assert_equal "Mobile Groceries", @diagnostic_row.reload.category
    assert Import::CategoryMapping.exists?(import: @diagnostic_import, key: "Mobile Groceries")
    assert Import::TagMapping.exists?(import: @diagnostic_import, key: "Edited")
  end

  test "should reject import row update with read-only API key" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/rows/#{@diagnostic_row.id}",
          params: { import_row: { name: "Blocked" } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return not found for missing import row update" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/rows/#{SecureRandom.uuid}",
          params: { import_row: { name: "Missing" } },
          headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should update import mapping to an existing mappable" do
    category = @family.categories.create!(name: "Mapped Mobile Category", color: "#407706", lucide_icon: "shopping-basket")
    mapping = Import::CategoryMapping.find_by!(import: @diagnostic_import, key: @diagnostic_category_name)

    patch "/api/v1/imports/#{@diagnostic_import.id}/mappings/#{mapping.id}",
          params: {
            import_mapping: {
              mappable_id: category.id
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal mapping.id, json_response.dig("data", "id")
    assert_equal category.id, json_response.dig("data", "mappable", "id")
    assert_equal category.id, mapping.reload.mappable_id
  end

  test "should update import mapping to create when empty" do
    mapping = Import::TagMapping.find_by!(import: @diagnostic_import, key: "Weekly")

    patch "/api/v1/imports/#{@diagnostic_import.id}/mappings/#{mapping.id}",
          params: {
            import_mapping: {
              mappable_id: Import::Mapping::CREATE_NEW_KEY
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal true, json_response.dig("data", "create_when_empty")
    assert_equal true, mapping.reload.create_when_empty
    assert_nil mapping.mappable
  end

  test "should reject import mapping update with read-only API key" do
    mapping = Import::CategoryMapping.find_by!(import: @diagnostic_import, key: @diagnostic_category_name)

    patch "/api/v1/imports/#{@diagnostic_import.id}/mappings/#{mapping.id}",
          params: { import_mapping: { mappable_id: @diagnostic_category.id } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return not found for missing import mapping update" do
    patch "/api/v1/imports/#{@diagnostic_import.id}/mappings/#{SecureRandom.uuid}",
          params: { import_mapping: { mappable_id: @diagnostic_category.id } },
          headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should not expose another family's import rows" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_import = other_family.imports.create!(type: "TransactionImport", raw_file_str: "date,amount,name")

    get rows_api_v1_import_url(other_import), headers: api_headers(@api_key)

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "not_found", json_response["error"]
  end

  test "should require authentication for import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import)

    assert_response :unauthorized
  end

  test "should require read scope for import row diagnostics" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  test "should create import with raw content" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)
    assert_equal "pending", json_response["data"]["status"]

    created_import = Import.find(json_response["data"]["id"])
    assert_equal csv_content, created_import.raw_file_str
  end

  test "should create import and generate rows when configured" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_difference([ "Import.count", "Import::Row.count" ], 1) do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)

    import = Import.find(json_response["data"]["id"])
    assert_equal 1, import.rows_count
    assert_equal "Test Transaction", import.rows.first.name
    assert_equal "-10.00", import.rows.first.amount # Normalized
  end

  test "should instantiate RuleImport before generating rows" do
    @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      lucide_icon: "shopping-basket"
    )

    csv_content = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Categorize groceries","transaction",true,2024-01-01,"[{""condition_type"":""transaction_name"",""operator"":""like"",""value"":""grocery""}]","[{""action_type"":""set_transaction_category"",""value"":""Groceries""}]"
    CSV

    assert_difference([ "Import.count", "Import::Row.count" ], 1) do
      post api_v1_imports_url,
           params: {
             type: "RuleImport",
             raw_file_content: csv_content,
             col_sep: ","
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    import = Import.find(json_response["data"]["id"])
    row = import.rows.first

    assert_instance_of RuleImport, import
    assert_equal 1, import.rows_count
    assert_equal "Categorize groceries", row.name
    assert_equal "transaction", row.resource_type
    assert_equal true, row.active
    assert_equal "2024-01-01", row.effective_date
    assert_equal '[{"condition_type":"transaction_name","operator":"like","value":"grocery"}]', row.conditions
    assert_equal '[{"action_type":"set_transaction_category","value":"Groceries"}]', row.actions
  end

  test "should create QIF import with uploaded file" do
    qif_file = Rack::Test::UploadedFile.new(
      StringIO.new(SAMPLE_QIF),
      "application/octet-stream",
      original_filename: "mobile.qif"
    )

    assert_difference("Import.count", 1) do
      assert_difference("Import::Row.count", 2) do
        post api_v1_imports_url,
             params: {
               type: "QifImport",
               account_id: @account.id,
               file: qif_file
             },
             headers: api_headers(@api_key)
      end
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    import = Import.find(json_response["data"]["id"])

    assert_instance_of QifImport, import
    assert_equal @account.id, import.account_id
    assert_equal 2, import.rows_count
    assert_equal "Coffee Shop", import.rows.order(:source_row_number).first.name
    assert_equal "Bank", import.qif_account_type
  end

  test "should reject QIF import without account" do
    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "QifImport",
             raw_file_content: SAMPLE_QIF
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "account_required", json_response["error"]
  end

  test "should create PDF import with account assignment" do
    assert_difference("PdfImport.count", 1) do
      assert_difference("AccountStatement.count", 1) do
        post api_v1_imports_url,
             params: {
               type: "PdfImport",
               account_id: @account.id,
               file: Rack::Test::UploadedFile.new(
                 Rails.root.join("test/fixtures/files/imports/sample_bank_statement.pdf"),
                 "application/pdf"
               )
             },
             headers: api_headers(@api_key)
      end
    end

    assert_response :created
    import = PdfImport.find(JSON.parse(response.body).dig("data", "id"))
    assert_equal @account.id, import.account_id
    assert_equal @account.id, import.account_statement.account_id
  end

  test "should create PDF import when PDF file is uploaded without explicit type" do
    assert_difference("PdfImport.count", 1) do
      post api_v1_imports_url,
           params: {
             file: Rack::Test::UploadedFile.new(
               Rails.root.join("test/fixtures/files/imports/sample_bank_statement.pdf"),
               "application/pdf"
             )
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    import = Import.find(JSON.parse(response.body).dig("data", "id"))
    assert_instance_of PdfImport, import
  end

  test "should reject invalid PDF import file" do
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new("not a pdf"),
      "application/pdf",
      original_filename: "invalid.pdf"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "PdfImport",
             file: invalid_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_pdf", json_response["error"]
  end

  test "should show QIF category selection summary" do
    qif_import = create_qif_import

    get "/api/v1/imports/#{qif_import.id}/qif_category_selection", headers: api_headers(@read_only_api_key)

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal qif_import.id, data["import_id"]
    assert_equal "Bank", data["qif_account_type"]
    assert_equal "%m/%d/%Y", data["qif_date_format"]
    assert_equal true, data["categories_selected"]
    assert_equal [ "Cafes", "Groceries" ], data["categories"].map { |category| category["name"] }
    assert_equal 1, data["categories"].find { |category| category["name"] == "Cafes" }["count"]
    assert_equal [ "Mobile", "Weekly" ], data["tags"].map { |tag| tag["name"] }
    assert data["date_formats"].any? { |format| format["selected"] && format["format"] == "%m/%d/%Y" }
  end

  test "should update QIF category selection and resync mappings" do
    qif_import = create_qif_import

    patch "/api/v1/imports/#{qif_import.id}/qif_category_selection",
          params: {
            qif_category_selection: {
              categories: [ "Groceries" ],
              tags: [ "Weekly" ]
            }
          },
          headers: api_headers(@api_key)

    assert_response :success

    qif_import.reload
    coffee_row = qif_import.rows.find_by!(name: "Coffee Shop")
    grocery_row = qif_import.rows.find_by!(name: "Grocery Store")

    assert_equal "", coffee_row.category
    assert_equal "", coffee_row.tags
    assert_equal "Groceries", grocery_row.category
    assert_equal "Weekly", grocery_row.tags
    assert_not Import::CategoryMapping.exists?(import: qif_import, key: "Cafes")
    assert_not Import::TagMapping.exists?(import: qif_import, key: "Mobile")

    data = JSON.parse(response.body)["data"]
    assert_equal [ "Groceries" ], data["categories"].map { |category| category["name"] }
    assert_equal [ "Weekly" ], data["tags"].map { |tag| tag["name"] }
  end

  test "should reject QIF category selection update with read-only API key" do
    qif_import = create_qif_import

    patch "/api/v1/imports/#{qif_import.id}/qif_category_selection",
          params: { qif_category_selection: { categories: [ "Groceries" ] } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should reject QIF category selection for non-QIF import" do
    get "/api/v1/imports/#{@diagnostic_import.id}/qif_category_selection", headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "unsupported_import_type", json_response["error"]
  end

  test "should create Sure import with raw NDJSON content" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    import = Import.find(json_response["data"]["id"])

    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
    assert_equal "pending", import.status
  end

  test "should require authentication for Sure import" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           }
    end

    assert_response :unauthorized
  end

  test "should reject Sure import with read-only API key" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
    json_response = JSON.parse(response.body)
    assert_equal "insufficient_scope", json_response["error"]
  end

  test "should create Sure import with uploaded NDJSON file" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    valid_file = Rack::Test::UploadedFile.new(
      StringIO.new(ndjson_content),
      "application/x-ndjson",
      original_filename: "sure-backup.ndjson"
    )

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: valid_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    import = Import.find(JSON.parse(response.body)["data"]["id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
  end

  test "should reject Sure import with no file or raw content" do
    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "missing_content", json_response["error"]
  end

  test "should reject Sure import uploaded file exceeding max size" do
    test_limit = 1.kilobyte
    large_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (test_limit + 1)),
      "application/x-ndjson",
      original_filename: "large.ndjson"
    )

    SureImport.stubs(:max_ndjson_size).returns(test_limit)

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: large_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "file_too_large", json_response["error"]
  end

  test "should reject Sure import uploaded file with invalid type" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new(ndjson_content),
      "application/pdf",
      original_filename: "sure-backup.pdf"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: invalid_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_file_type", json_response["error"]
  end

  test "should clean up Sure import if row sync fails" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    SureImport.any_instance.stubs(:sync_ndjson_rows_count!).raises(StandardError, "sync failed")

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    assert_equal "internal_server_error", json_response["error"]
  end

  test "should clean up Sure import if row sync validation fails" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    invalid_import = SureImport.new
    invalid_import.errors.add(:base, "invalid rows")
    SureImport.any_instance.stubs(:sync_ndjson_rows_count!).raises(ActiveRecord::RecordInvalid.new(invalid_import))

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
    assert_includes json_response["errors"], "invalid rows"
  end

  test "should preserve Sure import if publish queueing fails" do
    ndjson_content = {
      type: "Account",
      data: {
        id: "account_1",
        name: "Checking",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      }
    }.to_json
    ImportJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    assert_equal "publish_failed", json_response["error"]

    import = Import.find(json_response["import_id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
    assert_equal "pending", import.status
  end

  test "should preserve Sure import and return preflight errors when auto publish fails preflight" do
    @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      lucide_icon: "shopping-basket"
    )
    ndjson_content = [
      { type: "Category", data: { id: "category_1", name: "Groceries" } }
    ].map(&:to_json).join("\n")

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "preflight_failed", json_response["error"]
    assert_includes json_response["errors"].join("\n"), "Category name \"Groceries\" already exists"

    import = Import.find(json_response["import_id"])
    assert_equal "failed", import.status
    assert import.ndjson_file.attached?
  end

  test "should preserve Sure import and return not publishable when auto publish has no records" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    SureImport.any_instance.stubs(:publish_later).raises(
      SureImport::NotPublishableError,
      "raw publishability failure with internal state"
    )

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "not_publishable", json_response["error"]
    assert_equal "Import was uploaded but has no publishable records.", json_response["message"]
    assert_not json_response.key?("errors")
    refute_includes response.body, "raw publishability failure"

    import = Import.find(json_response["import_id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
    assert_equal "pending", import.status
  end

  test "should return unsupported Sure record errors during auto publish preflight" do
    ndjson_content = [
      { type: "MysteryType", data: { id: "mystery_1" } }
    ].map(&:to_json).join("\n")

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "preflight_failed", json_response["error"]
    assert_includes json_response["errors"].join("\n"), "unsupported record type MysteryType"

    import = Import.find(json_response["import_id"])
    assert_equal "failed", import.status
  end

  test "should preserve Sure import if auto publish exceeds row count" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    SureImport.any_instance.stubs(:publish_later).raises(Import::MaxRowCountExceededError)

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "max_row_count_exceeded", json_response["error"]

    import = Import.find(json_response["import_id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
  end

  test "should reject invalid Sure import NDJSON content" do
    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: "not ndjson"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_ndjson", json_response["error"]
  end

  test "should preflight CSV import without persisting records" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_no_difference([ "Import.count", "Import::Row.count" ]) do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    json_response = JSON.parse(response.body)
    data = json_response["data"]

    assert_equal "TransactionImport", data["type"]
    assert_equal true, data["valid"]
    assert_equal 1, data["stats"]["rows_count"]
    assert_not data["stats"].key?("valid_rows_count")
    assert_not data["stats"].key?("invalid_rows_count")
    assert_equal %w[date amount name], data["headers"]
    assert_empty data["missing_required_headers"]
    assert_empty data["errors"]
  end

  test "should report missing required CSV headers during preflight" do
    csv_content = "name\nMissing Amount"

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 1, data["stats"]["rows_count"]
    assert_not data["stats"].key?("valid_rows_count")
    assert_not data["stats"].key?("invalid_rows_count")
    assert_equal [ "date", "amount" ], data["missing_required_headers"]
    assert_equal "missing_required_headers", data["errors"].first["code"]
  end

  test "should apply rows_to_skip before CSV preflight header validation" do
    csv_content = [
      "Generated by bank export",
      "posted,amount,description",
      "2024-01-01,-10.00,Coffee"
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             rows_to_skip: 1,
             date_col_label: "posted",
             amount_col_label: "amount",
             name_col_label: "description",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal true, data["valid"]
    assert_equal 1, data["stats"]["rows_count"]
    assert_equal %w[posted amount description], data["headers"]
    assert_empty data["missing_required_headers"]
  end

  test "should preflight semicolon separated CSV content" do
    csv_content = "date;amount;name\n2024-01-01;-10.00;Coffee"

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             col_sep: ";",
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal true, data["valid"]
    assert_equal 1, data["stats"]["rows_count"]
    assert_equal %w[date amount name], data["headers"]
  end

  test "should report invalid preflight CSV parser config without parsing" do
    csv_content = "date,amount,name\n2024-01-01,-10.00,Coffee"

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             col_sep: "",
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 0, data["stats"]["rows_count"]
    assert_empty data["headers"]
    assert_equal "validation_failed", data["errors"].first["code"]
  end

  test "should reject malformed CSV during preflight" do
    csv_content = "date,amount,name\n2024-01-01,-10.00,\"Coffee Shop"

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_csv", json_response["error"]
  end

  test "should hide preflight exception message in internal server error response" do
    Import::Preflight.any_instance.stubs(:call).raises(StandardError, "boom with raw internals")

    post preflight_api_v1_imports_url,
         params: {
           raw_file_content: "date,amount,name\n2024-01-01,-10.00,Coffee",
           date_col_label: "date",
           amount_col_label: "amount",
           name_col_label: "name"
         },
         headers: api_headers(@read_only_api_key)

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    assert_equal "internal_server_error", json_response["error"]
    assert_equal "Import preflight could not be completed.", json_response["message"]
    refute_includes response.body, "boom with raw internals"
  end

  test "should reject unknown preflight import type" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "FakeImport",
             raw_file_content: "date,amount,name\n2023-01-01,-10.00,Test Transaction"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "invalid_import_type", response_data["error"]
    assert_not response_data.key?("errors")
  end

  test "should reject import types excluded from preflight" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "QifImport",
             raw_file_content: "!Type:Bank\nD01/01/2024\nT-10.00\nPTest\n^"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "invalid_import_type", response_data["error"]
    assert_not response_data.key?("errors")
    assert_not_includes response_data["message"], "QifImport"
    assert_not_includes response_data["message"], "PdfImport"
  end

  test "should report empty CSV preflight content as invalid" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: "date,amount,name\n",
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 0, data["stats"]["rows_count"]
    assert_equal "no_data_rows", data["errors"].first["code"]
    assert_empty data["warnings"]
  end

  test "should preflight Sure import without persisting records" do
    ndjson_content = [
      { type: "Account", data: {
        id: "account_1",
        name: "Checking",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      } }.to_json,
      { type: "Transaction", data: {
        id: "entry_1",
        account_id: "account_1",
        date: "2024-01-01",
        amount: "-5"
      } }.to_json
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal "SureImport", data["type"]
    assert_equal true, data["valid"]
    assert_equal 2, data["stats"]["rows_count"]
    assert_equal 1, data["stats"]["entity_counts"]["accounts"]
    assert_equal 1, data["stats"]["entity_counts"]["transactions"]
    assert_empty data["errors"]
  end

  test "should preflight Sure import taxonomy collisions in strict mode" do
    @family.tags.create!(name: "Reviewed", color: "#12B76A")
    ndjson_content = [
      { type: "Tag", data: { id: "tag_1", name: "Reviewed" } }
    ].map(&:to_json).join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]
    assert_equal false, data["valid"]
    assert_equal "existing_taxonomy_collision", data["errors"].first["code"]
  end

  test "should report invalid Sure import accountable type during preflight" do
    ndjson_content = [
      { type: "Account", data: {
        id: "account_1",
        name: "Checking",
        balance: "100",
        currency: "USD",
        accountable_type: "Kernel"
      } }.to_json
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal "invalid_accountable_type", data["errors"].first["code"]
    assert_includes data["errors"].first["message"], "Kernel"
  end

  test "should report invalid Sure import NDJSON during preflight" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: "not ndjson"
           },
           headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 1, data["stats"]["invalid_rows_count"]
    assert_equal "invalid_json", data["errors"].first["code"]
  end

  test "should report non-object Sure import NDJSON records during preflight" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: "[]"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 1, data["stats"]["invalid_rows_count"]
    assert_equal "invalid_ndjson_record", data["errors"].first["code"]
  end

  test "should report empty Sure import file as invalid during preflight" do
    empty_file = Rack::Test::UploadedFile.new(
      StringIO.new(""),
      "application/x-ndjson",
      original_filename: "empty.ndjson"
    )

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "SureImport",
             file: empty_file
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal false, data["valid"]
    assert_equal 0, data["stats"]["rows_count"]
    assert_equal "no_data_rows", data["errors"].first["code"]
    assert_empty data["warnings"]
  end

  test "should reject preflight with no file or raw content" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: { type: "SureImport" },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "missing_content", JSON.parse(response.body)["error"]
  end

  test "should reject oversized file uploads during preflight" do
    test_limit = 1.kilobyte
    large_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (test_limit + 1)),
      "text/csv",
      original_filename: "large.csv"
    )

    Import.stubs(:max_csv_size).returns(test_limit)

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: { file: large_file },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "file_too_large", JSON.parse(response.body)["error"]
  end

  test "should preflight with read-only API key" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    assert_equal true, JSON.parse(response.body)["data"]["valid"]
  end

  test "should require authentication for preflight" do
    post preflight_api_v1_imports_url, params: {
      raw_file_content: "date,amount,name\n2023-01-01,-10.00,Test Transaction"
    }

    assert_response :unauthorized
  end

  test "should return not found for preflight account outside family" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_depository = Depository.create!(subtype: "checking")
    other_account = Account.create!(
      family: other_family,
      name: "Other Account",
      currency: "USD",
      classification: "asset",
      accountable: other_depository,
      balance: 0
    )

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: "date,amount,name\n2023-01-01,-10.00,Test Transaction",
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: other_account.id
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "should return not found for malformed preflight account id" do
    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             raw_file_content: "date,amount,name\n2023-01-01,-10.00,Test Transaction",
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: "not-a-uuid"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "should apply Mint defaults before preflight header validation" do
    mint_content = [
      "Date,Amount,Account Name,Description,Category,Labels,Currency,Notes,Transaction Type",
      "01/01/2024,-8.55,Checking,Starbucks,Food & Drink,Coffee,USD,Morning coffee,debit"
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "MintImport",
             raw_file_content: mint_content
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal "MintImport", data["type"]
    assert_equal true, data["valid"]
    assert_empty data["missing_required_headers"]
    assert_includes data["required_headers"], "Date"
    assert_includes data["required_headers"], "Amount"
  end

  test "should apply Actual defaults before preflight header validation" do
    actual_content = [
      "Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared",
      "Checking Account,2024-01-01,Coffee Shop,Morning coffee,Food,Coffee,-4.25,0,Cleared"
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "ActualImport",
             raw_file_content: actual_content
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal "ActualImport", data["type"]
    assert_equal true, data["valid"]
    assert_empty data["missing_required_headers"]
    assert_includes data["required_headers"], "Date"
    assert_includes data["required_headers"], "Amount"
  end

  test "should not overwrite explicit Actual preflight column mappings with defaults" do
    actual_content = [
      "Booked On,Value,Payee",
      "2024-01-01,-4.25,Coffee Shop"
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "ActualImport",
             raw_file_content: actual_content,
             date_col_label: "Booked On",
             amount_col_label: "Value"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal true, data["valid"]
    assert_equal [ "Booked On", "Value" ], data["required_headers"]
    assert_empty data["missing_required_headers"]
  end

  test "should not overwrite explicit Mint preflight column mappings with defaults" do
    mint_content = [
      "Posted On,Value,Description",
      "01/01/2024,-8.55,Starbucks"
    ].join("\n")

    assert_no_difference("Import.count") do
      post preflight_api_v1_imports_url,
           params: {
             type: "MintImport",
             raw_file_content: mint_content,
             date_col_label: "Posted On",
             amount_col_label: "Value"
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)["data"]

    assert_equal true, data["valid"]
    assert_equal [ "Posted On", "Value" ], data["required_headers"]
    assert_empty data["missing_required_headers"]
  end

  test "should create import and auto-publish when configured and requested" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_enqueued_with(job: ImportJob) do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id,
             date_format: "%Y-%m-%d",
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)
    assert_equal "importing", json_response["data"]["status"]
  end

  test "should not create import for account in another family" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_depository = Depository.create!(subtype: "checking")
    other_account = Account.create!(family: other_family, name: "Other Account", currency: "USD", classification: "asset", accountable: other_depository, balance: 0)

    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    post api_v1_imports_url,
          params: {
            raw_file_content: csv_content,
            account_id: other_account.id
          },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["errors"], "Account must belong to your family"
  end

  test "should reject file upload exceeding max size" do
    large_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (Import::MAX_CSV_SIZE + 1)),
      "text/csv",
      original_filename: "large.csv"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { file: large_file },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "file_too_large", json_response["error"]
  end

  test "should reject file upload with invalid mime type" do
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new("not a csv"),
      "application/pdf",
      original_filename: "document.pdf"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { file: invalid_file },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_file_type", json_response["error"]
  end

  test "should reject raw content exceeding max size" do
    # Use a small test limit to avoid Rack request size limits
    test_limit = 1.kilobyte
    large_content = "x" * (test_limit + 1)

    Import.stubs(:max_csv_size).returns(test_limit)

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { raw_file_content: large_content },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "content_too_large", json_response["error"]
  end

  test "should accept file upload with valid csv mime type" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"
    valid_file = Rack::Test::UploadedFile.new(
      StringIO.new(csv_content),
      "text/csv",
      original_filename: "transactions.csv"
    )

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             file: valid_file,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
  end

  test "should publish import" do
    Import.any_instance.expects(:publish_later).returns(true)

    post publish_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :accepted
    json_response = JSON.parse(response.body)
    assert_equal @diagnostic_import.id, json_response.dig("data", "id")
  end

  test "should reject publish with read-only API key" do
    post publish_api_v1_import_url(@diagnostic_import), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return validation error when import cannot be published" do
    Import.any_instance.stubs(:publish_later).raises(StandardError, "Import is not publishable")

    post publish_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "not_publishable", json_response["error"]
    assert_equal "Import could not be queued for processing.", json_response["message"]
  end

  test "should return max row count error when publish exceeds row limit" do
    Import.any_instance.stubs(:publish_later).raises(Import::MaxRowCountExceededError)

    post publish_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "max_row_count_exceeded", json_response["error"]
  end

  test "should revert import" do
    @diagnostic_import.update!(status: "complete")
    Import.any_instance.expects(:revert_later).returns(true)

    post revert_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :accepted
    json_response = JSON.parse(response.body)
    assert_equal @diagnostic_import.id, json_response.dig("data", "id")
  end

  test "should reject revert with read-only API key" do
    post revert_api_v1_import_url(@diagnostic_import), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return validation error when import cannot be reverted" do
    Import.any_instance.stubs(:revert_later).raises(StandardError, "Import is not revertable")

    post revert_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "not_revertable", json_response["error"]
    assert_equal "Import could not be queued for revert.", json_response["message"]
  end

  test "should destroy import" do
    import = @family.imports.create!(type: "TransactionImport", status: "pending")

    assert_difference("@family.imports.count", -1) do
      delete api_v1_import_url(import), headers: api_headers(@api_key)
    end

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal "Import deleted successfully", json_response["message"]
  end

  test "should reject destroy with read-only API key" do
    delete api_v1_import_url(@diagnostic_import), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return not found for missing import lifecycle actions" do
    post publish_api_v1_import_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found

    post revert_api_v1_import_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found

    delete api_v1_import_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  private

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end

    def create_qif_import
      @family.imports.create!(
        type: "QifImport",
        account: @account,
        raw_file_str: SAMPLE_QIF
      ).tap do |import|
        import.generate_rows_from_csv
        import.sync_mappings
        import.reload
      end
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
