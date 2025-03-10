# Bootstrap vault github employee & aws backend.
{ terralib, lib, config, ... }:
let

  inherit (terralib) var;
  inherit (config.cluster)
    adminGithubTeamNames developerGithubTeamNames developerGithubNames;

in {
  tf.hydrate.configuration = {

    resource.vault_github_auth_backend.employee = {
      organization = "input-output-hk";
      path = "github-employees";
    };

    resource.vault_github_team = let
      admins = lib.listToAttrs (lib.forEach adminGithubTeamNames (name:
        lib.nameValuePair name {
          backend = var "vault_github_auth_backend.employee.path";
          team = name;
          policies = [ "admin" "default" ];
        }));

      developers = lib.listToAttrs (lib.forEach developerGithubTeamNames (name:
        lib.nameValuePair name {
          backend = var "vault_github_auth_backend.employee.path";
          team = name;
          policies = [ "developer" "default" ];
        }));
    in admins // developers;

    resource.vault_github_user =
      lib.mkIf (builtins.length developerGithubNames > 0) (lib.listToAttrs
        (lib.forEach developerGithubNames (name:
          lib.nameValuePair name {
            backend = var "vault_github_auth_backend.employee.path";
            user = name;
            policies = [ "developer" "default" ];
          })));

    resource.vault_aws_secret_backend_role = {
      developers = {
        backend = "aws";
        name = "developer";
        credential_type = "iam_user";
        iam_groups = [ "developers" ];
      };
      admin = {
        backend = "aws";
        name = "admin";
        credential_type = "iam_user";
        iam_groups = [ "admins" ];
      };
    };

  };
}
