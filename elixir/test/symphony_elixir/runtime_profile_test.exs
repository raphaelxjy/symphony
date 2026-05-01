defmodule SymphonyElixir.RuntimeProfileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.RuntimeProfile

  test "resolves configured complexity labels to gpt-5.5 reasoning tiers" do
    codex = Config.settings!().codex

    assert {:ok, %{model: "gpt-5.5", reasoning: "low", complexity: "low", fallback?: false}} =
             RuntimeProfile.resolve(["Workflow", "Low"], codex)

    assert {:ok, %{model: "gpt-5.5", reasoning: "medium", complexity: "medium", fallback?: false}} =
             RuntimeProfile.resolve(["Workflow", "Medium"], codex)

    assert {:ok, %{model: "gpt-5.5", reasoning: "high", complexity: "high", fallback?: false}} =
             RuntimeProfile.resolve(["Workflow", "High"], codex)

    assert {:ok, %{model: "gpt-5.5", reasoning: "xhigh", complexity: "extra_high", fallback?: false}} =
             RuntimeProfile.resolve(["Workflow", "Extra high"], codex)
  end

  test "accepts grouped complexity label spelling" do
    assert {:ok, %{model: "gpt-5.5", reasoning: "high", complexity: "high", fallback?: false}} =
             RuntimeProfile.resolve(["Category/Workflow", "Complexity/High"], Config.settings!().codex)
  end

  test "falls back to the default profile when no complexity label exists" do
    assert {:ok, %{model: "gpt-5.5", reasoning: "medium", complexity: nil, fallback?: true}} =
             RuntimeProfile.resolve(["Workflow"], Config.settings!().codex)
  end

  test "rejects issues with multiple complexity labels" do
    assert {:error, {:multiple_complexity_labels, labels}} =
             RuntimeProfile.resolve(["Workflow", "Low", "Complexity/High"], Config.settings!().codex)

    assert labels == ["Low", "Complexity/High"]
  end

  test "renders selected profile into the codex command template" do
    {:ok, profile} = RuntimeProfile.resolve(["High"], Config.settings!().codex)

    assert {:ok, "codex --config \"model=\\\"gpt-5.5\\\"\" --config \"model_reasoning_effort=\\\"high\\\"\" app-server"} =
             RuntimeProfile.render_command(
               "codex --config \"model=\\\"{{ codex.model }}\\\"\" --config \"model_reasoning_effort=\\\"{{ codex.reasoning }}\\\"\" app-server",
               profile
             )
  end
end
