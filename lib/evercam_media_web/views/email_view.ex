defmodule EvercamMediaWeb.EmailView do
  use EvercamMediaWeb, :view

  def full_name(user) do
    "#{user.firstname} #{user.lastname}"
  end

  def image_tag(has_thumbnail) do
    case has_thumbnail do
      true -> "<br><img src='cid:snapshot.jpg' alt='Camera Preview' style='width: 100%; display:block; margin:0 auto;' >"
      _ -> ""
    end
  end

  def get_user_name(email) do
    email
    |> User.by_username_or_email
    |> User.get_fullname
  end
end
