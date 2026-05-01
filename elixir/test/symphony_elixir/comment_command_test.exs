defmodule SymphonyElixir.CommentCommandTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.CommentCommand
  alias SymphonyElixir.Orchestrator.State

  test "parses only explicit command prefixes on the first non-blank line" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", state: "Backlog"}

    assert CommentCommand.command_prefixes() == [
             "/approve-plan",
             "/block",
             "/revise-plan",
             "/rework-pr",
             "/roadmap-review",
             "/split-task",
             "/unblock"
           ]

    assert {:ok, command} =
             CommentCommand.parse(issue, %{
               id: "comment-1",
               body: "\n\n/roadmap-review current board"
             })

    assert command.command == "/roadmap-review"
    assert command.arguments == "current board"
    assert command.route == :planner

    assert {:ok, string_keyed} =
             CommentCommand.parse(issue, %{
               "id" => "comment-string",
               "body" => "/block waiting on owner"
             })

    assert string_keyed.route == :planner
    assert string_keyed.arguments == "waiting on owner"

    assert :ignore = CommentCommand.parse(issue, %{id: "comment-2", body: "please /roadmap-review"})
    assert :ignore = CommentCommand.parse(issue, %{id: "comment-3", body: "/unknown"})
    assert :ignore = CommentCommand.parse(issue, %{id: "comment-4", body: ""})
    assert :ignore = CommentCommand.parse(issue, %{id: "comment-5"})
    assert :ignore = CommentCommand.parse(issue, "not a comment")
  end

  test "dispatches planner commands once and ignores ordinary comments" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    state = %State{max_concurrent_agents: 4}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    planner_path = Workflow.workflow_file_path() |> Path.dirname() |> Path.join("WORKFLOW_PLANNER.md")
    write_workflow_file!(planner_path, prompt: "Symphony Planner Workflow")

    entries = [
      %{issue: issue, comment: %{id: "comment-1", body: "ordinary discussion"}},
      %{issue: issue, comment: %{id: "comment-2", body: "/roadmap-review"}},
      %{issue: issue, comment: %{id: "comment-2", body: "/roadmap-review"}}
    ]

    test_pid = self()

    state =
      Orchestrator.process_comment_commands_for_test(entries, state,
        dispatch_fun: fn dispatched_issue, state_acc, run_opts ->
          send(test_pid, {:dispatched, dispatched_issue.identifier, run_opts})
          state_acc
        end
      )

    assert_receive {:dispatched, "HIN-1", run_opts}
    assert run_opts[:prompt_template] =~ "Symphony Planner Workflow"
    assert run_opts[:comment_command_context].command == "/roadmap-review"
    assert run_opts[:continuation_states] == ["Backlog"]
    assert run_opts[:max_turns] >= 2
    assert_receive {:memory_tracker_comment, "issue-1", marker_body}
    assert marker_body =~ "Symphony command marker"
    assert marker_body =~ "command_comment_id: comment-2"
    assert marker_body =~ "command: /roadmap-review"
    assert marker_body =~ "status: claimed"
    refute_receive {:dispatched, _, _}
    assert MapSet.member?(state.comment_command_debounce_ids, "comment-2")
    refute MapSet.member?(state.comment_command_debounce_ids, "comment-1")
  end

  test "skips comment commands that already have durable Linear markers" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    planner_path = Workflow.workflow_file_path() |> Path.dirname() |> Path.join("WORKFLOW_PLANNER.md")
    write_workflow_file!(planner_path, prompt: "Symphony Planner Workflow")

    entries = [
      %{issue: issue, comment: %{id: "comment-1", body: "/roadmap-review"}},
      %{
        issue: issue,
        comment: %{
          id: "marker-1",
          body: """
          Symphony command marker
          command_comment_id: comment-1
          command: /roadmap-review
          status: claimed
          """
        }
      }
    ]

    Orchestrator.process_comment_commands_for_test(entries, %State{max_concurrent_agents: 4},
      dispatch_fun: fn _issue, state_acc, _run_opts ->
        flunk("marked commands must not dispatch")
        state_acc
      end
    )

    refute_receive {:memory_tracker_comment, _, _}
  end

  test "does not dispatch when command marker creation fails" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    planner_path = Workflow.workflow_file_path() |> Path.dirname() |> Path.join("WORKFLOW_PLANNER.md")
    write_workflow_file!(planner_path, prompt: "Symphony Planner Workflow")

    state =
      Orchestrator.process_comment_commands_for_test(
        [%{issue: issue, comment: %{id: "comment-1", body: "/roadmap-review"}}],
        %State{max_concurrent_agents: 4},
        dispatch_fun: fn _issue, state_acc, _run_opts ->
          flunk("commands must not dispatch unless the durable marker is written")
          state_acc
        end
      )

    refute MapSet.member?(state.comment_command_debounce_ids, "comment-1")
    refute_receive {:memory_tracker_comment, _, _}
  end

  test "does not dispatch planner commands for terminal issues" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Done plan", state: "Done"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    planner_path = Workflow.workflow_file_path() |> Path.dirname() |> Path.join("WORKFLOW_PLANNER.md")
    write_workflow_file!(planner_path, prompt: "Symphony Planner Workflow")

    Orchestrator.process_comment_commands_for_test(
      [%{issue: issue, comment: %{id: "comment-1", body: "/roadmap-review"}}],
      %State{max_concurrent_agents: 4},
      dispatch_fun: fn _issue, state_acc, _run_opts ->
        flunk("terminal planner commands must not dispatch")
        state_acc
      end
    )

    refute_receive {:memory_tracker_comment, _, _}
  end

  test "acknowledges approve-plan without dispatching" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_turns: 1)

    state =
      Orchestrator.process_comment_commands_for_test(
        [%{issue: issue, comment: %{id: "comment-1", body: "/approve-plan"}}],
        %State{max_concurrent_agents: 4},
        dispatch_fun: fn _issue, state_acc, _run_opts ->
          flunk("approve-plan must not dispatch an agent")
          state_acc
        end
      )

    assert_receive {:memory_tracker_comment, "issue-1", marker_body}
    assert marker_body =~ "Symphony command marker"
    assert marker_body =~ "command_comment_id: comment-1"
    assert_receive {:memory_tracker_comment, "issue-1", body}
    assert body =~ "Acknowledged `/approve-plan`"
    assert body =~ "will not move the issue to `Todo` automatically"
    assert MapSet.member?(state.comment_command_debounce_ids, "comment-1")
  end

  test "routes rework-pr only from In Review" do
    review_issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Review", state: "In Review"}
    todo_issue = %Issue{id: "issue-2", identifier: "HIN-2", title: "Todo", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    test_pid = self()

    Orchestrator.process_comment_commands_for_test(
      [
        %{issue: review_issue, comment: %{id: "comment-1", body: "/rework-pr fix docs"}},
        %{issue: todo_issue, comment: %{id: "comment-2", body: "/rework-pr too early"}}
      ],
      %State{max_concurrent_agents: 4},
      dispatch_fun: fn dispatched_issue, state_acc, run_opts ->
        send(test_pid, {:dispatched, dispatched_issue.identifier, run_opts})
        state_acc
      end
    )

    assert_receive {:dispatched, "HIN-1", run_opts}
    assert run_opts[:comment_command_context].command == "/rework-pr"
    assert run_opts[:comment_command_context].arguments == "fix docs"
    assert run_opts[:continuation_states] == ["In Review"]
    assert run_opts[:max_turns] >= 2
    assert_receive {:memory_tracker_comment, "issue-1", marker_body}
    assert marker_body =~ "command_comment_id: comment-1"
    assert_receive {:memory_tracker_comment, "issue-2", body}
    assert body =~ "Symphony command marker"
    assert body =~ "command_comment_id: comment-2"
    assert_receive {:memory_tracker_comment, "issue-2", body}
    assert body =~ "only routes issues that are already in `In Review`"
  end
end
