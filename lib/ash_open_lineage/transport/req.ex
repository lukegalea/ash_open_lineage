# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Transport.Req do
  @moduledoc """
  The default transport: `POST {http_base_url}/api/v1/lineage` with the event
  as the JSON body — the endpoint shape Marquez and friends expose.

  Configure:

      config :ash_open_lineage, http_base_url: "http://localhost:5000"

  A `2xx` reply is `:ok`; any other status, a transport failure, or a missing
  `:http_base_url` comes back as `{:error, term()}` — never a raise, so the
  notifier's logging path (not the host's write) absorbs outages.
  """

  @behaviour AshOpenLineage.Transport

  @path "/api/v1/lineage"

  @impl true
  def send(event) do
    case base_url() do
      nil ->
        {:error, :http_base_url_not_configured}

      base_url ->
        base_url
        |> String.trim_trailing("/")
        |> Kernel.<>(@path)
        |> post(event)
    end
  end

  defp post(url, event) do
    case Req.post(url, json: event) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  rescue
    exception -> {:error, exception}
  end

  defp base_url, do: Application.get_env(:ash_open_lineage, :http_base_url)
end
