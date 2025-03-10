{ pkgs, lib, buildGoModule, fetchFromGitHub, fetchurl, nixosTests }:

buildGoModule rec {
  pname = "consul";
  version = "1.10.3";
  rev = "v${version}";

  # Note: Currently only release tags are supported, because they have the Consul UI
  # vendored. See
  #   https://github.com/NixOS/nixpkgs/pull/48714#issuecomment-433454834
  # If you want to use a non-release commit as `src`, you probably want to improve
  # this derivation so that it can build the UI's JavaScript from source.
  # See https://github.com/NixOS/nixpkgs/pull/49082 for something like that.
  # Or, if you want to patch something that doesn't touch the UI, you may want
  # to apply your changes as patches on top of a release commit.
  src = fetchFromGitHub {
    owner = "hashicorp";
    repo = pname;
    inherit rev;
    sha256 = "sha256-Jn8cF+8Wf4zZ/PFXvjCGpomSa/DvraBGW0LsZQ+Zy+4=";
  };

  patches = [
    ./script-check.patch
    # Fix no http protocol upgrades through envoy
    ./consul-issue-9639.patch
  ];

  passthru.tests.consul = nixosTests.consul;

  # This corresponds to paths with package main - normally unneeded but consul
  # has a split module structure in one repo
  subPackages = [ "." "connect/certgen" ];

  vendorSha256 = "sha256-bQWwOJj5WHFsU52Ht+BpdYeLjUaz7h1tE+IpPCzbjb4=";
  deleteVendor = true;

  preBuild = ''
    buildFlagsArray+=("-ldflags"
                      "-X github.com/hashicorp/consul/version.GitDescribe=v${version}
                       -X github.com/hashicorp/consul/version.Version=${version}
                       -X github.com/hashicorp/consul/version.VersionPrerelease=")
  '';

  meta = with lib; {
    description = "Tool for service discovery, monitoring and configuration";
    homepage = "https://www.consul.io/";
    platforms = platforms.linux ++ platforms.darwin;
    license = licenses.mpl20;
    maintainers = with maintainers; [ pradeepchhetri vdemeester nh2 ];
  };
}
