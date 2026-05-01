defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Linear.Client, Linear.Issue, Tracker}

  @linear_graphql_tool "linear_graphql"
  @linear_create_comment_tool "linear_create_comment"
  @linear_update_issue_state_tool "linear_update_issue_state"
  @linear_graphql_description """
  Escape hatch: execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_create_comment_description """
  Create a Linear issue comment. Defaults to the current issue when issueId is omitted.
  """
  @linear_update_issue_state_description """
  Move a Linear issue to a named workflow state. Defaults to the current issue when issueId is omitted.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @linear_create_comment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["body"],
    "properties" => %{
      "issueId" => %{
        "type" => ["string", "null"],
        "description" => "Linear issue id or identifier. Defaults to the current issue."
      },
      "body" => %{
        "type" => "string",
        "description" => "Markdown comment body."
      }
    }
  }
  @linear_update_issue_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["stateName"],
    "properties" => %{
      "issueId" => %{
        "type" => ["string", "null"],
        "description" => "Linear issue id or identifier. Defaults to the current issue."
      },
      "stateName" => %{
        "type" => "string",
        "description" => "Target Linear workflow state name."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_create_comment_tool ->
        execute_linear_create_comment(arguments, opts)

      @linear_update_issue_state_tool ->
        execute_linear_update_issue_state(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_create_comment_tool,
        "description" => @linear_create_comment_description,
        "inputSchema" => @linear_create_comment_input_schema
      },
      %{
        "name" => @linear_update_issue_state_tool,
        "description" => @linear_update_issue_state_description,
        "inputSchema" => @linear_update_issue_state_input_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_create_comment(arguments, opts) do
    comment_creator = Keyword.get(opts, :comment_creator, &Tracker.create_comment/2)

    with {:ok, issue_id, body} <- normalize_comment_arguments(arguments, opts),
         :ok <- comment_creator.(issue_id, body) do
      success_response(%{
        "ok" => true,
        "issueId" => issue_id,
        "action" => @linear_create_comment_tool
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_update_issue_state(arguments, opts) do
    state_updater = Keyword.get(opts, :state_updater, &Tracker.update_issue_state/2)

    with {:ok, issue_id, state_name} <- normalize_state_update_arguments(arguments, opts),
         :ok <- state_updater.(issue_id, state_name) do
      success_response(%{
        "ok" => true,
        "issueId" => issue_id,
        "stateName" => state_name,
        "action" => @linear_update_issue_state_tool
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_comment_arguments(arguments, opts) when is_map(arguments) do
    with {:ok, issue_id} <- normalize_issue_id(arguments, opts),
         {:ok, body} <- normalize_body(arguments) do
      {:ok, issue_id, body}
    end
  end

  defp normalize_comment_arguments(_arguments, _opts), do: {:error, :invalid_arguments}

  defp normalize_state_update_arguments(arguments, opts) when is_map(arguments) do
    with {:ok, issue_id} <- normalize_issue_id(arguments, opts),
         {:ok, state_name} <- normalize_state_name(arguments) do
      {:ok, issue_id, state_name}
    end
  end

  defp normalize_state_update_arguments(_arguments, _opts), do: {:error, :invalid_arguments}

  defp normalize_issue_id(arguments, opts) do
    issue_id =
      arguments
      |> map_value(["issueId", :issueId, "issue_id", :issue_id])
      |> normalize_optional_string()

    case issue_id || current_issue_id(opts) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_issue_id}
    end
  end

  defp normalize_body(arguments) do
    arguments
    |> map_value(["body", :body])
    |> normalize_required_string(:missing_body)
  end

  defp normalize_state_name(arguments) do
    arguments
    |> map_value(["stateName", :stateName, "state_name", :state_name])
    |> normalize_required_string(:missing_state_name)
  end

  defp map_value(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_required_string(value, error) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_string(_value, error), do: {:error, error}

  defp current_issue_id(opts) do
    case Keyword.get(opts, :current_issue) do
      %Issue{id: id} when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
      _ -> Keyword.get(opts, :current_issue_id)
    end
    |> normalize_optional_string()
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_issue_id) do
    %{
      "error" => %{
        "message" => "Linear issue id is required when no current issue is available."
      }
    }
  end

  defp tool_error_payload(:missing_body) do
    %{
      "error" => %{
        "message" => "`linear_create_comment` requires a non-empty `body` string."
      }
    }
  end

  defp tool_error_payload(:missing_state_name) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` requires a non-empty `stateName` string."
      }
    }
  end

  defp tool_error_payload(:comment_create_failed) do
    %{
      "error" => %{
        "message" => "Linear comment creation did not report success."
      }
    }
  end

  defp tool_error_payload(:issue_update_failed) do
    %{
      "error" => %{
        "message" => "Linear issue state update did not report success."
      }
    }
  end

  defp tool_error_payload(:state_not_found) do
    %{
      "error" => %{
        "message" => "Linear workflow state was not found for the issue's team."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
