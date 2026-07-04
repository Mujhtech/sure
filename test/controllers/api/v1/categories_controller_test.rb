# frozen_string_literal: true

require "test_helper"

class Api::V1::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    # Fixtures pre-create active keys for family_admin; clear them so we can
    # create scoped keys per-test without tripping the one-active-key-per-source
    # validation.
    @user.api_keys.active.destroy_all

    @category = categories(:food_and_drink)
    @subcategory = categories(:subcategory)
  end

  # Index action tests

  test "should require authentication" do
    get "/api/v1/categories"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should return user's family categories successfully" do
    get "/api/v1/categories", params: {}, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("categories")
    assert response_body["categories"].is_a?(Array)

    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")
  end

  test "should not return other family's categories" do
    other_family_api_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Key",
      key: ApiKey.generate_secure_key,
      scopes: %w[read],
      source: "web"
    )

    get "/api/v1/categories", params: {}, headers: api_headers(other_family_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include dylan_family's categories
    category_names = response_body["categories"].map { |c| c["name"] }
    assert_not_includes category_names, @category.name
  end

  test "should return proper category data structure" do
    get "/api/v1/categories", params: {}, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body["categories"].length > 0

    category = response_body["categories"].find { |c| c["name"] == @category.name }
    assert category.present?, "Should find the food_and_drink category"

    required_fields = %w[id name color icon subcategories_count created_at updated_at]
    required_fields.each do |field|
      assert category.key?(field), "Category should have #{field} field"
    end

    assert category["id"].is_a?(String), "ID should be string (UUID)"
    assert category["name"].is_a?(String), "Name should be string"
    assert category["color"].is_a?(String), "Color should be string"
    assert category["icon"].is_a?(String), "Icon should be string"
  end

  test "should include parent information for subcategories" do
    get "/api/v1/categories", params: {}, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    subcategory = response_body["categories"].find { |c| c["name"] == @subcategory.name }
    assert subcategory.present?, "Should find the subcategory"

    assert subcategory["parent"].present?, "Subcategory should have parent"
    assert_equal @category.id, subcategory["parent"]["id"]
    assert_equal @category.name, subcategory["parent"]["name"]
  end

  test "should handle pagination parameters" do
    get "/api/v1/categories", params: { page: 1, per_page: 2 }, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body["categories"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should filter for roots only" do
    get "/api/v1/categories", params: { roots_only: true }, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    response_body["categories"].each do |category|
      assert_nil category["parent"], "Root categories should not have a parent"
    end
  end

  test "should sort categories alphabetically" do
    get "/api/v1/categories", params: {}, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    category_names = response_body["categories"].map { |c| c["name"] }
    assert_equal category_names.sort, category_names
  end

  # Show action tests

  test "should return a single category" do
    get "/api/v1/categories/#{@category.id}", params: {}, headers: api_headers(read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal @category.id, response_body["id"]
    assert_equal @category.name, response_body["name"]
    assert_equal @category.color, response_body["color"]
    assert_equal @category.lucide_icon, response_body["icon"]
  end

  test "should return 404 for non-existent category" do
    get "/api/v1/categories/00000000-0000-0000-0000-000000000000", params: {}, headers: api_headers(read_only_api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should not return category from another family" do
    other_family_category = families(:empty).categories.create!(
      name: "Other Family Category",
      color: "#FF0000",
      classification_unused: "expense"
    )

    get "/api/v1/categories/#{other_family_category.id}", params: {}, headers: api_headers(read_only_api_key)

    assert_response :not_found
  end

  # Create action tests

  test "create requires authentication" do
    post "/api/v1/categories", params: { category: { name: "Anything" } }
    assert_response :unauthorized
  end

  test "create rejects api key without read_write scope" do
    post "/api/v1/categories",
      params: { category: { name: "Coffee Runs", color: "#22c55e", icon: "coffee" } },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  test "create returns 201 with full attributes" do
    post "/api/v1/categories",
      params: { category: { name: "Coffee Runs", color: "#22c55e", icon: "coffee" } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Coffee Runs", body["name"]
    assert_equal "#22c55e", body["color"]
    assert_equal "coffee", body["icon"]
    assert_nil body["parent"]
    assert_equal 0, body["subcategories_count"]

    persisted = @user.family.categories.find(body["id"])
    assert_equal "coffee", persisted.lucide_icon
  end

  test "create auto-suggests icon when omitted" do
    post "/api/v1/categories",
      params: { category: { name: "Groceries Imported", color: "#407706" } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["icon"].present?
    assert_not_equal "", body["icon"]
  end

  test "create attaches parent when provided" do
    post "/api/v1/categories",
      params: { category: { name: "Imported Subcategory", color: "#22c55e", icon: "shapes", parent_id: @category.id } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @category.id, body.dig("parent", "id")
    assert_equal @category.name, body.dig("parent", "name")
  end

  test "create returns 422 on duplicate name within family" do
    post "/api/v1/categories",
      params: { category: { name: @category.name, color: "#22c55e", icon: "shapes" } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert body["message"].present?
  end

  test "create returns 422 on invalid color" do
    post "/api/v1/categories",
      params: { category: { name: "Bad Color", color: "not-a-hex" } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert body["message"].present?
  end

  test "create returns 422 when parent_id belongs to another family" do
    other_family_category = families(:empty).categories.create!(
      name: "External Parent",
      color: "#FF0000",
      classification_unused: "expense"
    )

    post "/api/v1/categories",
      params: { category: { name: "Should Fail", color: "#22c55e", icon: "shapes", parent_id: other_family_category.id } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert body["message"].present?
  end

  test "create returns 422 when nesting exceeds two levels" do
    child = @user.family.categories.create!(
      name: "Existing Child",
      color: "#22c55e",
      lucide_icon: "shapes",
      parent: @category
    )

    post "/api/v1/categories",
      params: { category: { name: "Grandchild", color: "#22c55e", icon: "shapes", parent_id: child.id } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert body["message"].present?
  end

  test "create returns 400 when category payload is missing" do
    post "/api/v1/categories",
      params: {},
      headers: api_headers(read_write_api_key)

    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "bad_request", body["error"]
  end

  test "update changes category attributes" do
    patch api_v1_category_url(@subcategory),
      params: { category: { name: "Updated Subcategory", icon: "coffee" } },
      headers: api_headers(read_write_api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Updated Subcategory", body["name"]
    assert_equal "coffee", body["icon"]
  end

  test "update rejects parent from another family" do
    other_family_category = families(:empty).categories.create!(
      name: "External Parent",
      color: "#FF0000",
      lucide_icon: "shapes"
    )

    patch api_v1_category_url(@subcategory),
      params: { category: { parent_id: other_family_category.id } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "destroy deletes a category" do
    category = @user.family.categories.create!(
      name: "Disposable",
      color: "#22c55e",
      lucide_icon: "shapes"
    )

    assert_difference("@user.family.categories.count", -1) do
      delete api_v1_category_url(category), headers: api_headers(read_write_api_key)
    end

    assert_response :ok
  end

  test "replace_and_destroy reassigns transactions to replacement category" do
    replacement = @user.family.categories.create!(
      name: "Replacement Category",
      color: "#22c55e",
      lucide_icon: "shapes"
    )
    source = @user.family.categories.create!(
      name: "Replace Source Category",
      color: "#f97316",
      lucide_icon: "utensils"
    )
    transaction = transactions(:one)
    transaction.update!(category: source)

    assert_difference(-> { @user.family.categories.count }, -1) do
      post "/api/v1/categories/#{source.id}/replace_and_destroy",
        params: { replacement_category_id: replacement.id },
        headers: api_headers(read_write_api_key)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Category replaced and deleted successfully", body["message"]
    assert_equal 1, body["reassigned_transactions_count"]
    assert_equal source.id, body.dig("deleted_category", "id")
    assert_equal replacement.id, body.dig("replacement_category", "id")
    assert_equal replacement.id, transaction.reload.category_id
    assert_not @user.family.categories.exists?(source.id)
  end

  test "replace_and_destroy can leave transactions uncategorized" do
    source = @user.family.categories.create!(
      name: "Uncategorize Source Category",
      color: "#f97316",
      lucide_icon: "utensils"
    )
    transaction = transactions(:one)
    transaction.update!(category: source)

    assert_difference(-> { @user.family.categories.count }, -1) do
      post "/api/v1/categories/#{source.id}/replace_and_destroy",
        headers: api_headers(read_write_api_key)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["reassigned_transactions_count"]
    assert_nil body["replacement_category"]
    assert_nil transaction.reload.category_id
  end

  test "replace_and_destroy rejects same replacement category" do
    post "/api/v1/categories/#{@category.id}/replace_and_destroy",
      params: { replacement_category_id: @category.id },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal "Replacement category cannot be the same as the category being destroyed", body["message"]
  end

  test "replace_and_destroy rejects replacement category from another family" do
    other_category = families(:empty).categories.create!(
      name: "External Replacement",
      color: "#FF0000",
      lucide_icon: "shapes"
    )

    post "/api/v1/categories/#{@category.id}/replace_and_destroy",
      params: { replacement_category_id: other_category.id },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal "Replacement category not found", body["message"]
  end

  test "replace_and_destroy rejects api key without read_write scope" do
    post "/api/v1/categories/#{@category.id}/replace_and_destroy",
      params: { replacement_category_id: @subcategory.id },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  test "bootstrap creates default categories" do
    empty_user = users(:empty)
    empty_user.api_keys.active.destroy_all
    key = ApiKey.create!(
      user: empty_user,
      name: "Empty Family RW Key",
      key: ApiKey.generate_secure_key,
      scopes: %w[read_write],
      source: "web"
    )

    before_count = empty_user.family.categories.count
    post bootstrap_api_v1_categories_url, headers: api_headers(key)
    assert_response :success
    assert_operator empty_user.family.categories.count, :>, before_count
  end

  test "destroy_all deletes all family categories" do
    assert_operator @user.family.categories.count, :>, 0

    delete destroy_all_api_v1_categories_url, headers: api_headers(read_write_api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Categories deleted successfully", body["message"]
    assert_equal 0, body["categories_count"]
    assert_equal 0, @user.family.categories.count
  end

  test "destroy_all rejects api key without read_write scope" do
    delete destroy_all_api_v1_categories_url, headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  test "merge reassigns transactions and deletes source categories" do
    target = @user.family.categories.create!(
      name: "Target Category",
      color: "#22c55e",
      lucide_icon: "shapes"
    )
    source = @user.family.categories.create!(
      name: "Source Category",
      color: "#f97316",
      lucide_icon: "utensils"
    )
    transaction = transactions(:one)
    transaction.update!(category: source)

    assert_difference(-> { @user.family.categories.count }, -1) do
      post merge_api_v1_categories_url,
        params: { target_id: target.id, source_ids: [ source.id ] },
        headers: api_headers(read_write_api_key)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Categories merged successfully", body["message"]
    assert_equal 1, body["merged_count"]
    assert_equal target.id, body.dig("category", "id")
    assert_equal target.id, transaction.reload.category_id
    assert_not @user.family.categories.exists?(source.id)
  end

  test "merge rejects target selected as source" do
    post merge_api_v1_categories_url,
      params: { target_id: @category.id, source_ids: [ @category.id ] },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal "Target category cannot also be a source category", body["message"]
  end

  test "merge rejects missing source categories" do
    post merge_api_v1_categories_url,
      params: { target_id: @category.id, source_ids: [ SecureRandom.uuid ] },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal "One or more source categories were not found", body["message"]
  end

  test "merge rejects api key without read_write scope" do
    post merge_api_v1_categories_url,
      params: { target_id: @category.id, source_ids: [ @subcategory.id ] },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  private

    def read_write_api_key
      @read_write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RW Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read_write],
        source: "web"
      )
    end

    def read_only_api_key
      @read_only_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RO Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read],
        source: "mobile"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
