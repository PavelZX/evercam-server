defmodule TimelapseRecording do
  use EvercamMediaWeb, :model
  import Ecto.Query
  alias EvercamMedia.Repo

  @required_fields ~w(camera_id frequency storage_duration status schedule)

  schema "timelapse_recordings" do
    belongs_to :camera, Camera, foreign_key: :camera_id

    field :frequency, :integer
    field :storage_duration, :integer
    field :status, :string
    field :schedule, EvercamMedia.Types.JSON

    timestamps(type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def get_all_ephemeral do
    TimelapseRecording
    |> where([cl], cl.storage_duration != -1)
    |> preload(:camera)
    |> Repo.all
  end

  def by_camera_id(camera_id) do
    TimelapseRecording
    |> where(camera_id: ^camera_id)
    |> Repo.one
  end

  def delete_by_camera_id(camera_id) do
    TimelapseRecording
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def schedule(timelapse_recording) do
    if timelapse_recording == nil || timelapse_recording.status == "off" do
      %{}
    else
      timelapse_recording.schedule
    end
  end

  def recording(timelapse_recording) do
    if timelapse_recording == nil do
      "off"
    else
      timelapse_recording.status
    end
  end

  def initial_sleep(timelapse_recording) do
    if timelapse_recording == nil || timelapse_recording.frequency == 1 || timelapse_recording.status == "off" do
      :crypto.rand_uniform(1, 60) * 1000
    else
      1000
    end
  end

  def sleep(timelapse_recording) do
    if timelapse_recording == nil || timelapse_recording.status == "off" || timelapse_recording.status == "paused" do
      60_000
    else
      timelapse_recording.frequency * 1_000
    end
  end

  defp count_sleep(frequency) when frequency in [5, 10], do: 60_000 * frequency
  defp count_sleep(frequency), do: div(60_000, frequency)

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(model, params \\ :invalid) do
    model
    |> cast(params, @required_fields)
    |> validate_required(required_fields())
  end
end
