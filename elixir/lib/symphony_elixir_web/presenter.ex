defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: workspace_payload(issue_identifier, running, retry, blocked),
      attempts: attempts_payload(retry),
      running: maybe_running_issue_payload(running),
      retry: maybe_retry_issue_payload(retry),
      blocked: maybe_blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: issue_recent_events(running, blocked),
      last_error: issue_last_error(retry, blocked),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp workspace_payload(issue_identifier, running, retry, blocked) do
    %{
      path: workspace_path(issue_identifier, running, retry, blocked),
      host: workspace_host(running, retry, blocked)
    }
  end

  defp attempts_payload(retry) do
    %{
      restart_count: restart_count(retry),
      current_retry_attempt: retry_attempt(retry)
    }
  end

  defp maybe_running_issue_payload(nil), do: nil
  defp maybe_running_issue_payload(running), do: running_issue_payload(running)

  defp maybe_retry_issue_payload(nil), do: nil
  defp maybe_retry_issue_payload(retry), do: retry_issue_payload(retry)

  defp maybe_blocked_issue_payload(nil), do: nil
  defp maybe_blocked_issue_payload(blocked), do: blocked_issue_payload(blocked)

  defp issue_recent_events(running, blocked) do
    cond do
      not is_nil(running) -> recent_events_payload(running)
      not is_nil(blocked) -> recent_events_payload(blocked)
      true -> []
    end
  end

  defp issue_last_error(nil, nil), do: nil
  defp issue_last_error(retry, nil), do: retry.error
  defp issue_last_error(_retry, blocked), do: blocked.error

  defp issue_status(_running, _retry, blocked) when not is_nil(blocked), do: "blocked"
  defp issue_status(_running, nil, _blocked), do: "running"
  defp issue_status(nil, _retry, _blocked), do: "retrying"
  defp issue_status(_running, _retry, _blocked), do: "running"

  defp running_entry_payload(entry) do
    recent_events = recent_events_payload(entry)
    last_message = summarize_message(entry.last_codex_message)
    last_event_at = iso8601(entry.last_codex_timestamp)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: last_message,
      started_at: iso8601(entry.started_at),
      last_event_at: last_event_at,
      last_activity_at: last_event_at,
      current_activity: last_message,
      blocked_on: latest_blocker(recent_events),
      recent_events: recent_events,
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    recent_events = recent_events_payload(entry)
    last_message = summarize_message(entry.last_codex_message)
    last_event_at = iso8601(entry.last_codex_timestamp)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      blocked_on: entry.blocked_on,
      error: entry.error,
      failed_at: iso8601(Map.get(entry, :failed_at)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: last_message,
      started_at: iso8601(entry.started_at),
      last_event_at: last_event_at,
      last_activity_at: last_event_at,
      current_activity: last_message,
      recent_events: recent_events,
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp running_issue_payload(running) do
    recent_events = recent_events_payload(running)
    last_message = summarize_message(running.last_codex_message)
    last_event_at = iso8601(running.last_codex_timestamp)

    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: last_message,
      last_event_at: last_event_at,
      last_activity_at: last_event_at,
      current_activity: last_message,
      blocked_on: latest_blocker(recent_events),
      recent_events: recent_events,
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked), do: blocked_entry_payload(blocked)

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(running) do
    running
    |> Map.get(:recent_events, [])
    |> case do
      events when is_list(events) and events != [] ->
        Enum.map(events, &recent_event_payload/1)

      _ ->
        [
          %{
            timestamp: running.last_codex_timestamp,
            event: running.last_codex_event,
            message: running.last_codex_message
          }
        ]
        |> Enum.map(&recent_event_payload/1)
    end
    |> Enum.reject(&is_nil(&1.at))
  end

  defp recent_event_payload(%{timestamp: timestamp, event: event, message: message}) do
    humanized = summarize_message(message)

    %{
      at: iso8601(timestamp),
      event: event,
      message: humanized,
      blocked_on: classify_blocker(event, message)
    }
  end

  defp recent_event_payload(_event), do: %{at: nil, event: nil, message: nil, blocked_on: nil}

  defp latest_blocker(events) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(& &1.blocked_on)
  end

  defp classify_blocker(event, message) do
    event_text = event |> to_string() |> String.downcase()
    message_text = message |> inspect(limit: 50, printable_limit: 500) |> String.downcase()

    cond do
      String.contains?(event_text, ["auto_approved", "auto_answered"]) ->
        nil

      String.contains?(message_text, ["mcpserver/elicitation/request"]) ->
        "mcp_elicitation"

      String.contains?(event_text, ["approval_required"]) or
          String.contains?(message_text, ["approval_required", "requestapproval"]) ->
        "approval"

      String.contains?(event_text, ["input_required", "needs_input"]) or
          String.contains?(message_text, ["turn_input_required", "input_required", "requestuserinput"]) ->
        "user_input"

      true ->
        nil
    end
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
