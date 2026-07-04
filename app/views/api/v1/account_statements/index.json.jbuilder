# frozen_string_literal: true

json.account_statements @account_statements do |account_statement|
  json.partial! "api/v1/account_statements/account_statement", account_statement: account_statement
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
