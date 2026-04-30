defmodule Elv.VDaemon.Driver do
  @moduledoc false

  @type config :: map()
  @type state :: term()
  @type generation_spec :: map()
  @type artifact :: map()
  @type generation_record :: map()

  @callback start(config()) :: {:ok, state()} | {:error, binary()}
  @callback stop(state()) :: :ok
  @callback build(state(), generation_spec(), keyword()) ::
              {:ok, artifact(), state()} | {:error, binary(), state()}
  @callback load(state(), artifact(), keyword()) ::
              {:ok, map(), state()} | {:error, binary(), state()}
  @callback unload(state(), generation_record(), keyword()) ::
              {:ok, map(), state()} | {:error, binary(), state()}
  @callback recycle(state(), binary(), keyword()) ::
              {:ok, map(), state()} | {:error, binary(), state()}
  @callback metadata(state()) :: map()
end
