# frozen_string_literal: true

json.insights @insights do |insight|
  json.partial! "insight", insight: insight, unread: @unread_ids.include?(insight.id)
end

json.unread_count @unread_ids.size
