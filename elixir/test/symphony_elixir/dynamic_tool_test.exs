defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises Linear handoff tools and the raw GraphQL escape hatch" do
    specs = DynamicTool.tool_specs()

    assert %{
             "inputSchema" => %{
               "properties" => %{"body" => _, "issueId" => _},
               "required" => ["body"],
               "type" => "object"
             },
             "name" => "linear_create_comment"
           } = Enum.find(specs, &(&1["name"] == "linear_create_comment"))

    assert %{
             "inputSchema" => %{
               "properties" => %{"issueId" => _, "stateName" => _},
               "required" => ["stateName"],
               "type" => "object"
             },
             "name" => "linear_update_issue_state"
           } = Enum.find(specs, &(&1["name"] == "linear_update_issue_state"))

    assert %{
             "description" => description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             },
             "name" => "linear_graphql"
           } = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => [
                 "linear_create_comment",
                 "linear_update_issue_state",
                 "linear_graphql"
               ]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_create_comment posts to the current issue by default" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_create_comment",
        %{"body" => "## Handoff\n\nDone."},
        current_issue: %Issue{id: "issue-123"},
        comment_creator: fn issue_id, body ->
          send(test_pid, {:comment_created, issue_id, body})
          :ok
        end
      )

    assert_received {:comment_created, "issue-123", "## Handoff\n\nDone."}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "ok" => true,
             "issueId" => "issue-123",
             "action" => "linear_create_comment"
           }
  end

  test "linear_create_comment accepts an explicit issue id" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_create_comment",
        %{"issueId" => "HIN-23", "body" => "Ready for review"},
        comment_creator: fn issue_id, body ->
          send(test_pid, {:comment_created, issue_id, body})
          :ok
        end
      )

    assert_received {:comment_created, "HIN-23", "Ready for review"}
    assert response["success"] == true
  end

  test "linear_create_comment replies under command comments during command runs" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_create_comment",
        %{"body" => "## Handoff\n\nDone."},
        current_issue: %Issue{id: "issue-123"},
        comment_command_context: %{comment_id: "command-comment-1"},
        comment_creator: fn issue_id, body, opts ->
          send(test_pid, {:comment_created, issue_id, body, opts})
          :ok
        end
      )

    assert_received {:comment_created, "issue-123", "## Handoff\n\nDone.", [parent_id: "command-comment-1"]}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "ok" => true,
             "issueId" => "issue-123",
             "parentId" => "command-comment-1",
             "action" => "linear_create_comment"
           }
  end

  test "linear_create_comment fails closed when command runs cannot create replies" do
    response =
      DynamicTool.execute(
        "linear_create_comment",
        %{"body" => "Done."},
        current_issue: %Issue{id: "issue-123"},
        comment_command_context: %{comment_id: "command-comment-1"},
        comment_creator: fn _issue_id, _body ->
          flunk("two-argument comment creators cannot safely create command replies")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear comment creation requires parent-comment support for this command run."
             }
           }
  end

  test "linear_update_issue_state moves the current issue by state name" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"stateName" => "In Review"},
        current_issue_id: "issue-456",
        state_updater: fn issue_id, state_name ->
          send(test_pid, {:state_updated, issue_id, state_name})
          :ok
        end
      )

    assert_received {:state_updated, "issue-456", "In Review"}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "ok" => true,
             "issueId" => "issue-456",
             "stateName" => "In Review",
             "action" => "linear_update_issue_state"
           }
  end

  test "Linear handoff tools validate issue defaults and required strings" do
    missing_issue =
      DynamicTool.execute(
        "linear_create_comment",
        %{"body" => "Done"},
        comment_creator: fn _issue_id, _body -> flunk("comment creator should not be called") end
      )

    assert missing_issue["success"] == false

    assert Jason.decode!(missing_issue["output"]) == %{
             "error" => %{
               "message" => "Linear issue id is required when no current issue is available."
             }
           }

    missing_body =
      DynamicTool.execute(
        "linear_create_comment",
        %{"body" => "   "},
        current_issue_id: "issue-123",
        comment_creator: fn _issue_id, _body -> flunk("comment creator should not be called") end
      )

    assert Jason.decode!(missing_body["output"]) == %{
             "error" => %{
               "message" => "`linear_create_comment` requires a non-empty `body` string."
             }
           }

    missing_state =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"stateName" => "   "},
        current_issue_id: "issue-123",
        state_updater: fn _issue_id, _state_name -> flunk("state updater should not be called") end
      )

    assert Jason.decode!(missing_state["output"]) == %{
             "error" => %{
               "message" => "`linear_update_issue_state` requires a non-empty `stateName` string."
             }
           }
  end

  test "Linear handoff tools format tracker failures" do
    comment_response =
      DynamicTool.execute(
        "linear_create_comment",
        %{"issueId" => "issue-123", "body" => "Done"},
        comment_creator: fn _issue_id, _body -> {:error, :comment_create_failed} end
      )

    assert comment_response["success"] == false

    assert Jason.decode!(comment_response["output"]) == %{
             "error" => %{
               "message" => "Linear comment creation did not report success."
             }
           }

    state_response =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"issueId" => "issue-123", "stateName" => "Human Review"},
        state_updater: fn _issue_id, _state_name -> {:error, :state_not_found} end
      )

    assert Jason.decode!(state_response["output"]) == %{
             "error" => %{
               "message" => "Linear workflow state was not found for the issue's team."
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
