defmodule SymphonyElixir.PipelineStore do
  @moduledoc """
  Compatibility loader that projects the legacy single WORKFLOW runtime
  into a synthetic default pipeline.
  """

  alias SymphonyElixir.{Pipeline, Workflow}

  @default_pipeline_id "default"

  @spec current() :: {:ok, Pipeline.t()} | {:error, term()}
  def current do
    workflow_path = Workflow.workflow_file_path()

    with {:ok, workflow} <- Workflow.current() do
      Pipeline.from_workflow(
        workflow,
        default_id: @default_pipeline_id,
        source_path: workflow_path,
        workflow_path: workflow_path
      )
    end
  end
end
