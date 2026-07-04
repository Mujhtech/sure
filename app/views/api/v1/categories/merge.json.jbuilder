# frozen_string_literal: true

json.message "Categories merged successfully"
json.merged_count @merged_count
json.category do
  json.partial! "api/v1/categories/category", category: @category
end
