defmodule SymphonyElixir.FailureCode do
  @moduledoc """Controlled failure taxonomy and run-level retry policy."""

  @codes ~w(runtime_offline network_interrupted queued_expired execution_timeout codex_inactivity platform_transient agent_error orchestrator_crash legacy_unclassified)a
  @retry_limits %{runtime_offline: 3, network_interrupted: 3, queued_expired: 0, execution_timeout: 2, codex_inactivity: 2, platform_transient: 2, agent_error: 0, orchestrator_crash: 0, legacy_unclassified: 0}

  @type t :: unquote(Enum.reduce(@codes, &{:|, [], [&1, &2]}))

  @spec values() :: [t()]
  def values, do: @codes

  @spec valid?(term()) :: boolean()
  def valid?(code) when is_atom(code), do: code in @codes
  def valid?(_), do: false

  @spec parse(term()) :: {:ok, t()} | {:error, :unknown_failure_code}
  def parse(code) when is_atom(code), do: if(valid?(code), do: {:ok, code}, else: {:error, :unknown_failure_code})
  def parse(code) when is_binary(code) do
    try do
      code |> String.to_existing_atom() |> parse()
    rescue
      ArgumentError -> {:error, :unknown_failure_code}
    end
  end
  def parse(_), do: {:error, :unknown_failure_code}

  @spec retry_limit(t()) :: non_neg_integer()
  def retry_limit(code) when is_atom(code), do: Map.fetch!(@retry_limits, code)

  @spec retry?(t(), non_neg_integer()) :: boolean()
  def retry?(code, attempts) when is_atom(code) and is_integer(attempts) and attempts >= 0,
    do: valid?(code) and attempts < retry_limit(code)

  @spec bound_detail(term(), pos_integer()) :: String.t()
  def bound_detail(detail, limit \\ 2_000) when is_integer(limit) and limit > 0 do
    detail |> inspect(limit: 20, printable_limit: limit) |> String.slice(0, limit)
  end
end
