{ config, pkgs, lib, ... }:

with lib;
let
  cfg = config.services.amazon-ssm-agent;

  # The SSM agent doesn't pay attention to our /etc/os-release yet, and the lsb-release tool
  # in nixpkgs doesn't seem to work properly on NixOS, so let's just fake the two fields SSM
  # looks for. See https://github.com/aws/amazon-ssm-agent/issues/38 for upstream fix.
  fake-lsb-release = pkgs.writeScriptBin "lsb_release" ''
    #!${pkgs.runtimeShell}

    case "$1" in
      -i) echo "nixos";;
      -r) echo "${config.system.nixos.version}";;
    esac
  '';
in {
  options.services.amazon-ssm-agent = {
    enable = mkEnableOption "AWS SSM agent";

    package = mkOption {
      type = types.path;
      description = "The SSM agent package to use";
      default = pkgs.ssm-agent;
      defaultText = "pkgs.ssm-agent";
    };
  };

  config = mkIf cfg.enable {
    users.users.ssm-user.isSystemUser = true;
    users.users.ssm-user.group = "ssm-user";
    users.groups.ssm-user = { };
    users.extraGroups.wheel.members = [ "ssm-user" ];

    systemd.services.amazon-ssm-agent = {
      inherit (cfg.package.meta) description;
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = [ fake-lsb-release pkgs.coreutils ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/amazon-ssm-agent";
        KillMode = "process";
        Restart = "on-failure";
        RestartSec = "15min";
      };
    };
  };
}
