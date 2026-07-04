# frozen_string_literal: true

json.id attachment.id
json.filename attachment.filename.to_s
json.content_type attachment.content_type
json.byte_size attachment.byte_size
json.inline_path api_v1_transaction_attachment_path(transaction, attachment, disposition: "inline")
json.download_path api_v1_transaction_attachment_path(transaction, attachment, disposition: "attachment")
json.created_at attachment.created_at.iso8601
