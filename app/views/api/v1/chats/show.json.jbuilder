# frozen_string_literal: true

json.partial! "chat", chat: @chat

messages = @messages || @chat.messages.ordered

json.messages messages do |message|
  json.partial! "message", message: message
end

if @pagy
  json.pagination do
    json.page @pagy.page
    json.per_page @pagy.vars[:items]
    json.total_count @pagy.count
    json.total_pages @pagy.pages
  end
end
