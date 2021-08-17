{ config, nodeName, ... }:
let inherit (config.cluster.instances.${nodeName}) privateIP;
in {
  imports = [ ./default.nix ./policies.nix ];

  config = {
    environment.variables.VAULT_ADDR = "https://127.0.0.1:8200";

    services.vault = {
      enable = true;
      ui = true;
    };
  };
}
