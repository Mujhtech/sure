# frozen_string_literal: true

json.account do
  json.id @account.id
  json.name @account.name
  json.owner_id @account.owner_id
  json.owned_by_current_user @account.owned_by?(Current.user)
  json.current_user_permission @account.permission_for(Current.user)

  if @account.owner.present?
    json.owner do
      json.id @account.owner.id
      json.email @account.owner.email
      json.display_name @account.owner.display_name
      json.initials @account.owner.initials
    end
  else
    json.owner nil
  end
end

json.permissions AccountShare::PERMISSIONS

if @current_user_share.present?
  json.current_user_share do
    json.id @current_user_share.id
    json.permission @current_user_share.permission
    json.include_in_finances @current_user_share.include_in_finances?
  end
else
  json.current_user_share nil
end

json.family_members @family_members do |user|
  share = @account_shares_by_user_id[user.id]

  json.id user.id
  json.email user.email
  json.display_name user.display_name
  json.initials user.initials
  json.active user.active?

  if share.present?
    json.share do
      json.id share.id
      json.shared true
      json.permission share.permission
      json.include_in_finances share.include_in_finances?
      json.created_at share.created_at.iso8601
      json.updated_at share.updated_at.iso8601
    end
  else
    json.share do
      json.id nil
      json.shared false
      json.permission nil
      json.include_in_finances nil
      json.created_at nil
      json.updated_at nil
    end
  end
end
