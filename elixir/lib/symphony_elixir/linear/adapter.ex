defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @fetch_comments_query """
  query SymphonyFetchIssueComments($issueId: String!) {
    issue(id: $issueId) {
      comments(orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          user {
            name
            isMe
          }
        }
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyResolveLabelId($issueId: String!, $labelName: String!) {
    issue(id: $issueId) {
      labels {
        nodes {
          id
        }
      }
      team {
        labels(filter: {name: {eqCaseInsensitive: $labelName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @update_labels_mutation """
  mutation SymphonyUpdateIssueLabels($issueId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@fetch_comments_query, %{issueId: issue_id}),
         nodes when is_list(nodes) <-
           get_in(response, ["data", "issue", "comments", "nodes"]) do
      comments =
        Enum.map(nodes, fn node ->
          %{
            id: node["id"],
            body: node["body"],
            created_at: node["createdAt"],
            user_name: get_in(node, ["user", "name"]),
            is_bot: get_in(node, ["user", "isMe"]) == true
          }
        end)

      {:ok, comments}
    else
      nil -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_lookup_query, %{issueId: issue_id, labelName: label_name}),
         {:ok, current_label_ids} <- extract_current_label_ids(response),
         {:ok, new_label_id} <- extract_team_label_id(response),
         combined_ids <- Enum.uniq([new_label_id | current_label_ids]),
         {:ok, update_response} <-
           client_module().graphql(@update_labels_mutation, %{issueId: issue_id, labelIds: combined_ids}),
         true <- get_in(update_response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :label_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_update_failed}
    end
  end

  defp extract_current_label_ids(response) do
    case get_in(response, ["data", "issue", "labels", "nodes"]) do
      nodes when is_list(nodes) ->
        ids = Enum.map(nodes, & &1["id"]) |> Enum.reject(&is_nil/1)
        {:ok, ids}

      _ ->
        {:ok, []}
    end
  end

  defp extract_team_label_id(response) do
    case get_in(response, ["data", "issue", "team", "labels", "nodes", Access.at(0), "id"]) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :label_not_found}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
