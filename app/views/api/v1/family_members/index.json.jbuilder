# frozen_string_literal: true

json.family_members @family_members do |family_member|
  json.partial! "api/v1/family_members/family_member", family_member: family_member
end

json.pending_invitations @pending_invitations do |invitation|
  json.partial! "api/v1/invitations/invitation", invitation: invitation, accepted_existing_user: false
end
