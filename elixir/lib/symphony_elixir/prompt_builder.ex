defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      opts
      |> Keyword.get(:prompt_template)
      |> prompt_template_or_current!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> append_comment_command_context(Keyword.get(opts, :comment_command_context))
  end

  defp prompt_template_or_current!(prompt) when is_binary(prompt), do: default_prompt(prompt)
  defp prompt_template_or_current!(_prompt), do: Workflow.current() |> prompt_template!()

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp append_comment_command_context(prompt, nil), do: prompt

  defp append_comment_command_context(prompt, context) when is_map(context) do
    command = Map.get(context, :command) || Map.get(context, "command") || ""
    arguments = Map.get(context, :arguments) || Map.get(context, "arguments") || ""
    comment_id = Map.get(context, :comment_id) || Map.get(context, "comment_id") || ""
    body = Map.get(context, :body) || Map.get(context, "body") || ""

    prompt <>
      """

      ## Triggering Linear Comment Command

      Command: #{command}
      Arguments: #{arguments}
      Comment ID: #{comment_id}

      Comment body:

      ```text
      #{body}
      ```

      Handle this explicit command according to the workflow contract. Ordinary Linear comments remain discussion only.

      Command detection and dispatch are not completion. Before ending this turn, produce the appropriate durable artifact for `#{command}`: a pushed PR update, Linear handoff/comment, Project Update, blocker, acknowledgement, or explicit no-op reason.

      If repository docs mention older supervised-only or one-turn comment-command limitations, treat those notes as stale for this run. The active Symphony runner supports unattended command completion and this explicit command block is the controlling instruction.
      #{command_specific_guidance(command)}
      """
  end

  defp append_comment_command_context(prompt, _context), do: prompt

  defp command_specific_guidance("/rework-pr") do
    """

    This is a review-rework command, not a request to perform a read-only code review or return only a plan. Apply the requested scoped revision to the existing draft PR branch, run the relevant verification, push the branch, and leave a fresh Linear handoff. If no change is appropriate, post a fresh Linear comment explaining the no-op reason before ending the turn.
    """
  end

  defp command_specific_guidance(_command), do: ""
end
