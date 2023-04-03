{ config, lib, options, pkgs, utils, ... }:
with lib;
let
  cfg = config.services.wstunnel;
  attrsToArgs = attrs: utils.escapeSystemdExecArgs (
    mapAttrsToList
    (name: value: if value == true then "--${name}" else "--${name}=${value}")
    attrs
  );
  hostPortSubmodule = {
    options = {
      host = mkOption {
        description = mdDoc "The hostname.";
        type = types.str;
      };
      port = mkOption {
        description = mdDoc "The port.";
        type = types.port;
      };
    };
  };
  localRemoteSubmodule = {
    options = {
      local = mkOption {
        description = mdDoc "Local address and port to listen on.";
        type = types.submodule hostPortSubmodule;
        example = {
          host = "127.0.0.1";
          port = 51820;
        };
      };
      remote = mkOption {
        description = mdDoc "Address and port on remote to forward traffic to.";
        type = types.submodule hostPortSubmodule;
        example = {
          host = "127.0.0.1";
          port = 51820;
        };
      };
    };
  };
  hostPortToString = { host, port }: "${host}:${builtins.toString port}";
  localRemoteToString = { local, remote }: utils.escapeSystemdExecArg "${hostPortToString local}:${hostPortToString remote}";
  commonOptions = {
    enable = mkOption {
      description = mdDoc "Whether to enable this `wstunnel` instance.";
      type = types.bool;
      default = true;
    };

    package = mkPackageOptionMD pkgs "wstunnel" {};

    autoStart = mkOption {
      description = mdDoc "Whether this tunnel server should be started automatically.";
      type = types.bool;
      default = true;
    };

    extraArgs = mkOption {
      description = mdDoc "Extra command line arguments to pass to `wstunnel`. Attributes of the form `argName = true;` will be translated to `--argName`, and `argName = \"value\"` to `--argName=value`.";
      type = with types; attrsOf (either str bool);
      default = {};
      example = {
        "someNewOption" = true;
        "someNewOptionWithValue" = "someValue";
      };
    };

    verboseLogging = mkOption {
      description = mdDoc "Enable verbose logging.";
      type = types.bool;
      default = false;
    };

    environmentFile = mkOption {
      description = mdDoc "Environment file to be passed to the systemd service. Useful for passing secrets to the service to prevent them from being world-readable in the Nix store. Note however that the secrets are passed to `wstunnel` through the command line, which makes them locally readable for all users of the system at runtime.";
      type = types.nullOr types.path;
      default = null;
      example = "/var/lib/secrets/wstunnelSecrets";
    };
  };

  serverSubmodule = { config, ...}: {
    options = commonOptions // {
      listen = mkOption {
        description = mdDoc "Address and port to listen on. Setting the port to a value below 1024 will also give the process the required `CAP_NET_BIND_SERVICE` capability.";
        type = types.submodule hostPortSubmodule;
        default = {
          address = "0.0.0.0";
          port = if config.enableHTTPS then 443 else 80;
        };
        defaultText = literalExpression ''
          {
            address = "0.0.0.0";
            port = if enableHTTPS then 443 else 80;
          }
        '';
      };

      restrictTo = mkOption {
        description = mdDoc "Accepted traffic will be forwarded only to this service. Set to `null` to allow forwarding to arbitrary addresses.";
        type = types.nullOr (types.submodule hostPortSubmodule);
        example = {
          host = "127.0.0.1";
          port = 51820;
        };
      };

      enableHTTPS = mkOption {
        description = mdDoc "Use HTTPS for the tunnel server.";
        type = types.bool;
        default = true;
      };

      tlsCertificate = mkOption {
        description = mdDoc "TLS certificate to use instead of the hardcoded one in case of HTTPS connections. Use together with `tlsKey`.";
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/secrets/cert.pem";
      };

      tlsKey = mkOption {
        description = mdDoc "TLS key to use instead of the hardcoded on in case of HTTPS connections. Use together with `tlsCertificate`.";
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/secrets/key.pem";
      };

      useACMEHost = mkOption {
        description = mdDoc "Use a certificate generated by the NixOS ACME module for the given host. Note that this will not generate a new certificate - you will need to do so with `security.acme.certs`.";
        type = types.nullOr types.str;
        default = null;
        example = "example.com";
      };
    };
  };
  clientSubmodule = { config, ... }: {
    options = commonOptions // {
      connectTo = mkOption {
        description = mdDoc "Server address and port to connect to.";
        type = types.submodule hostPortSubmodule;
        example = {
          host = "example.com";
        };
      };

      enableHTTPS = mkOption {
        description = mdDoc "Enable HTTPS when connecting to the server.";
        type = types.bool;
        default = true;
      };

      localToRemote = mkOption {
        description = mdDoc "Local hosts and ports to listen on, plus the hosts and ports on remote to forward traffic to. Setting a local port to a value less than 1024 will additionally give the process the required CAP_NET_BIND_SERVICE capability.";
        type = types.listOf (types.submodule localRemoteSubmodule);
        default = [];
        example = [ {
          local = {
            host = "127.0.0.1";
            port = 8080;
          };
          remote = {
            host = "127.0.0.1";
            port = 8080;
          };
        } ];
      };

      dynamicToRemote = mkOption {
        description = mdDoc "Host and port for the SOCKS5 proxy to dynamically forward traffic to. Leave this at `null` to disable the SOCKS5 proxy. Setting the port to a value less than 1024 will additionally give the service the required CAP_NET_BIND_SERVICE capability.";
        type = types.nullOr (types.submodule hostPortSubmodule);
        default = null;
        example = {
          host = "127.0.0.1";
          port = 1080;
        };
      };

      udp = mkOption {
        description = mdDoc "Whether to forward UDP instead of TCP traffic.";
        type = types.bool;
        default = false;
      };

      udpTimeout = mkOption {
        description = mdDoc "When using UDP forwarding, timeout in seconds after which the tunnel connection is closed. `-1` means no timeout.";
        type = types.int;
        default = 30;
      };

      httpProxy = mkOption {
        description = mdDoc ''
          Proxy to use to connect to the wstunnel server (`USER:PASS@HOST:PORT`).

          ::: {.warning}
          Passwords specified here will be world-readable in the Nix store! To pass a password to the service, point the `environmentFile` option to a file containing `PROXY_PASSWORD=<your-password-here>` and set this option to `<user>:$PROXY_PASSWORD@<host>:<port>`. Note however that this will also locally leak the passwords at runtime via e.g. /proc/<pid>/cmdline.

          :::
        '';
        type = types.nullOr types.str;
        default = null;
      };

      soMark = mkOption {
        description = mdDoc "Mark network packets with the SO_MARK sockoption with the specified value. Setting this option will also enable the required `CAP_NET_ADMIN` capability for the systemd service.";
        type = types.nullOr types.int;
        default = null;
      };

      upgradePathPrefix = mkOption {
        description = mdDoc "Use a specific HTTP path prefix that will show up in the upgrade request to the `wstunnel` server. Useful when running `wstunnel` behind a reverse proxy.";
        type = types.nullOr types.str;
        default = null;
        example = "wstunnel";
      };

      hostHeader = mkOption {
        description = mdDoc "Use this as the HTTP host header instead of the real hostname. Useful for circumventing hostname-based firewalls.";
        type = types.nullOr types.str;
        default = null;
      };

      tlsSNI = mkOption {
        description = mdDoc "Use this as the SNI while connecting via TLS. Useful for circumventing hostname-based firewalls.";
        type = types.nullOr types.str;
        default = null;
      };

      tlsVerifyCertificate = mkOption {
        description = mdDoc "Whether to verify the TLS certificate of the server. It might be useful to set this to `false` when working with the `tlsSNI` option.";
        type = types.bool;
        default = true;
      };

      # The original argument name `websocketPingFrequency` is a misnomer, as the frequency is the inverse of the interval.
      websocketPingInterval = mkOption {
        description = mdDoc "Do a heartbeat ping every N seconds to keep up the websocket connection.";
        type = types.nullOr types.ints.unsigned;
        default = null;
      };

      upgradeCredentials = mkOption {
        description = mdDoc ''
          Use these credentials to authenticate during the HTTP upgrade request (Basic authorization type, `USER:[PASS]`).

          ::: {.warning}
          Passwords specified here will be world-readable in the Nix store! To pass a password to the service, point the `environmentFile` option to a file containing `HTTP_PASSWORD=<your-password-here>` and set this option to `<user>:$HTTP_PASSWORD`. Note however that this will also locally leak the passwords at runtime via e.g. /proc/<pid>/cmdline.
          :::
        '';
        type = types.nullOr types.str;
        default = null;
      };

      customHeaders = mkOption {
        description = mdDoc "Custom HTTP headers to send during the upgrade request.";
        type = types.attrsOf types.str;
        default = {};
        example = {
          "X-Some-Header" = "some-value";
        };
      };
    };
  };
  generateServerUnit = name: serverCfg: {
    name = "wstunnel-server-${name}";
    value = {
      description = "wstunnel server - ${name}";
      requires = [ "network.target" "network-online.target" ];
      after = [ "network.target" "network-online.target" ];
      wantedBy = optional serverCfg.autoStart "multi-user.target";

      serviceConfig = let
        certConfig = config.security.acme.certs."${serverCfg.useACMEHost}";
      in {
        Type = "simple";
        ExecStart = with serverCfg; let
          resolvedTlsCertificate = if useACMEHost != null
            then "${certConfig.directory}/fullchain.pem"
            else tlsCertificate;
          resolvedTlsKey = if useACMEHost != null
            then "${certConfig.directory}/key.pem"
            else tlsKey;
        in ''
          ${package}/bin/wstunnel \
            --server \
            ${optionalString (restrictTo != null)     "--restrictTo=${utils.escapeSystemdExecArg (hostPortToString restrictTo)}"} \
            ${optionalString (resolvedTlsCertificate != null) "--tlsCertificate=${utils.escapeSystemdExecArg resolvedTlsCertificate}"} \
            ${optionalString (resolvedTlsKey != null)         "--tlsKey=${utils.escapeSystemdExecArg resolvedTlsKey}"} \
            ${optionalString verboseLogging "--verbose"} \
            ${attrsToArgs extraArgs} \
            ${utils.escapeSystemdExecArg "${if enableHTTPS then "wss" else "ws"}://${hostPortToString listen}"}
        '';
        EnvironmentFile = optional (serverCfg.environmentFile != null) serverCfg.environmentFile;
        DynamicUser = true;
        SupplementaryGroups = optional (serverCfg.useACMEHost != null) certConfig.group;
        PrivateTmp = true;
        AmbientCapabilities = optional (serverCfg.listen.port < 1024) [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        RestrictNamespaces = "uts ipc pid user cgroup";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateDevices = true;
        RestrictSUIDSGID = true;

      };
    };
  };
  generateClientUnit = name: clientCfg: {
    name = "wstunnel-client-${name}";
    value = {
      description = "wstunnel client - ${name}";
      requires = [ "network.target" "network-online.target" ];
      after = [ "network.target" "network-online.target" ];
      wantedBy = optional clientCfg.autoStart "multi-user.target";

      serviceConfig = {
        Type = "simple";
        ExecStart = with clientCfg; ''
          ${package}/bin/wstunnel \
            ${concatStringsSep " " (builtins.map (x:          "--localToRemote=${localRemoteToString x}") localToRemote)} \
            ${concatStringsSep " " (mapAttrsToList (n: v:     "--customHeaders=\"${n}: ${v}\"") customHeaders)} \
            ${optionalString (dynamicToRemote != null)        "--dynamicToRemote=${utils.escapeSystemdExecArg (hostPortToString dynamicToRemote)}"} \
            ${optionalString udp                              "--udp"} \
            ${optionalString (httpProxy != null)              "--httpProxy=${httpProxy}"} \
            ${optionalString (soMark != null)                 "--soMark=${toString soMark}"} \
            ${optionalString (upgradePathPrefix != null)      "--upgradePathPrefix=${upgradePathPrefix}"} \
            ${optionalString (hostHeader != null)             "--hostHeader=${hostHeader}"} \
            ${optionalString (tlsSNI != null)                 "--tlsSNI=${tlsSNI}"} \
            ${optionalString tlsVerifyCertificate             "--tlsVerifyCertificate"} \
            ${optionalString (websocketPingInterval != null)  "--websocketPingFrequency=${toString websocketPingInterval}"} \
            ${optionalString (upgradeCredentials != null)     "--upgradeCredentials=${upgradeCredentials}"} \
            --udpTimeoutSec=${toString udpTimeout} \
            ${optionalString verboseLogging "--verbose"} \
            ${attrsToArgs extraArgs} \
            ${utils.escapeSystemdExecArg "${if enableHTTPS then "wss" else "ws"}://${hostPortToString connectTo}"}
        '';
        EnvironmentFile = optional (clientCfg.environmentFile != null) clientCfg.environmentFile;
        DynamicUser = true;
        PrivateTmp = true;
        AmbientCapabilities = (optional (clientCfg.soMark != null) [ "CAP_NET_ADMIN" ]) ++ (optional ((clientCfg.dynamicToRemote.port or 1024) < 1024 || (any (x: x.local.port < 1024) clientCfg.localToRemote)) [ "CAP_NET_BIND_SERVICE" ]);
        NoNewPrivileges = true;
        RestrictNamespaces = "uts ipc pid user cgroup";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateDevices = true;
        RestrictSUIDSGID = true;
      };
    };
  };
in {
  options.services.wstunnel = {
    enable = mkEnableOption (mdDoc "wstunnel");

    servers = mkOption {
      description = mdDoc "`wstunnel` servers to set up.";
      type = types.attrsOf (types.submodule serverSubmodule);
      default = {};
      example = {
        "wg-tunnel" = {
          listen.port = 8080;
          enableHTTPS = true;
          tlsCertificate = "/var/lib/secrets/fullchain.pem";
          tlsKey = "/var/lib/secrets/key.pem";
          restrictTo = {
            host = "127.0.0.1";
            port = 51820;
          };
        };
      };
    };

    clients = mkOption {
      description = mdDoc "`wstunnel` clients to set up.";
      type = types.attrsOf (types.submodule clientSubmodule);
      default = {};
      example = {
        "wg-tunnel" = {
          connectTo = {
            host = "example.com";
            port = 8080;
          };
          enableHTTPS = true;
          localToRemote = {
            local = {
              host = "127.0.0.1";
              port = 51820;
            };
            remote = {
              host = "127.0.0.1";
              port = 51820;
            };
          };
          udp = true;
        };
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services = (mapAttrs' generateServerUnit (filterAttrs (n: v: v.enable) cfg.servers)) // (mapAttrs' generateClientUnit (filterAttrs (n: v: v.enable) cfg.clients));

    assertions = (mapAttrsToList (name: serverCfg: {
      assertion = !(serverCfg.useACMEHost != null && (serverCfg.tlsCertificate != null || serverCfg.tlsKey != null));
      message = ''
        Options services.wstunnel.servers."${name}".useACMEHost and services.wstunnel.servers."${name}".{tlsCertificate, tlsKey} are mutually exclusive.
      '';
    }) cfg.servers) ++
    (mapAttrsToList (name: serverCfg: {
      assertion = !((serverCfg.tlsCertificate != null || serverCfg.tlsKey != null) && !(serverCfg.tlsCertificate != null && serverCfg.tlsKey != null));
      message = ''
        services.wstunnel.servers."${name}".tlsCertificate and services.wstunnel.servers."${name}".tlsKey need to be set together.
      '';
    }) cfg.servers) ++
    (mapAttrsToList (name: clientCfg: {
      assertion = !(clientCfg.localToRemote == [] && clientCfg.dynamicToRemote == null);
      message = ''
        Either one of services.wstunnel.clients."${name}".localToRemote or services.wstunnel.clients."${name}".dynamicToRemote must be set.
      '';
    }) cfg.clients);
  };

  meta.maintainers = with maintainers; [ alyaeanyx ];
}
