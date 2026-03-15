defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Pipeline, PipelineLoader, PipelineSupervisor, Workflow}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec pipelines(Conn.t(), map()) :: Conn.t()
  def pipelines(conn, _params) do
    json(
      conn,
      Presenter.pipelines_payload(
        pipelines_catalog(),
        &orchestrator_for_pipeline/1,
        snapshot_timeout_ms()
      )
    )
  end

  @spec pipeline(Conn.t(), map()) :: Conn.t()
  def pipeline(conn, %{"pipeline_id" => pipeline_id}) do
    with {:ok, pipeline} <- fetch_pipeline(pipeline_id),
         {:ok, payload} <-
           Presenter.pipeline_payload(
             pipeline,
             orchestrator_for_pipeline(pipeline_id),
             snapshot_timeout_ms()
           ) do
      json(conn, payload)
    else
      {:error, :pipeline_not_found} ->
        error_response(conn, 404, "pipeline_not_found", "Pipeline not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh_pipeline(Conn.t(), map()) :: Conn.t()
  def refresh_pipeline(conn, %{"pipeline_id" => pipeline_id}) do
    with {:ok, pipeline} <- fetch_pipeline(pipeline_id),
         {:ok, payload} <-
           Presenter.pipeline_refresh_payload(pipeline, orchestrator_for_pipeline(pipeline_id)) do
      conn
      |> put_status(202)
      |> json(payload)
    else
      {:error, :pipeline_not_found} ->
        error_response(conn, 404, "pipeline_not_found", "Pipeline not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec pause_pipeline(Conn.t(), map()) :: Conn.t()
  def pause_pipeline(conn, %{"pipeline_id" => pipeline_id}) do
    with {:ok, pipeline} <- fetch_pipeline(pipeline_id),
         {:ok, payload} <-
           Presenter.pipeline_pause_payload(pipeline, orchestrator_for_pipeline(pipeline_id)) do
      conn
      |> put_status(202)
      |> json(payload)
    else
      {:error, :pipeline_not_found} ->
        error_response(conn, 404, "pipeline_not_found", "Pipeline not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec resume_pipeline(Conn.t(), map()) :: Conn.t()
  def resume_pipeline(conn, %{"pipeline_id" => pipeline_id}) do
    with {:ok, pipeline} <- fetch_pipeline(pipeline_id),
         {:ok, payload} <-
           Presenter.pipeline_resume_payload(pipeline, orchestrator_for_pipeline(pipeline_id)) do
      conn
      |> put_status(202)
      |> json(payload)
    else
      {:error, :pipeline_not_found} ->
        error_response(conn, 404, "pipeline_not_found", "Pipeline not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp orchestrator_for_pipeline(pipeline_id) when is_binary(pipeline_id) do
    endpoint_orchestrators = Endpoint.config(:pipeline_orchestrators)

    if is_map(endpoint_orchestrators) and Map.has_key?(endpoint_orchestrators, pipeline_id) do
      Map.get(endpoint_orchestrators, pipeline_id)
    else
      case PipelineSupervisor.lookup(pipeline_id, pipeline_registry_name()) do
        {:ok, pid} ->
          pid

        :error ->
          fallback_orchestrator_for_pipeline(pipeline_id)
      end
    end
  end

  defp fallback_orchestrator_for_pipeline("default"), do: orchestrator()
  defp fallback_orchestrator_for_pipeline(_pipeline_id), do: nil

  defp fetch_pipeline(pipeline_id) when is_binary(pipeline_id) do
    case Enum.find(pipelines_catalog(), fn
           %Pipeline{id: id} -> id == pipeline_id
           _ -> false
         end) do
      %Pipeline{} = pipeline -> {:ok, pipeline}
      _ -> {:error, :pipeline_not_found}
    end
  end

  defp pipelines_catalog do
    case Endpoint.config(:pipelines) do
      pipelines when is_list(pipelines) and pipelines != [] ->
        pipelines

      _ ->
        configured_pipelines()
    end
  end

  defp configured_pipelines do
    case PipelineLoader.load_pipeline_root(Workflow.pipeline_root_path()) do
      {:ok, pipelines} -> pipelines
      {:error, _reason} -> []
    end
  end

  defp pipeline_registry_name do
    Endpoint.config(:pipeline_registry_name) || SymphonyElixir.PipelineRegistry
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
