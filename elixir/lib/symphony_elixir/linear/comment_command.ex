defmodule SymphonyElixir.Linear.CommentCommand do
  @moduledoc """
  Parses explicit Linear comment commands for planner and rework automation.
  """

  alias SymphonyElixir.Linear.Issue

  @planner_commands MapSet.new([
                      "/roadmap-review",
                      "/revise-plan",
                      "/split-task",
                      "/block",
                      "/unblock"
                    ])
  @approve_command "/approve-plan"
  @rework_command "/rework-pr"
  @commands @planner_commands |> MapSet.put(@approve_command) |> MapSet.put(@rework_command)

  defstruct [
    :comment_id,
    :command,
    :arguments,
    :body,
    :issue,
    :route
  ]

  @type route :: :planner | :approve_plan | :rework_pr
  @type t :: %__MODULE__{
          comment_id: String.t(),
          command: String.t(),
          arguments: String.t(),
          body: String.t(),
          issue: Issue.t(),
          route: route()
        }

  @spec command_prefixes() :: [String.t()]
  def command_prefixes do
    MapSet.to_list(@commands) |> Enum.sort()
  end

  @spec parse(Issue.t(), map()) :: {:ok, t()} | :ignore | {:error, term()}
  def parse(%Issue{} = issue, comment) when is_map(comment) do
    comment_id = Map.get(comment, :id) || Map.get(comment, "id")
    body = Map.get(comment, :body) || Map.get(comment, "body")

    if is_binary(comment_id) and is_binary(body) do
      do_parse(issue, comment_id, body)
    else
      :ignore
    end
  end

  def parse(_issue, _comment), do: :ignore

  defp do_parse(%Issue{} = issue, comment_id, body) do
    with {:ok, first_line} <- first_non_blank_line(body),
         {:ok, command, arguments} <- parse_command_line(first_line),
         {:ok, route} <- route_for_command(command) do
      {:ok,
       %__MODULE__{
         comment_id: comment_id,
         command: command,
         arguments: arguments,
         body: body,
         issue: issue,
         route: route
       }}
    else
      :ignore -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_non_blank_line(body) when is_binary(body) do
    body
    |> String.split(~r/\R/, trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> :ignore
      line -> {:ok, line}
    end
  end

  defp parse_command_line("/" <> _ = line) do
    [command | rest] = String.split(line, ~r/\s+/, parts: 2)
    arguments = rest |> List.first() |> normalize_arguments()

    if MapSet.member?(@commands, command) do
      {:ok, command, arguments}
    else
      :ignore
    end
  end

  defp parse_command_line(_line), do: :ignore

  defp route_for_command(command) do
    cond do
      MapSet.member?(@planner_commands, command) -> {:ok, :planner}
      command == @approve_command -> {:ok, :approve_plan}
      command == @rework_command -> {:ok, :rework_pr}
      true -> :ignore
    end
  end

  defp normalize_arguments(nil), do: ""
  defp normalize_arguments(arguments) when is_binary(arguments), do: String.trim(arguments)
end
