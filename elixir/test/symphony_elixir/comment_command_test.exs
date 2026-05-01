defmodule SymphonyElixir.CommentCommandTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.CommentCommand
  alias SymphonyElixir.Orchestrator.State

  test "parses only explicit command prefixes on the first non-blank line" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", state: "Backlog"}

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
  end

  test "dispatches planner commands once and ignores ordinary comments" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    state = %State{max_concurrent_agents: 4}
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
    refute_receive {:dispatched, _, _}
    assert MapSet.member?(state.seen_comment_command_ids, "comment-2")
    refute MapSet.member?(state.seen_comment_command_ids, "comment-1")
  end

  test "acknowledges approve-plan without dispatching" do
    issue = %Issue{id: "issue-1", identifier: "HIN-1", title: "Plan", state: "Backlog"}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    state =
      Orchestrator.process_comment_commands_for_test(
        [%{issue: issue, comment: %{id: "comment-1", body: "/approve-plan"}}],
        %State{max_concurrent_agents: 4},
        dispatch_fun: fn _issue, state_acc, _run_opts ->
          flunk("approve-plan must not dispatch an agent")
          state_acc
        end
      )

    assert_receive {:memory_tracker_comment, "issue-1", body}
    assert body =~ "Acknowledged `/approve-plan`"
    assert body =~ "will not move the issue to `Todo` automatically"
    assert MapSet.member?(state.seen_comment_command_ids, "comment-1")
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
    assert_receive {:memory_tracker_comment, "issue-2", body}
    assert body =~ "only routes issues that are already in `In Review`"
  end
end
