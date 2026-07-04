# frozen_string_literal: true

json.goals @goals do |goal|
  json.partial! "api/v1/goals/goal", goal: goal
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
