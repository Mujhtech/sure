# frozen_string_literal: true

json.id family_member.id
json.email family_member.email
json.display_name family_member.display_name
json.initials family_member.initials
json.role family_member.role
json.active family_member.active?
json.current_user family_member.id == Current.user&.id
json.can_remove Current.user&.admin? && family_member.id != Current.user&.id
json.created_at family_member.created_at.iso8601
json.updated_at family_member.updated_at.iso8601
