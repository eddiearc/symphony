defmodule Symphonyctl.Issue do
  @moduledoc """
  Creates and reads Linear issues for Symphony workflows.
  """

  @project_lookup_query """
  query SymphonyctlProjectLookup($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        slugId
        teams(first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation SymphonyctlCreateIssue(
    $projectId: String!
    $teamId: String!
    $title: String!
    $description: String!
  ) {
    issueCreate(
      input: {
        projectId: $projectId
        teamId: $teamId
        title: $title
        description: $description
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        state {
          name
        }
      }
    }
  }
  """

  @issue_by_identifier_query """
  query SymphonyctlIssueByIdentifier($identifier: String!) {
    issues(filter: {identifier: {eq: $identifier}}, first: 1) {
      nodes {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @issue_by_id_query """
  query SymphonyctlIssueById($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      url
      state {
        name
      }
    }
  }
  """

  @type issue_result :: %{
          id: String.t(),
          identifier: String.t(),
          state: String.t() | nil,
          title: String.t(),
          url: String.t() | nil
        }

  @type deps :: %{
          optional(:graphql) => (String.t(), map(), map() -> {:ok, map()} | {:error, term()})
        }

  @spec create(map(), map(), deps()) :: {:ok, issue_result()} | {:error, term()}
  def create(attrs, config, deps \\ runtime_deps())
      when is_map(attrs) and is_map(config) and is_map(deps) do
    with {:ok, title} <- fetch_required(attrs, :title),
         description <- Map.get(attrs, :description, ""),
         {:ok, %{project_id: project_id, team_id: team_id}} <- resolve_project_context(attrs, config, deps),
         {:ok, response} <-
           deps.graphql.(
             @issue_create_mutation,
             %{projectId: project_id, teamId: team_id, title: title, description: description},
             config
           ),
         {:ok, issue} <- extract_created_issue(response) do
      {:ok, issue}
    end
  end

  @spec fetch(String.t(), map(), deps()) :: {:ok, issue_result()} | {:error, term()}
  def fetch(issue_ref, config, deps \\ runtime_deps())
      when is_binary(issue_ref) and is_map(config) and is_map(deps) do
    {query, variables} =
      if Regex.match?(~r/^[A-Za-z]+-\d+$/, issue_ref) do
        {@issue_by_identifier_query, %{identifier: issue_ref}}
      else
        {@issue_by_id_query, %{id: issue_ref}}
      end

    with {:ok, response} <- deps.graphql.(query, variables, config),
         {:ok, issue} <- extract_issue(response, query) do
      {:ok, issue}
    end
  end

  defp runtime_deps do
    %{
      graphql: &graphql/3
    }
  end

  defp resolve_project_context(attrs, config, deps) do
    with {:ok, project_slug} <- fetch_project_slug(attrs, config),
         {:ok, response} <- deps.graphql.(@project_lookup_query, %{slug: project_slug}, config),
         {:ok, project_id, team_id} <- extract_project_and_team(response) do
      {:ok, %{project_id: project_id, team_id: Map.get(attrs, :team_id, team_id)}}
    end
  end

  defp fetch_project_slug(attrs, config) do
    case Map.get(attrs, :project_slug) || get_in(config, [:linear, :project_slug]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_project_slug}
    end
  end

  defp extract_project_and_team(%{"data" => %{"projects" => %{"nodes" => [project | _]}}}) do
    team_id = get_in(project, ["teams", "nodes", Access.at(0), "id"])

    case {project["id"], team_id} do
      {project_id, team_id} when is_binary(project_id) and is_binary(team_id) ->
        {:ok, project_id, team_id}

      _ ->
        {:error, :project_team_not_found}
    end
  end

  defp extract_project_and_team(%{"errors" => errors}), do: {:error, {:linear_errors, errors}}
  defp extract_project_and_team(_response), do: {:error, :project_not_found}

  defp extract_created_issue(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}) do
    {:ok, normalize_issue(issue)}
  end

  defp extract_created_issue(%{"errors" => errors}), do: {:error, {:linear_errors, errors}}
  defp extract_created_issue(_response), do: {:error, :issue_create_failed}

  defp extract_issue(%{"data" => %{"issues" => %{"nodes" => [issue | _]}}}, @issue_by_identifier_query) do
    {:ok, normalize_issue(issue)}
  end

  defp extract_issue(%{"data" => %{"issue" => issue}}, @issue_by_id_query) when is_map(issue) do
    {:ok, normalize_issue(issue)}
  end

  defp extract_issue(%{"errors" => errors}, _query), do: {:error, {:linear_errors, errors}}
  defp extract_issue(_response, _query), do: {:error, :issue_not_found}

  defp normalize_issue(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      state: get_in(issue, ["state", "name"]),
      title: issue["title"],
      url: issue["url"]
    }
  end

  defp graphql(query, variables, config) do
    with {:ok, api_url} <- fetch_config_value(config, [:linear, :api_url], :missing_linear_api_url),
         {:ok, api_token} <- fetch_config_value(config, [:linear, :api_token], :missing_linear_api_token),
         {:ok, response} <-
           Req.post(api_url,
             json: %{query: query, variables: variables},
             headers: [{"authorization", api_token}]
           ) do
      {:ok, response.body}
    else
      {:error, _reason} = error -> error
    end
  end

  defp fetch_config_value(config, path, error_reason) do
    case get_in(config, path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error_reason}
    end
  end

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end
end
