defmodule EvercamMedia.Util do
  require Logger
  alias EvercamMedia.Schedule
  alias Evercam.SnapshotRepo
  import String, only: [to_integer: 1]

  def deep_get(map, keys, default \\ nil), do: do_deep_get(map, keys, default)

  defp do_deep_get(nil, _, default), do: default
  defp do_deep_get(%{} = map, [], default) when map_size(map) == 0, do: default
  defp do_deep_get(value, [], _default), do: value
  defp do_deep_get(map, [key|rest], default) do
    map
    |> Map.get(key, %{})
    |> do_deep_get(rest, default)
  end

  def unavailable do
    ConCache.dirty_get_or_store(:snapshot_error, "unavailable", fn() ->
      Application.app_dir(:evercam_media)
      |> Path.join("priv/static/images/unavailable.jpg")
      |> File.read!
    end)
  end

  def default_thumbnail do
    ConCache.dirty_get_or_store(:snapshot_error, "default_thumbnail", fn() ->
      Application.app_dir(:evercam_media)
      |> Path.join("priv/static/images/default-thumbnail.jpg")
      |> File.read!
    end)
  end

  def storage_unavailable do
    ConCache.dirty_get_or_store(:snapshot_error, "storage_unavailable", fn() ->
      Application.app_dir(:evercam_media)
      |> Path.join("priv/static/images/storage-unavailable.jpg")
      |> File.read!
    end)
  end

  def jpeg?(<<0xFF, 0xD8, _ :: binary>>), do: true
  def jpeg?(_), do: false

  def port_open?(address, port) do
    case :gen_tcp.connect(to_charlist(address), to_integer(port), [:binary, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _error} ->
        false
    end
  end

  def encode(args) do
    message = format_token_message(args)
    encrypted_message = :crypto.block_encrypt(
      :aes_cbc256,
      System.get_env["SNAP_KEY"],
      System.get_env["SNAP_IV"],
      message)
    Base.url_encode64(encrypted_message)
  end

  def decode(token) do
    encrypted_message = Base.url_decode64!(token)
    message = :crypto.block_decrypt(
      :aes_cbc256,
      System.get_env["SNAP_KEY"],
      System.get_env["SNAP_IV"],
      encrypted_message)
    message |> String.split("|") |> List.delete_at(-1)
  end

  def broadcast_snapshot(camera_exid, image, timestamp) do
    EvercamMediaWeb.Endpoint.broadcast(
      "cameras:#{camera_exid}",
      "snapshot-taken",
      %{image: Base.encode64(image), timestamp: timestamp})
  end

  def broadcast_camera_status(camera_exid, status, username) do
    EvercamMediaWeb.Endpoint.broadcast(
      "users:#{username}",
      "camera-status-changed",
      %{camera_id: camera_exid, status: status})
  end

  def broadcast_camera_share(camera, username) do
    EvercamMediaWeb.Endpoint.broadcast(
      "users:#{username}",
      "camera-share",
      camera)
  end

  def broadcast_camera_response(camera_exid, timestamp, response_time, description, response_type) do
    EvercamMediaWeb.Endpoint.broadcast(
      "livetail:#{camera_exid}",
      "camera-response",
      %{timestamp: timestamp, response_time: response_time, response_type: response_type, description: description})
  end

  defp format_token_message(args) do
    args ++ [""]
    |> Enum.join("|")
    |> pad_token_message
  end

  defp pad_token_message(message) do
    case rem(String.length(message), 16) do
      0 -> message
      _ -> pad_token_message("#{message} ")
    end
  end

  def ecto_datetime_to_unix(nil), do: nil
  def ecto_datetime_to_unix(datetime) do
    datetime
    |> Calendar.DateTime.Format.unix
  end

  def get_list(values) when values in [nil, ""], do: []
  def get_list(values) do
    values
    |> String.split(",", trim: true)
  end

  def parse_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn
      {msg, opts} -> String.replace(msg, "%{count}", to_string(opts[:count]))
      msg -> msg
    end)
  end

  def slugify(string) do
    string |> String.normalize(:nfd) |> String.replace(~r/[^A-z0-9-\s]/u, "")
  end

  def create_HMAC(username, intercom_key) do
    :crypto.hmac(:sha256, intercom_key, username)
    |> Base.encode16
    |> String.downcase
  end

  def kill_all_ffmpegs do
    Porcelain.shell("for pid in $(ps -ef | grep ffmpeg | grep 'rtsp://' | grep -v grep |  awk '{print $2}'); do kill -9 $pid; done")
    MetaData.delete_all()
    spawn(fn -> Camera.all |> Enum.map(&(invalidate_response_time_cache &1)) end)
  end

  def invalidate_response_time_cache(nil), do: :noop
  def invalidate_response_time_cache(camera) do
    ConCache.delete(:camera_response_times, camera.exid)
  end

  def get_offline_reason(reason) when reason in [nil, ""], do: reason
  def get_offline_reason(reason) do
    case reason |> String.to_atom do
      :system_limit -> "Sorry, we dropped the ball."
      :emfile -> "Sorry, we dropped the ball."
      :case_clause -> "Bad request."
      :bad_request -> "Bad request."
      :closed -> "Connection closed."
      :nxdomain -> "Non-existant domain."
      :ehostunreach -> "No route to host."
      :enetunreach -> "Network unreachable."
      :req_timedout -> "Request to the camera timed out."
      :timeout -> "Camera response timed out."
      :connect_timeout -> "Connection to the camera timed out."
      :econnrefused -> "Connection refused."
      :not_found -> "Camera snapshot url is not found."
      :forbidden -> "Camera responded with a Forbidden message."
      :unauthorized -> "Invalid username and password."
      :device_error -> "Camera responded with a Device Error message."
      :device_busy -> "Camera responded with a Device Busy message."
      :invalid_operation -> "Camera responded with a Invalid Operation message."
      :moved -> "Camera url has changed, please update it."
      :not_a_jpeg -> "Camera didn't respond with an image."
      _reason -> "Sorry, we dropped the ball."
    end
  end

  def get_rtmp_url(camera, requester \\ "Anonymous") do
    if Camera.rtsp_url(camera) != "" do
      base_url = EvercamMediaWeb.Endpoint.url |> String.replace("http", "rtmp") |> String.replace("4000", "1935")
      "#{base_url}/live/#{url_token(camera)}?stream_token=#{streaming_token(camera, requester)}"
    else
      ""
    end
  end

  def get_hls_url(camera, requester \\ "Anonymous") do
    if Camera.rtsp_url(camera) != "" do
      base_url = EvercamMediaWeb.Endpoint.static_url
      "#{base_url}/live/#{url_token(camera)}/index.m3u8?stream_token=#{streaming_token(camera, requester)}"
    else
      ""
    end
  end

  defp url_token(camera) do
    Base.url_encode64("#{camera.exid}|#{camera.name}")
  end

  defp streaming_token(camera, requester) do
    token = "#{username(camera)}|#{password(camera)}|#{Camera.rtsp_url(camera)}|#{requester}"
    encode([token])
  end

  def auth(camera) do
    username(camera) <> ":" <> password(camera)
  end

  def username(camera) do
    deep_get(camera, [:config, "auth", "basic", "username"], "")
  end

  def password(camera) do
    deep_get(camera, [:config, "auth", "basic", "password"], "")
  end

  def camera_recording?(camera_full) do
    !!Application.get_env(:evercam_media, :start_camera_workers)
    && CloudRecording.sleep(camera_full.cloud_recordings) == 1000
    && Schedule.scheduled_now?(camera_full) == {:ok, true}
  end

  def log_activity(user, camera, action, extra \\ nil, done_at \\ Calendar.DateTime.now_utc) do
    do_log(Application.get_env(:evercam_media, :run_spawn), user, camera, action, extra, done_at)
  end

  defp do_log(true, user, camera, action, extra, done_at) do
    access_token_id = AccessToken.active_token_id_for(user.id)
    params = %{
      camera_id: camera.id,
      camera_exid: camera.exid,
      access_token_id: access_token_id,
      name: User.get_fullname(user),
      action: action,
      extra: extra,
      done_at: done_at
    }
    %CameraActivity{}
    |> CameraActivity.changeset(params)
    |> SnapshotRepo.insert
  end
  defp do_log(_mode, _, _, _, _, _), do: :noop

  def camera_share_get_rights("private", user, camera) do
    ["snapshot", "list", "share", "view", "edit", "delete"]
    |> Enum.filter(fn(right) -> Permission.Camera.can_access?(right, user, camera) end)
    |> Enum.join(",")
  end

  def camera_share_get_rights("public", _user, _camera) do
    ["snapshot", "list"]
    |> Enum.join(",")
  end
end
