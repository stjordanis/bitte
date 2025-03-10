{ config, pkgs, lib, ... }:
let
  cfg = config.services.vault-agent;

  templateType = lib.types.submodule ({ name, ... }: {
    options = {
      destination = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      contents = lib.mkOption { type = lib.types.str; };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  });

  listenerType = lib.types.submodule {
    options = {
      type = lib.mkOption { type = lib.types.str; };
      address = lib.mkOption { type = lib.types.str; };
      tlsDisable = lib.mkOption { type = lib.types.bool; };
    };
  };

in {
  options.services.vault-agent = {
    enable = lib.mkEnableOption "Enable the vault-agent";

    role = lib.mkOption { type = lib.types.enum [ "client" "core" ]; };

    vaultAddress = lib.mkOption {
      type = lib.types.str;
      default = "https://active.vault.service.consul:8200";
    };

    autoAuthMethod = lib.mkOption {
      type = lib.types.enum [ "aws" "cert" ];
      default = "aws";
    };

    autoAuthConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };

    cache = lib.mkOption {
      default = { };
      type = lib.types.submodule {
        options = {
          useAutoAuthToken = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      };
    };

    listener = lib.mkOption {
      type = lib.types.listOf listenerType;
      default = [ ];
    };

    templates = lib.mkOption { type = lib.types.attrsOf templateType; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.vault-agent = let
      configFile = pkgs.toPrettyJSON "vault-agent" ({
        pid_file = "/run/vault-agent.pid";
        vault.address = cfg.vaultAddress;

        auto_auth = {
          method = [{
            type = cfg.autoAuthMethod;
            config = cfg.autoAuthConfig;
          }];

          sinks = [{
            sink = {
              type = "file";
              config = { path = "/run/keys/vault-token"; };
              perms = "0644";
            };
          }];
        };

        templates = lib.mapAttrs (name: value:
          {
            inherit (value) destination contents;
          } // (lib.optionalAttrs (value.command != null) {
            command = value.command;
          })) cfg.templates;
      } // (lib.optionalAttrs (builtins.length cfg.listener > 0) {
        cache.use_auto_auth_token = cfg.cache.useAutoAuthToken;

        listener = lib.forEach cfg.listener (l: {
          type = l.type;
          address = l.address;
          tls_disable = l.tlsDisable;
        });
      }));
    in {
      description = "Obtain secrets from Vault";
      before = lib.mkIf (cfg.role == "core")
        ((lib.optional config.services.vault.enable "vault.service")
          ++ (lib.optional config.services.consul.enable "consul.service")
          ++ (lib.optional config.services.nomad.enable "nomad.service"));
      after =
        lib.mkIf (cfg.role == "client") [ "vault.service" "consul.service" ];
      wants =
        lib.mkIf (cfg.role == "client") [ "vault.service" "consul.service" ];

      wantedBy = [ "multi-user.target" ];

      environment = {
        inherit (config.environment.variables) AWS_DEFAULT_REGION;
        CONSUL_HTTP_ADDR = "127.0.0.1:8500";
        VAULT_ADDR = cfg.vaultAddress;
        VAULT_SKIP_VERIFY = "true";
        VAULT_FORMAT = "json";
      };

      path = with pkgs; [ vault-bin ];

      serviceConfig = {
        Restart = "always";
        RestartSec = "30s";
        ExecStart = "${pkgs.vault-bin}/bin/vault agent -config ${configFile}";
        LimitNOFILE = "infinity";
      };
    };
  };
}
