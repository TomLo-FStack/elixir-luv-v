defmodule Elv.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_session(config) when is_map(config) do
    DynamicSupervisor.start_child(__MODULE__, {Elv.SessionServer, config})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
