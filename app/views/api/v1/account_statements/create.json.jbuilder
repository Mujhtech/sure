# frozen_string_literal: true

json.account_statements @account_statements do |account_statement|
  json.partial! "api/v1/account_statements/account_statement", account_statement: account_statement
end

json.duplicates @duplicates do |account_statement|
  json.id account_statement.id
  json.filename account_statement.filename
end

json.errors @upload_errors
