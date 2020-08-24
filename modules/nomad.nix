{ self, lib, pkgs, nodeName, config, ... }:
let
  cfg = config.services.nomad;

  inherit (builtins) toJSON typeOf length attrNames split;
  inherit (lib)
    mkOption mkEnableOption mkIf mapAttrsToList filterAttrs hasPrefix
    makeBinPath pipe mapAttrs' nameValuePair flip concatMapStrings isList
    toLower;
  inherit (lib.types)
    attrs nullOr attrsOf path package str submodule bool listOf enum port ints;
  inherit (pkgs) snakeCase;

  # TODO: put this in lib
  sanitize = obj:
    lib.getAttr (typeOf obj) {
      lambda = throw "Cannot sanitize functions";
      bool = obj;
      int = obj;
      string = obj;
      path = toString obj;
      list = map sanitize obj;
      null = null;
      set = if (length (attrNames obj) == 0) then
        null
      else
        pipe obj [
          (filterAttrs
            (name: value: name != "_module" && name != "_ref" && value != null))
          (mapAttrs'
            (name: value: nameValuePair (snakeCase name) (sanitize value)))
        ];
    };

  serverJoinType = submodule {
    options = {
      retryJoin = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          Specifies a list of server addresses to join. This is similar to start_join, but will continue to be attempted even if the initial join attempt fails, up to retry_max. Further, retry_join is available to both Nomad servers and clients, while start_join is only defined for Nomad servers. This is useful for cases where we know the address will become available eventually. Use retry_join with an array as a replacement for start_join, do not use both options.
        '';
      };

      retryInterval = mkOption {
        type = str;
        default = "30s";
        description = ''
          Specifies the time to wait between retry join attempts.
        '';
      };

      retryMax = mkOption {
        type = ints.unsigned;
        default = 0;
        description = ''
          Specifies the maximum number of join attempts to be made before exiting with a return code of 1. By default, this is set to 0 which is interpreted as infinite retries.
        '';
      };

      startJoin = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          Specifies a list of server addresses to join on startup. If Nomad is unable to join with any of the specified addresses, agent startup will fail. See the server address format section for more information on the format of the string. This field is defined only for Nomad servers and will result in a configuration parse error if included in a client configuration.
        '';
      };
    };
  };
