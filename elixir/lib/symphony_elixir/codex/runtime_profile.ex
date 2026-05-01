defmodule SymphonyElixir.Codex.RuntimeProfile do
  @moduledoc """
  Resolves the Codex launch profile for an issue before app-server starts.
  """

  alias SymphonyElixir.Config.Schema.Codex

  @default_profile %{"model" => "gpt-5.5", "reasoning" => "medium"}
  @default_complexity_profiles %{
    "low" => %{"model" => "gpt-5.5", "reasoning" => "low"},
    "medium" => %{"model" => "gpt-5.5", "reasoning" => "medium"},
    "high" => %{"model" => "gpt-5.5", "reasoning" => "high"},
    "extra_high" => %{"model" => "gpt-5.5", "reasoning" => "xhigh"}
  }
  @known_complexities Map.keys(@default_complexity_profiles)

  @type t :: %{
          model: String.t(),
          reasoning: String.t(),
          complexity: String.t() | nil,
          source: :complexity_label | :default,
          fallback?: boolean()
        }

  @spec resolve([String.t()], Codex.t()) :: {:ok, t()} | {:error, term()}
  def resolve(labels, %Codex{} = codex) when is_list(labels) do
    case complexity_matches(labels) do
      [] ->
        {:ok, build_profile(default_profile(codex), nil, :default)}

      [{complexity, _label}] ->
        complexity
        |> profile_for_complexity(codex)
        |> build_profile(complexity, :complexity_label)
        |> then(&{:ok, &1})

      matches ->
        {:error, {:multiple_complexity_labels, Enum.map(matches, fn {_complexity, label} -> label end)}}
    end
  end

  @spec default(Codex.t()) :: t()
  def default(%Codex{} = codex), do: build_profile(default_profile(codex), nil, :default)

  @spec render_command(String.t(), t()) :: {:ok, String.t()} | {:error, term()}
  def render_command(command_template, profile) when is_binary(command_template) and is_map(profile) do
    command_template
    |> Solid.parse!()
    |> Solid.render(
      %{
        "codex" => %{
          "model" => Map.fetch!(profile, :model),
          "reasoning" => Map.fetch!(profile, :reasoning),
          "complexity" => Map.get(profile, :complexity),
          "source" => Map.fetch!(profile, :source),
          "fallback" => Map.fetch!(profile, :fallback?)
        }
      },
      strict_variables: true,
      strict_filters: true
    )
    |> case do
      {:ok, rendered, _warnings} -> {:ok, IO.iodata_to_binary(rendered)}
      {:error, reason} -> {:error, {:codex_command_template_error, reason}}
    end
  rescue
    error ->
      {:error, {:codex_command_template_error, Exception.message(error)}}
  end

  @spec complexity_matches([String.t()]) :: [{String.t(), String.t()}]
  def complexity_matches(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn label ->
      case normalize_complexity_label(label) do
        nil -> []
        complexity -> [{complexity, label}]
      end
    end)
    |> Enum.uniq_by(fn {complexity, _label} -> complexity end)
  end

  defp normalize_complexity_label(label) when is_binary(label) do
    normalized =
      label
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/^complexity\s*\/\s*/, "")
      |> String.replace(~r/[\s-]+/, "_")

    if normalized in @known_complexities, do: normalized
  end

  defp normalize_complexity_label(_label), do: nil

  defp profile_for_complexity(complexity, %Codex{} = codex) do
    configured_profiles = normalize_profile_collection(codex.complexity_profiles)

    @default_complexity_profiles
    |> Map.merge(configured_profiles, fn _key, default, configured ->
      Map.merge(default, configured)
    end)
    |> Map.fetch!(complexity)
  end

  defp default_profile(%Codex{} = codex) do
    Map.merge(@default_profile, normalize_profile(codex.default_profile))
  end

  defp build_profile(profile, complexity, source) do
    %{
      model: required_profile_value(profile, "model"),
      reasoning: required_profile_value(profile, "reasoning"),
      complexity: complexity,
      source: source,
      fallback?: source == :default
    }
  end

  defp required_profile_value(profile, key) do
    value = Map.get(profile, key)

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      raise ArgumentError, "Codex profile is missing required #{key}"
    end
  end

  defp normalize_profile_collection(value) when is_map(value) do
    Map.new(value, fn {key, profile} ->
      normalized_key =
        key
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[\s-]+/, "_")

      {normalized_key, normalize_profile(profile)}
    end)
  end

  defp normalize_profile_collection(_value), do: %{}

  defp normalize_profile(value) when is_map(value) do
    Map.new(value, fn {key, profile_value} -> {to_string(key), profile_value} end)
  end

  defp normalize_profile(_value), do: %{}
end
