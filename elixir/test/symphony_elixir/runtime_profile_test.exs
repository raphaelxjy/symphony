defmodule SymphonyElixir.RuntimeProfileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.RuntimeProfile
  alias SymphonyElixir.Config.Schema.Codex

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
    expected = ~s(codex --config "model=\\"gpt-5.5\\"" --config "model_reasoning_effort=\\"high\\"" app-server)
    template = ~s(codex --config "model=\\"{{ codex.model }}\\"" --config "model_reasoning_effort=\\"{{ codex.reasoning }}\\"" app-server)

    assert {:ok, ^expected} = RuntimeProfile.render_command(template, profile)
  end

  test "handles custom and malformed profile configuration defensively" do
    assert {:ok, %{reasoning: "xhigh", complexity: "high", fallback?: false}} =
             RuntimeProfile.resolve(
               ["High", nil],
               %Codex{complexity_profiles: %{"HIGH" => %{"reasoning" => "xhigh"}}}
             )

    assert {:ok, %{reasoning: "low", complexity: "low", fallback?: false}} =
             RuntimeProfile.resolve(["Low"], %Codex{complexity_profiles: "not a map"})

    assert {:ok, %{reasoning: "medium", fallback?: true}} =
             RuntimeProfile.resolve([], %Codex{default_profile: "not a map"})

    assert_raise ArgumentError, ~r/Codex profile is missing required model/, fn ->
      RuntimeProfile.default(%Codex{default_profile: %{"model" => ""}})
    end
  end

  test "reports codex command template render and parse errors" do
    {:ok, profile} = RuntimeProfile.resolve(["High"], Config.settings!().codex)

    assert {:error, {:codex_command_template_error, _reason}} =
             RuntimeProfile.render_command("codex {{ missing.value }}", profile)

    assert {:error, {:codex_command_template_error, _message}} =
             RuntimeProfile.render_command("{% if codex.model %}", profile)
  end
end