in {
  options.services.nomad = {
    enable = mkEnableOption "Enable the Nomad agent";

    package = mkOption {
      type = package;
      default = pkgs.nomad;
      defaultText = "pkgs.nomad";
      description = "The nomad package to use.";
    };

    pluginDir = mkOption {
      type = nullOr path;
      default = null;
      description = ''
        Path to a directory with plugins to load at runtime.
      '';
    };

    configDir = mkOption {
      type = nullOr path;
      default = /etc/nomad.d;
    };

    dataDir = mkOption {
      type = path;
      default = /var/lib/nomad;
      description = ''
        A local directory used to store agent state. Client nodes use this
        directory by default to store temporary allocation data as well as
        cluster information. Server nodes use this directory to store cluster
        state, including the replicated log and snapshot data. This must be
        specified as an absolute path.

        WARNING: This directory must not be set to a directory that is included
        in the chroot if you use the exec driver.
      '';
    };

    ports = mkOption {
      default = { };
      type = submodule {
        options = {
          http = mkOption {
            type = port;
            default = 4646;
            description = ''
              The port used to run the HTTP server.
            '';
          };

          rpc = mkOption {
            type = port;
            default = 4647;
            description = ''
              The port used for internal RPC communication between agents and
              servers, and for inter-server traffic for the consensus algorithm
              (raft).
            '';
          };

          serf = mkOption {
            type = port;
            default = 4648;
            description = ''
              The port used for the gossip protocol for cluster membership.
              Both TCP and UDP should be routable between the server nodes on
              this port.
            '';
          };
        };
      };
    };

    datacenter = mkOption {
      type = str;
      default = "dc1";
    };

    logLevel = mkOption {
      type = enum [ "DEBUG" "INFO" "warn" ];
      default = "INFO";
    };

    name = mkOption {
      type = nullOr str;
      default = null;
    };

    client = mkOption {
      default = { };
      type = submodule {
        options = {
          allocDir = mkOption {
            type = path;
            default = cfg.dataDir + "/alloc";
            description = ''
              The directory to use for allocation data. By default, this is the top-level data_dir suffixed with "alloc", like "/var/lib/nomad/alloc". This must be an absolute path.
            '';
          };

          chrootEnv = mkOption {
            type = nullOr (attrsOf str);
            default = null;
            example = { "/usr/bin/env" = "/usr/bin/env"; };
            description = ''
              Specifies a key-value mapping that defines the chroot environment for jobs using the Exec and Java drivers.
            '';
          };

          enabled = mkOption {
            type = bool;
            default = false;
            description = ''
              Specifies if client mode is enabled. All other client configuration options depend on this value.
            '';
          };

          maxKillTimeout = mkOption {
            type = str;
            default = "30s";
            description = ''
              Specifies the maximum amount of time a job is allowed to wait to exit. Individual jobs may customize their own kill timeout, but it may not exceed this value.
            '';
          };

          disableRemoteExec = mkOption {
            type = bool;
            default = false;
            description = ''
              Specifies if the client should disable remote task execution to tasks running on this client.
            '';
          };

          meta = mkOption {
            type = nullOr (attrsOf str);
            default = null;
            description = ''
              Specifies a key-value map that annotates with user-defined metadata.
            '';
          };

          networkInterface = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The name of the interface to force network fingerprinting on.
              When run in dev mode, this defaults to the loopback interface.
              When not in dev mode, the interface attached to the default route
              is used. The scheduler chooses from these fingerprinted IP
              addresses when allocating ports for tasks. If no non-local IP
              addresses are found, Nomad could fingerprint link-local IPv6
              addresses depending on the client's
              "fingerprint.network.disallow_link_local" configuration value.
            '';
          };

          networkSpeed = mkOption {
            type = nullOr ints.unsigned;
            default = null;
            description = ''
              An override for the network link speed. This value, if set,
              overrides any detected or defaulted link speed. Most clients can
              determine their speed automatically, and thus in most cases this
              should be left unset.
            '';
          };

          cpuTotalCompute = mkOption {
            type = nullOr ints.unsigned;
            default = null;
            description = ''
              An override for the total CPU compute. This value should be set
              to # Cores * Core MHz. For example, a quad-core running at 2 GHz
              would have a total compute of 8000 (4 * 2000). Most clients can
              determine their total CPU compute automatically, and thus in most
              cases this should be left unset.
            '';
          };

          memoryTotalMb = mkOption {
            type = nullOr ints.unsigned;
            default = null;
            description = ''
              An override for the total memory. If set, this value overrides
              any detected memory.
            '';
          };

          nodeClass = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              An arbitrary string used to logically group client nodes by
              user-defined class. This can be used during job placement as a
              filter.
            '';
          };

          reserved = mkOption {
            type = submodule {
              options = {
                cpu = mkOption {
                  type = nullOr ints.unsigned;
                  default = null;
                  description = ''
                    Specifies the amount of CPU to reserve, in MHz.
                  '';
                };

                memory = mkOption {
                  type = nullOr ints.unsigned;
                  default = null;
                  description = ''
                    Specifies the amount of memory to reserve, in MB.
                  '';
                };

                disk = mkOption {
                  type = nullOr ints.unsigned;
                  default = null;
                  description = ''
                    Specifies the amount of disk to reserve, in MB.
                  '';
                };
                reservedPorts = mkOption {
                  type = nullOr str;
                  default = null;
                  description = ''
                    A comma-separated list of ports to reserve on all
                    fingerprinted network devices. Ranges can be specified by
                    using a hyphen separated the two inclusive ends.
                  '';
                };
              };
            };
            default = { };
            description = ''
              That Nomad should reserve a portion of the node's resources from
              receiving tasks. This can be used to target a certain capacity
              usage for the node. For example, 20% of the node's CPU could be
              reserved to target a CPU utilization of 80%.
            '';
          };

          servers = mkOption {
            type = listOf str;
            default = [ ];
            description = ''
              An array of addresses to the Nomad servers this client should
              join. This list is used to register the client with the server
              nodes and advertise the available resources so that the agent can
              receive work. This may be specified as an IP address or DNS, with
              or without the port. If the port is omitted, the default port of
              4647 is used.
            '';
          };

          serverJoin = mkOption {
            type = serverJoinType;
            default = { };
            description = ''
              How the Nomad client will connect to Nomad servers. The
              start_join field is not supported on the client. The retry_join
              fields may directly specify the server address or use go-discover
              syntax for auto-discovery. See the documentation for more detail.
            '';
          };

          stateDir = mkOption {
            type = path;
            default = cfg.dataDir + "/client";
            description = ''
              The directory to use to store client state. By default, this is -
              the top-level data_dir suffixed with "client", like
              "/var/lib/nomad/client". This must be an absolute path.
            '';
          };

          gcInterval = mkOption {
            type = str;
            default = "1m";
            description = ''
              Specifies the interval at which Nomad attempts to garbage collect
              terminal allocation directories.
            '';
          };

          gcDiskUsageThreshold = mkOption {
            type = ints.positive;
            default = 80;
            description = ''
              The disk usage percent which Nomad tries to maintain by garbage
              collecting terminal allocations.
            '';
          };

          gcInodeUsageThreshold = mkOption {
            type = ints.positive;
            default = 70;
            description = ''
              The inode usage percent which Nomad tries to maintain by garbage
              collecting terminal allocations.
            '';
          };

          gcMaxAllocs = mkOption {
            type = ints.positive;
            default = 50;
            description = ''
              The maximum number of allocations which a client will track
              before triggering a garbage collection of terminal allocations.
              This will not limit the number of allocations a node can run at a
              time, however after gc_max_allocs every new allocation will cause
              terminal allocations to be GC'd.
            '';
          };

          gcParallelDestroys = mkOption {
            type = ints.positive;
            default = 2;
            description = ''
              The maximum number of parallel destroys allowed by the garbage
              collector. This value should be relatively low to avoid high
              resource usage during garbage collections.
            '';
          };

          noHostUuid = mkOption {
            type = bool;
            default = false;
            description = ''
              By default a random node UUID will be generated, but setting this
              to false will use the system's UUID. Before Nomad 0.6 the default
              was to use the system UUID.
            '';
          };

          cniPath = mkOption {
            type = path;
            default = "${pkgs.cni-plugins}/bin";
            description = ''
              Sets the search path that is used for CNI plugin discovery.
            '';
          };

          bridgeNetworkName = mkOption {
            type = str;
            default = "nomad";
            description = ''
              The name of the bridge to be created by nomad for allocations
              running with bridge networking mode on the client.
            '';
          };

          bridgeNetworkSubnet = mkOption {
            type = str;
            default = "172.26.66.0/23";
            description = ''
              The subnet which the client will use to allocate IP addresses
              from.
            '';
          };

          template = mkOption {
            type = submodule {
              options = {
                functionBlacklist = mkOption {
                  type = listOf str;
                  default = [ "plugin" ];
                  description = ''
                    A list of template rendering functions that should be
                    disallowed in job specs. By default the plugin function is
                    disallowed as it allows running arbitrary commands on the
                    host as root (unless Nomad is configured to run as a
                    non-root user).
                  '';
                };

                disableFileSandbox = mkOption {
                  type = bool;
                  default = false;
                  description = ''
                    Allows templates access to arbitrary files on the client
                    host via the file function. By default templates can access
                    files only within the task directory.
                  '';
                };
              };
            };
            default = { };
            description = ''
              Controls on the behavior of task template stanzas.
            '';
          };

          hostVolume = mkOption {
            default = null;
            description = ''
              Exposes paths from the host as volumes that can be mounted into
              jobs.
            '';
            type = nullOr (submodule {
              options = {
                path = mkOption {
                  type = nullOr path;
                  default = null;
                  description = ''
                    The path on the host that should be used as the source when
                    this volume is mounted into a task. The path must exist on
                    client startup.
                  '';
                };

                readOnly = mkOption {
                  type = bool;
                  default = false;
                  description = ''
                    Whether the volume should only ever be allowed to be
                    mounted read_only, or if it should be writeable.
                  '';
                };
              };
            });
          };
        };
      };
    };

    server = mkOption {
      default = { };
      type = submodule {
        options = {
          dataDir = mkOption {
            type = path;
            default = cfg.dataDir + "/server";
            description = ''
              The directory to use for server-specific data, including the
              replicated log. By default, this is - the top-level data_dir suffixed
              with "server", like "/var/lib/nomad/server". This must be an absolute
              path.
            '';
          };

          enabled = mkEnableOption ''
            If this agent should run in server mode. All other server options
            depend on this value being set.
          '';

          serverJoin = mkOption {
            type = serverJoinType;
            default = { };
            description = ''
              How the Nomad client will connect to Nomad servers. The start_join
              field is not supported on the client. The retry_join fields may
              directly specify the server address or use go-discover syntax for
              auto-discovery. See the documentation for more detail.
            '';
          };

          encrypt = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              Specifies the secret key to use for encryption of Nomad server's
              gossip network traffic.
              This key must be 16 bytes that are base64-encoded. The provided key
              is automatically persisted to the data directory and loaded
              automatically whenever the agent is restarted.
              This means that to encrypt Nomad server's gossip protocol, this
              option only needs to be provided once on each agent's initial startup
              sequence.
              If it is provided after Nomad has been initialized with an encryption
              key, then the provided key is ignored and a warning will be
              displayed.
              See the encryption documentation for more details on this option and
              its impact on the cluster.
            '';
          };

          bootstrapExpect = mkOption {
            type = ints.positive;
            default = 1;
            description = ''
              Specifies the number of server nodes to wait for before
              bootstrapping.
              It is most common to use the odd-numbered integers 3 or 5 for this
              value, depending on the cluster size.
              A value of 1 does not provide any fault tolerance and is not
              recommended for production use cases.
            '';
          };

          defaultSchedulerConfig = mkOption {
            default = { };
            type = submodule {
              options = {
                schedulerAlgorithm = mkOption {
                  type = enum [ "binpack" "spread" ];
                  default = "binpack";
                };

                preemptionConfig = mkOption {
                  default = { };
                  type = submodule {
                    options = {
                      batchSchedulerEnabled =
                        mkEnableOption "Enable preemption for batch tasks";
                      systemSchedulerEnabled =
                        mkEnableOption "Enable preemption for system tasks";
                      serviceSchedulerEnabled =
                        mkEnableOption "Enable preemption for service tasks";
                    };
                  };
                };
              };
            };
          };
        };
      };
    };

    tls = mkOption {
      type = submodule {
        options = {
          caFile = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              The path to the CA certificate to use for Nomad's TLS
              communication.
            '';
          };

          certFile = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              The path to the certificate file used for Nomad's TLS
              communication.
            '';
          };

          keyFile = mkOption {
            type = nullOr str;
            default = path;
            description = ''
              The path to the key file to use for Nomad's TLS communication.
            '';
          };

          http = mkOption {
            type = bool;
            default = false;
            description = ''
              If TLS should be enabled on the HTTP endpoints on the Nomad
              agent, including the API.
            '';
          };

          rpc = mkOption {
            type = bool;
            default = false;
            description = ''
              If TLS should be enabled on the RPC endpoints and Raft traffic
              between the Nomad servers. Enabling this on a Nomad client makes
              the client use TLS for making RPC requests to the Nomad servers.
            '';
          };

          rpcUpgradeMode = mkOption {
            type = bool;
            default = false;
            description = ''
              Should be used only when the cluster is being upgraded to TLS,
              and removed after the migration is complete.  This allows the
              agent to accept both TLS and plaintext traffic.
            '';
          };

          tlsCipherSuites = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The TLS cipher suites that will be used by the agent as a
              comma-separated string. Known insecure ciphers are disabled
              (3DES and RC4). By default, an agent is configured to use
              TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
              TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
              TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
              TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
              TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
              TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
              TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
              TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
              TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 and
              TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256.
            '';
          };

          tlsMinVersion = mkOption {
            type = enum [ "tls10" "tls11" "tls12" ];
            default = "tls12";
            description = ''
              Specifies the minimum supported version of TLS.
            '';
          };

          tlsPreferServerCipherSuites = mkOption {
            type = bool;
            default = false;
            description = ''
              Whether TLS connections should prefer the server's ciphersuites
              over the client's.
            '';
          };

          verifyHttpsClient = mkOption {
            type = bool;
            default = false;
            description = ''
              Agents should require client certificates for all incoming HTTPS
              requests. The client certificates must be signed by the same CA
              as Nomad.
            '';
          };

          verifyServerHostname = mkOption {
            type = bool;
            default = false;
            description = ''
              If outgoing TLS connections should verify the server's hostname.
            '';
          };
        };
      };
    };

    acl = mkOption {
      type = submodule {
        options = {
          enabled = mkEnableOption ''
            If ACL enforcement is enabled. All other client configuration
            options depend on this value.
          '';

          tokenTtl = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The maximum time-to-live (TTL) for cached ACL tokens.
              This does not affect servers, since they do not cache tokens.
              Setting this value lower reduces how stale a token can be, but
              increases the request load against servers. If a client cannot
              reach a server, for example because of an outage, the TTL will be
              ignored and the cached value used.
            '';
          };

          policyTtl = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The maximum time-to-live (TTL) for cached ACL policies.
              This does not affect servers, since they do not cache policies.
              Setting this value lower reduces how stale a policy can be, but
              increases the request load against servers. If a client cannot
              reach a server, for example because of an outage, the TTL will be
              ignored and the cached value used.
            '';
          };

          replicationToken = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The Secret ID of the ACL token to use for replicating policies
              and tokens. This is used by servers in non-authoritative region
              to mirror the policies and tokens into the local region.
            '';
          };
        };
      };
    };

    consul = mkOption {
      type = submodule {
        options = {
          address = mkOption {
            type = str;
            default = "127.0.0.1:8500";
            description = ''
              Specifies the address to the local Consul agent, given in the format
              host:port. Supports Unix sockets with the format:
              unix:///tmp/consul/consul.sock. Will default to the CONSUL_HTTP_ADDR
              environment variable if set.
            '';
          };

          allowUnauthenticated = mkOption {
            type = bool;
            default = true;
            description = ''
              Specifies if users submitting jobs to the Nomad server should be
              required to provide their own Consul token, proving they have access
              to the service identity policies required by the Consul Connect
              enabled services listed in the job. This option should be disabled in
              an untrusted environment.
            '';
          };

          auth = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              Specifies the HTTP Basic Authentication information to use for access
              to the Consul Agent, given in the format username:password.
            '';
          };

          autoAdvertise = mkOption {
            type = bool;
            default = true;
            description = ''
              Specifies if Nomad should advertise its services in Consul. The
              services are named according to server_service_name and
              client_service_name. Nomad servers and clients advertise their
              respective services, each tagged appropriately with either http or
              rpc tag. Nomad servers also advertise a serf tagged service.
            '';
          };

          caFile = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              Specifies an optional path to the CA certificate used for Consul
              communication. This defaults to the system bundle if unspecified.
              Will default to the CONSUL_CACERT environment variable if set.
            '';
          };

          certFile = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              Specifies the path to the certificate used for Consul communication. If
              this is set then you need to also set key_file.
            '';
          };

          checksUseAdvertise = mkOption {
            type = bool;
            default = false;
            description = ''
              Specifies if Consul health checks should bind to the advertise
              address. By default, this is the bind address.
            '';
          };

          clientAutoJoin = mkOption {
            type = bool;
            default = true;
            description = ''
              Specifies if the Nomad clients should automatically discover
              servers in the same region by searching for the Consul service
              name defined in the server_service_name option. The search occurs
              if the client is not registered with any servers or it is unable
              to heartbeat to the leader of the region, in which case it may be
              partitioned and searches for other servers.
            '';
          };

          clientServiceName = mkOption {
            type = str;
            default = "nomad-client";
            description = ''
              Specifies the name of the service in Consul for the Nomad clients.
            '';
          };

          clientHttpCheckName = mkOption {
            type = str;
            default = "Nomad Client HTTP Check";
            description = ''
              Specifies the HTTP health check name in Consul for the Nomad clients.
            '';
          };

          keyFile = mkOption {
            type = nullOr path;
            default = null;
            description = ''
              Specifies the path to the private key used for Consul
              communication. If this is set then you need to also set cert_file.
            '';
          };

          serverServiceName = mkOption {
            type = str;
            default = "nomad";
            description = ''
              Specifies the name of the service in Consul for the Nomad servers.
            '';
          };

          serverHttpCheckName = mkOption {
            type = str;
            default = "Nomad Server HTTP Check";
            description = ''
              Specifies the HTTP health check name in Consul for the Nomad servers.
            '';
          };

          serverSerfCheckName = mkOption {
            type = str;
            default = "Nomad Server Serf Check";
            description = ''
              Specifies the Serf health check name in Consul for the Nomad servers.
            '';
          };

          serverRpcCheckName = mkOption {
            type = str;
            default = "Nomad Server RPC Check";
            description = ''
              Specifies the RPC health check name in Consul for the Nomad servers.
            '';
          };

          serverAutoJoin = mkOption {
            type = bool;
            default = true;
            description = ''
              Specifies if the Nomad servers should automatically discover and join other Nomad servers by searching for the Consul service name defined in the server_service_name option. This search only happens if the server does not have a leader.
            '';
          };

          # shareSsl = mkOption {
          #   type = bool;
          #   default = true;
          #   description = ''
          #     Specifies whether the Nomad client should share its Consul SSL configuration with Connect Native applications. Includes values of ca_file, cert_file, key_file, ssl, and verify_ssl. Does not include the values for the ACL token or auth. This option should be disabled in environments where Consul ACLs are not enabled.
          #   '';
          # };

          ssl = mkOption {
            type = bool;
            default = false;
            description = ''
              Specifies if the transport scheme should use HTTPS to communicate with the Consul agent. Will default to the CONSUL_HTTP_SSL environment variable if set.
            '';
          };

          tags = mkOption {
            type = listOf str;
            default = [ ];
            description = ''
              Specifies optional Consul tags to be registered with the Nomad server and agent services.
            '';
          };

          token = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              Specifies the token used to provide a per-request ACL token. This
              option overrides the Consul Agent's default token. If the token is
              not set here or on the Consul agent, it will default to Consul's
              anonymous policy, which may or may not allow writes.
            '';
          };

          verifySsl = mkOption {
            type = bool;
            default = true;
            description = ''
              Specifies if SSL peer verification should be used when communicating to the
              Consul API client over HTTPS. Will default to the
              CONSUL_HTTP_SSL_VERIFY environment variable if set.
            '';
          };
        };
      };
    };

    telemetry = mkOption {
      type = submodule {
        options = {
          datadogAddress = mkOption {
            type = nullOr str;
            default = null;
          };

          datadogTags = mkOption {
            type = nullOr (listOf str);
            default = null;
          };
        };
      };
    };

    # TODO: refactor this, no clue why it's so convoluted.
    plugin = let
      rawExecType = submodule {
        options = { enabled = mkEnableOption "Enable raw-exec"; };
      };

      dockerAuthType = submodule {
        options = {
          helper = mkOption {
            type = nullOr str;
            default = null;
          };

          config = mkOption {
            type = nullOr path;
            default = null;
          };
        };
      };

      dockerType = submodule {
        options = {
          auth = mkOption {
            type = nullOr dockerAuthType;
            default = null;
            apply = value: if value == null then [ ] else [ value ];
          };
        };
      };

      pluginType = submodule ({ name, ... }: {
        options = {
          rawExec = mkOption {
            type = nullOr rawExecType;
            default = null;
          };

          docker = mkOption {
            type = nullOr dockerType;
            default = null;
          };
        };
      });
    in mkOption {
      default = null;
      type = nullOr pluginType;
      apply = top:
        if top == null then
          null
        else
          lib.filter (elem: elem != null) (flip mapAttrsToList top
            (name: value: {
              ${name} =
                if value == null then null else [{ config = [ value ]; }];
            }));
    };
  };

  config = mkIf cfg.enable {
    environment.etc."nomad.d/config.json".source = pkgs.toPrettyJSON "config"
      (sanitize {
        inherit (cfg)
          dataDir logLevel datacenter name acl ports tls consul server client
          plugin telemetry;
      });

    environment.systemPackages = [ pkgs.nomad ];

    networking.firewall = {
      allowedTCPPorts = [ 4646 4647 4648 ];
      allowedUDPPorts = [ 4648 ];
    };

    systemd.services.nomad = {
      wants = [ "consul.service" "vault.service" "network-online.target" ];
      after = [ "consul.service" "vault.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      restartTriggers = mapAttrsToList (_: d: d.source)
        (filterAttrs (n: _: hasPrefix "${baseNameOf cfg.configDir}/" n)
          config.environment.etc);

      path = with pkgs; [
        iptables
        iproute
        consul
        envoy
        amazon-ecr-credential-helper
      ];

      environment = mkIf config.services.consul.enable {
        CONSUL_CACERT = "/etc/ssl/certs/full.pem";
        CONSUL_CLIENT_CERT = "/etc/ssl/certs/cert.pem";
        CONSUL_CLIENT_KEY = "/etc/ssl/certs/cert-key.pem";
        CONSUL_HTTP_ADDR = "https://127.0.0.1:8501";
        CONSUL_HTTP_SSL = "true";
        HOME = "/var/lib/nomad";
      };

      serviceConfig = {
        # ExecReload = "${pkgs.busybox}/bin/kill -HUP $MAINPID";
        ExecStartPre = let
          start-pre = pkgs.writeShellScriptBin "nomad-start-pre" ''
            PATH="${makeBinPath [ pkgs.coreutils ]}"
            set -exuo pipefail
            cp /etc/ssl/certs/cert-key.pem .
            chown --reference . --recursive .
          '';
        in "!${start-pre}/bin/nomad-start-pre";

        ExecStart = let
          args = [ "@${cfg.package}/bin/nomad" "nomad" "agent" ]
            ++ (lib.optionals (cfg.configDir != null) [
              "-config"
              (toString cfg.configDir)
            ]) ++ (lib.optionals (cfg.pluginDir != null) [
              "-plugin-dir"
              (toString cfg.pluginDir)
            ]);
        in lib.concatStringsSep " " args;
        KillMode = "process";
        LimitNOFILE = "infinity";
        LimitNPROC = "infinity";
        TasksMax = "infinity";
        Restart = "on-failure";
        RestartSec = 2;
        StartLimitBurst = 3;
        StartLimitIntervalSec = 10;
        WorkingDirectory = "/var/lib/nomad";
        StateDirectory = "nomad";
      };
    };
  };
}
