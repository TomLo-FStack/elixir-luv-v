defmodule Elv.ExecutionBackend do
  @moduledoc """
  Behaviour for ELV execution backends.

  The current backend is replay-based. Future backends can use live reload,
  plugins, or isolated workers while keeping the session surface stable.
  """

  @type engine :: term()
  @type eval_result ::
          {:ok, output :: binary(), elapsed_us :: non_neg_integer(), engine()}
          | {:error, message :: binary(), engine()}

  @callback start(v_path :: binary(), cwd :: binary(), opts :: keyword()) ::
              {:ok, engine()} | {:error, binary()}
  @callback close(engine()) :: :ok
  @callback restart(engine(), opts :: keyword()) :: {:ok, engine()} | {:error, binary()}
  @callback eval(engine(), code :: binary(), opts :: keyword()) :: eval_result()
  @callback run_v(engine(), args :: [binary()], opts :: keyword()) ::
              {binary(), non_neg_integer()}
  @callback split_forms(code :: binary()) :: [binary()]
  @callback metadata(engine()) :: map()
end
