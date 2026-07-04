# frozen_string_literal: true

json.attachments @attachments do |attachment|
  json.partial! "api/v1/transaction_attachments/attachment", transaction: @transaction, attachment: attachment
end
