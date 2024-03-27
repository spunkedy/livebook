defmodule Livebook.Application do
  use Application

  def start(_type, _args) do
    setup_optional_dependencies()
    ensure_directories!()
    set_local_file_system!()
    ensure_distribution!()
    validate_hostname_resolution!()
    set_cookie()

    children = get_children()

    opts = [strategy: :one_for_one, name: Livebook.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _} = result ->
        load_lb_env_vars()
        create_teams_hub()
        clear_env_vars()
        display_startup_info()
        Livebook.Hubs.connect_hubs()

        unless serverless?() do
          deploy_apps()
        end

        result

      {:error, error} ->
        Livebook.Config.abort!(Application.format_error(error))
    end
  end

  # break this out to allow for easier test-ability
  def get_children() do
    [
      # Start the Telemetry supervisor
      LivebookWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Livebook.PubSub},
      # Start a supervisor for Livebook tasks
      {Task.Supervisor, name: Livebook.TaskSupervisor},
      # Start the storage module
      Livebook.Storage,
      # Run migrations as soon as the storage is running
      Livebook.Migration,
      # Start the periodic version check
      Livebook.UpdateCheck,
      # Periodic measurement of system resources
      Livebook.SystemResources,
      # Start the notebook manager server
      Livebook.NotebookManager,
      # Start the tracker server on this node
      {Livebook.Tracker, pubsub_server: Livebook.PubSub},
      # Start the supervisor dynamically managing apps
      {DynamicSupervisor, name: Livebook.AppSupervisor, strategy: :one_for_one},
      # Start the supervisor dynamically managing sessions
      {DynamicSupervisor, name: Livebook.SessionSupervisor, strategy: :one_for_one},
      # Start the server responsible for associating files with sessions
      Livebook.Session.FileGuard,
      # Start the node pool for managing node names
      Livebook.Runtime.NodePool,
      # Start the unique task dependencies
      Livebook.Utils.UniqueTask,
      # Start the registry for managing unique connections
      {Registry, keys: :unique, name: Livebook.HubsRegistry},
      # Start the supervisor dynamically managing connections
      {DynamicSupervisor, name: Livebook.HubsSupervisor, strategy: :one_for_one}
    ] ++
      if serverless?() do
        []
      else
        {_type, module, key} = Livebook.Config.identity_provider()

        iframe_server_specs() ++
          [
            {module, name: LivebookWeb.ZTA, identity_key: key},
            {DNSCluster, query: Application.get_env(:livebook, :dns_cluster_query) || :ignore},
            # We skip the access url as we do our own logging below
            {LivebookWeb.Endpoint, log_access_url: false}
          ] ++ app_specs()
      end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    LivebookWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_optional_dependencies() do
    if Livebook.Config.aws_credentials?() do
      {:ok, _} = Application.ensure_all_started(:aws_credentials)
    end
  end

  defp ensure_directories!() do
    File.mkdir_p!(Livebook.Config.home())
    File.mkdir_p!(Livebook.Config.data_path())
  end

  defp set_local_file_system!() do
    home =
      Livebook.Config.home()
      |> Livebook.FileSystem.Utils.ensure_dir_path()

    local_file_system = Livebook.FileSystem.Local.new(default_path: home)
    :persistent_term.put(:livebook_local_file_system, local_file_system)
  end

  defp ensure_distribution!() do
    unless Node.alive?() do
      case System.cmd("epmd", ["-daemon"]) do
        {_, 0} ->
          :ok

        _ ->
          Livebook.Config.abort!("""
          Could not start epmd (Erlang Port Mapper Driver). Livebook uses epmd to \
          talk to different runtimes. You may have to start epmd explicitly by calling:

              epmd -daemon

          Or by calling:

              elixir --sname test -e "IO.puts node()"

          Then you can try booting Livebook again
          """)
      end

      {type, name} = get_node_type_and_name()

      case Node.start(name, type) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Livebook.Config.abort!("Could not start distributed node: #{inspect(reason)}")
      end
    end
  end

  import Record
  defrecordp :hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl")

  # See https://github.com/livebook-dev/livebook/issues/302
  defp validate_hostname_resolution!() do
    unless Livebook.Config.longname() do
      [nodename, hostname] = node() |> Atom.to_charlist() |> :string.split(~c"@")

      # erl_epmd names do not support ipv6 resolution by default,
      # unless inet6 is configured, so we attempt both.
      gethostbyname =
        with {:error, _} <- :inet.gethostbyname(hostname, :inet, :infinity),
             {:error, _} <- :inet.gethostbyname(hostname, :inet6, :infinity),
             do: :error

      with {:ok, hostent(h_addr_list: [epmd_addr | _])} <- gethostbyname,
           {:ok, nodenames} <- :erl_epmd.names(epmd_addr),
           true <- List.keymember?(nodenames, nodename, 0) do
        :ok
      else
        _ ->
          hint =
            cond do
              is_nil(System.get_env("LIVEBOOK_DESKTOP")) ->
                """
                  * If you are using Livebook's CLI or from source, consider using longnames:

                        livebook server --name livebook@127.0.0.1
                        elixir --name livebook@127.0.0.1 -S mix phx.server
                """

              match?({:win32, _}, :os.type()) ->
                path =
                  Path.join(
                    System.get_env("USERPROFILE", "%USERPROFILE%"),
                    ".livebookdesktop.bat"
                  )

                """
                  * Configure your Livebook Desktop to use long names by creating a file at #{path} with:

                        set LIVEBOOK_DISTRIBUTION=name
                        set LIVEBOOK_NODE=livebook@127.0.0.1
                """

              true ->
                path = Path.join(System.get_env("HOME", "~"), ".livebookdesktop.sh")

                """
                  * Configure your Livebook Desktop to use long names by creating a file at #{path} with:

                        export LIVEBOOK_DISTRIBUTION=name
                        export LIVEBOOK_NODE=livebook@127.0.0.1
                """
            end

          Livebook.Config.abort!("""
          Your hostname \"#{hostname}\" does not resolve to a loopback address (127.0.0.0/8), \
          which indicates something wrong in your OS configuration, or EPMD is not running.

          To address this issue, you might:

            * Consult our Installation FAQ:
              https://github.com/livebook-dev/livebook/wiki/Installation-FAQ

          #{hint}\

            * If the issue persists, please file a bug report

          """)
      end
    end
  end

  defp set_cookie() do
    cookie = Application.fetch_env!(:livebook, :cookie)
    Node.set_cookie(cookie)
  end

  defp get_node_type_and_name() do
    Application.get_env(:livebook, :node) || {:shortnames, random_short_name()}
  end

  defp random_short_name() do
    :"livebook_#{Livebook.Utils.random_short_id()}"
  end

  defp display_startup_info() do
    if Process.whereis(LivebookWeb.Endpoint) &&
         Phoenix.Endpoint.server?(:livebook, LivebookWeb.Endpoint) do
      IO.puts("[Livebook] Application running at #{LivebookWeb.Endpoint.access_url()}")
    end
  end

  defp clear_env_vars() do
    for {var, _} <- System.get_env(), config_env_var?(var) do
      System.delete_env(var)
    end
  end

  defp load_lb_env_vars() do
    secrets =
      for {"LB_" <> name = var, value} <- System.get_env() do
        System.delete_env(var)

        %Livebook.Secrets.Secret{
          name: name,
          value: value,
          hub_id: nil
        }
      end

    Livebook.Secrets.set_startup_secrets(secrets)
  end

  defp create_teams_hub() do
    teams_key = System.get_env("LIVEBOOK_TEAMS_KEY")
    auth = System.get_env("LIVEBOOK_TEAMS_AUTH")

    cond do
      teams_key && auth ->
        case String.split(auth, ":") do
          ["offline", name, public_key] ->
            create_offline_hub(teams_key, name, public_key)

          ["online", name, org_id, org_key_id, agent_key] ->
            create_online_hub(teams_key, name, org_id, org_key_id, agent_key)

          _ ->
            Livebook.Config.abort!("Invalid LIVEBOOK_TEAMS_AUTH configuration.")
        end

      teams_key || auth ->
        Livebook.Config.abort!(
          "You must specify both LIVEBOOK_TEAMS_KEY and LIVEBOOK_TEAMS_AUTH."
        )

      true ->
        :ok
    end
  end

  defp create_offline_hub(teams_key, name, public_key) do
    encrypted_secrets = System.get_env("LIVEBOOK_TEAMS_SECRETS")
    encrypted_file_systems = System.get_env("LIVEBOOK_TEAMS_FS")
    secret_key = Livebook.Teams.derive_key(teams_key)
    id = "team-#{name}"

    secrets =
      if encrypted_secrets do
        case Livebook.Teams.decrypt(encrypted_secrets, secret_key) do
          {:ok, json} ->
            for {name, value} <- Jason.decode!(json),
                do: %Livebook.Secrets.Secret{
                  name: name,
                  value: value,
                  hub_id: id
                }

          :error ->
            Livebook.Config.abort!(
              "You specified LIVEBOOK_TEAMS_SECRETS, but we couldn't decrypt with the given LIVEBOOK_TEAMS_KEY."
            )
        end
      else
        []
      end

    file_systems =
      if encrypted_file_systems do
        case Livebook.Teams.decrypt(encrypted_file_systems, secret_key) do
          {:ok, json} ->
            for %{"type" => type} = dumped_data <- Jason.decode!(json),
                do: Livebook.FileSystems.load(type, dumped_data)

          :error ->
            Livebook.Config.abort!(
              "You specified LIVEBOOK_TEAMS_FS, but we couldn't decrypt with the given LIVEBOOK_TEAMS_KEY."
            )
        end
      else
        []
      end

    Livebook.Hubs.save_hub(%Livebook.Hubs.Team{
      id: "team-#{name}",
      hub_name: name,
      hub_emoji: "⭐️",
      user_id: nil,
      org_id: nil,
      org_key_id: nil,
      session_token: "",
      teams_key: teams_key,
      org_public_key: public_key,
      offline: %Livebook.Hubs.Team.Offline{
        secrets: secrets,
        file_systems: file_systems
      }
    })
  end

  defp create_online_hub(teams_key, name, org_id, org_key_id, agent_key) do
    Livebook.Hubs.save_hub(%Livebook.Hubs.Team{
      id: "team-#{name}",
      hub_name: name,
      hub_emoji: "💡",
      user_id: nil,
      org_id: org_id,
      org_key_id: org_key_id,
      session_token: agent_key,
      teams_key: teams_key,
      org_public_key: nil,
      offline: nil
    })
  end

  defp config_env_var?("LIVEBOOK_" <> _), do: true
  defp config_env_var?("RELEASE_" <> _), do: true
  defp config_env_var?("MIX_ENV"), do: true
  defp config_env_var?(_), do: false

  if Mix.target() == :app do
    defp app_specs, do: [LivebookApp]
  else
    defp app_specs, do: []
  end

  defp deploy_apps() do
    if apps_path = Livebook.Config.apps_path() do
      warmup = Livebook.Config.apps_path_warmup() == :auto

      Livebook.Apps.deploy_apps_in_dir(apps_path,
        password: Livebook.Config.apps_path_password(),
        warmup: warmup,
        start_only: true
      )
    end
  end

  defp iframe_server_specs() do
    server? = Phoenix.Endpoint.server?(:livebook, LivebookWeb.Endpoint)
    port = Livebook.Config.iframe_port()

    if server? do
      http = Application.fetch_env!(:livebook, LivebookWeb.Endpoint)[:http]

      iframe_opts =
        [
          scheme: :http,
          plug: LivebookWeb.IframeEndpoint,
          port: port,
          thousand_island_options: [supervisor_options: [name: LivebookWeb.IframeEndpoint]]
        ] ++ Keyword.take(http, [:ip])

      [{Bandit, iframe_opts}]
    else
      []
    end
  end

  defp serverless?() do
    Application.get_env(:livebook, :serverless, false)
  end
end
