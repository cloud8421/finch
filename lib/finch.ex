defmodule Finch do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Finch.{PoolManager, Request, Response}

  use Supervisor

  @default_pool_size 10
  @default_pool_count 1

  @pool_config_schema [
    protocol: [
      type: {:one_of, [:http2, :http1]},
      doc: "The type of connection and pool to use",
      default: :http1
    ],
    size: [
      type: :pos_integer,
      doc: "Number of connections to maintain in each pool.",
      default: @default_pool_size
    ],
    count: [
      type: :pos_integer,
      doc: "Number of pools to start.",
      default: @default_pool_count
    ],
    conn_opts: [
      type: :keyword_list,
      doc:
        "These options are passed to `Mint.HTTP.connect/4` whenever a new connection is established. `:mode` is not configurable as Finch must control this setting. Typically these options are used to configure proxying, https settings, or connect timeouts.",
      default: []
    ]
  ]

  @typedoc """
  The `:name` provided to Finch in `start_link/1`.
  """
  @type name() :: atom()

  @typedoc """
  The stream function given to `stream/5`.
  """
  @type stream(acc) ::
          ({:status, integer} | {:headers, Mint.Types.headers()} | {:data, binary}, acc -> acc)

  @doc """
  Start an instance of Finch.

  ## Options

    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - A map specifying the configuration for your pools. The keys should be URLs
    provided as binaries, or the atom `:default` to provide a catch-all configuration to be used
    for any unspecified URLs. See "Pool Configuration Options" below for details on the possible
    map values. Default value is `%{default: [size: #{@default_pool_size}, count: #{
    @default_pool_count
  }]}`.

  ### Pool Configuration Options

  #{NimbleOptions.docs(@pool_config_schema)}
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name) || raise ArgumentError, "must supply a name"
    pools = Keyword.get(opts, :pools, []) |> pool_options!()
    {default_pool_config, pools} = Map.pop(pools, :default)

    config = %{
      registry_name: name,
      manager_name: manager_name(name),
      supervisor_name: pool_supervisor_name(name),
      default_pool_config: default_pool_config,
      pools: pools
    }

    Supervisor.start_link(__MODULE__, config, name: supervisor_name(name))
  end

  @impl true
  def init(config) do
    children = [
      {DynamicSupervisor, name: config.supervisor_name, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: config.registry_name, meta: [config: config]]},
      {PoolManager, config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp pool_options!(pools) do
    {:ok, default} = NimbleOptions.validate([], @pool_config_schema)

    Enum.reduce(pools, %{default: valid_opts_to_map(default)}, fn {destination, opts}, acc ->
      with {:ok, valid_destination} <- cast_destination(destination),
           {:ok, valid_pool_opts} <- cast_pool_opts(opts) do
        Map.put(acc, valid_destination, valid_pool_opts)
      else
        {:error, reason} ->
          raise ArgumentError,
                "got invalid configuration for pool #{inspect(destination)}! #{reason}"
      end
    end)
  end

  defp cast_destination(destination) do
    case destination do
      :default ->
        {:ok, destination}

      url when is_binary(url) ->
        cast_binary_destination(url)

      _ ->
        {:error, "invalid destination"}
    end
  end

  defp cast_binary_destination(url) when is_binary(url) do
    {scheme, host, port, _path, _query} = Finch.Request.parse_url(url)
    {:ok, {scheme, host, port}}
  end

  defp cast_pool_opts(opts) do
    with {:ok, valid} <- NimbleOptions.validate(opts, @pool_config_schema) do
      {:ok, valid_opts_to_map(valid)}
    end
  end

  defp valid_opts_to_map(valid) do
    %{
      size: valid[:size],
      count: valid[:count],
      conn_opts: valid[:conn_opts],
      protocol: valid[:protocol]
    }
  end

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"

  @doc """
  Builds an HTTP request to be sent with `request/3` or `stream/4`.
  """
  @spec build(Request.method(), Request.url(), Request.headers(), Request.body()) :: Request.t()
  defdelegate build(method, url, headers \\ [], body \\ nil), to: Request

  @doc """
  Streams an HTTP request and returns the accumulator.

  A function of arity 2 is expected as argument. The first argument
  is a tuple, as listed below, and the second argument is the
  accumulator. The function must return a potentially updated
  accumulator.

  ## Stream commands

    * `{:status, status}` - the status of the http response
    * `{:headers, headers}` - the headers of the http response
    * `{:data, data}` - a streaming section of the http body

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.

  """
  @spec stream(Request.t(), name(), acc, stream(acc), keyword) :: acc when acc: term()
  def stream(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    %{scheme: scheme, host: host, port: port} = req
    {pool, pool_mod} = PoolManager.get_pool(name, {scheme, host, port})
    pool_mod.request(pool, req, acc, fun, opts)
  end

  @doc """
  Sends an HTTP request and returns a `Finch.Response` struct.

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.

  """
  @spec request(Request.t(), name(), keyword()) ::
          {:ok, Response.t()} | {:error, Mint.Types.error()}
  def request(req, name, opts \\ [])

  def request(%Request{} = req, name, opts) do
    acc = {nil, [], []}

    fun = fn
      {:status, value}, {_, headers, body} -> {value, headers, body}
      {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
      {:data, value}, {status, headers, body} -> {status, headers, [value | body]}
    end

    with {:ok, {status, headers, body}} <- stream(req, name, acc, fun, opts) do
      {:ok,
       %Response{
         status: status,
         headers: headers,
         body: body |> Enum.reverse() |> IO.iodata_to_binary()
       }}
    end
  end

  # Catch-all for backwards compatibility below
  def request(name, method, url) do
    request(name, method, url, [])
  end

  def request(name, method, url, headers, body \\ nil, opts \\ []) do
    IO.warn("Finch.request/6 is deprecated, use Finch.build/4 + Finch.request/3 instead")

    build(method, url, headers, body)
    |> request(name, opts)
  end
end
