defmodule SymphonyElixir.RoutingProjection do
  @moduledoc """
  Builds the persisted issue routing projection from live worker sessions.
  """

  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.Linear.Issue

  @waiting_status "waiting_for_probe"
  @alert_threshold_seconds 30

  @type projection :: map()

  @spec build_issue_projection(Issue.t(), [map()], DateTime.t()) :: projection()
  def build_issue_projection(%Issue{} = issue, sessions, %DateTime{} = now) when is_list(sessions) do
    requirement = ExecutionRequirement.from_issue(issue)

    case requirement.execution_requirement do
      "default" -> default_fields(requirement)
      "host_only" -> host_only_fields(issue, requirement, sessions, now)
    end
  end

  @spec preserve_wait_since(map(), map()) :: map()
  def preserve_wait_since(previous_snapshot, next_snapshot)
      when is_map(previous_snapshot) and is_map(next_snapshot) do
    if continuous_wait?(previous_snapshot, next_snapshot) do
      Map.put(next_snapshot, "routing_since_at", previous_snapshot["routing_since_at"])
    else
      next_snapshot
    end
  end

  @spec history_fields(map(), DateTime.t()) :: projection()
  def history_fields(snapshot, %DateTime{} = now) when is_map(snapshot) do
    if Map.has_key?(snapshot, "execution_requirement") do
      wait_seconds = wait_seconds(snapshot, now)

      %{
        execution_requirement: snapshot["execution_requirement"],
        required_capabilities: snapshot["required_capabilities"],
        routing_status: snapshot["routing_status"],
        routing_reason: snapshot["routing_reason"],
        eligible_probe_count: snapshot["eligible_probe_count"],
        selected_probe_id: snapshot["selected_probe_id"],
        routing_since_at: snapshot["routing_since_at"],
        routing_wait_seconds: wait_seconds,
        routing_alert_threshold_seconds: @alert_threshold_seconds,
        routing_alert: is_integer(wait_seconds) and wait_seconds >= @alert_threshold_seconds
      }
    else
      unrecorded_fields()
    end
  end

  @spec waiting?(map()) :: boolean()
  def waiting?(snapshot) when is_map(snapshot), do: snapshot["routing_status"] == @waiting_status

  @spec alert?(map(), DateTime.t()) :: boolean()
  def alert?(snapshot, %DateTime{} = now) when is_map(snapshot) do
    snapshot |> history_fields(now) |> Map.fetch!(:routing_alert)
  end

  @spec alert_threshold_seconds() :: pos_integer()
  def alert_threshold_seconds, do: @alert_threshold_seconds

  defp default_fields(requirement) do
    base_fields(requirement)
    |> Map.merge(%{
      "routing_status" => "eligible_default",
      "routing_reason" => nil,
      "eligible_probe_count" => 0,
      "selected_probe_id" => nil,
      "routing_since_at" => nil
    })
  end

  defp host_only_fields(issue, requirement, sessions, now) do
    host_sessions = Enum.filter(sessions, &(routing_value(&1, :execution_surface) == "host_probe"))
    eligible_sessions = Enum.filter(host_sessions, &(ExecutionRequirement.admit(issue, &1) == :ok))

    case eligible_sessions do
      [] -> waiting_fields(requirement, waiting_reason(host_sessions), now)
      [selected | _rest] -> ready_fields(requirement, selected, length(eligible_sessions))
    end
  end

  defp waiting_reason([]), do: "no_online_eligible_probe"
  defp waiting_reason(_host_sessions), do: "capability_mismatch"

  defp waiting_fields(requirement, reason, now) do
    base_fields(requirement)
    |> Map.merge(%{
      "routing_status" => @waiting_status,
      "routing_reason" => reason,
      "eligible_probe_count" => 0,
      "selected_probe_id" => nil,
      "routing_since_at" => now |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    })
  end

  defp ready_fields(requirement, selected, count) do
    base_fields(requirement)
    |> Map.merge(%{
      "routing_status" => "ready_host_probe",
      "routing_reason" => nil,
      "eligible_probe_count" => count,
      "selected_probe_id" => routing_value(selected, :probe_id),
      "routing_since_at" => nil
    })
  end

  defp base_fields(requirement) do
    %{
      "execution_requirement" => requirement.execution_requirement,
      "required_capabilities" => requirement.required_capabilities
    }
  end

  defp continuous_wait?(previous, next) do
    previous["routing_status"] == @waiting_status and
      next["routing_status"] == @waiting_status and
      previous["routing_reason"] == next["routing_reason"] and
      is_binary(previous["routing_since_at"])
  end

  defp wait_seconds(%{"routing_status" => @waiting_status, "routing_since_at" => since}, now)
       when is_binary(since) do
    {:ok, since_at, _offset} = DateTime.from_iso8601(since)
    max(DateTime.diff(now, since_at, :second), 0)
  end

  defp wait_seconds(_snapshot, _now), do: nil

  defp unrecorded_fields do
    %{
      execution_requirement: "unrecorded",
      required_capabilities: "unrecorded",
      routing_status: "unrecorded",
      routing_reason: nil,
      eligible_probe_count: nil,
      selected_probe_id: nil,
      routing_since_at: nil,
      routing_wait_seconds: nil,
      routing_alert_threshold_seconds: @alert_threshold_seconds,
      routing_alert: false
    }
  end

  defp routing_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
