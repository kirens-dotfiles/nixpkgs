# Configuration for the pwdutils suite of tools: passwd, useradd, etc.

{ config, lib, utils, pkgs, ... }:

with lib;

let

  inherit (lib)
    mkOption
    types
    optionalString
    concatStrings
    concatMapStringsSep
    ;
  inherit (types)
    submodule
    listOf
    strMatching
    nullOr
    path
    int
    bool
    ;

  yesNo = opt: if opt then "yes" else "no";

  range = submodule {
    options.min.type = int;
    options.max.type = int;
  };

  cfg = config.users;
  idRanges = cfg.idRanges;
  login = cfg.login;

  loginDefs =
    ''
      DEFAULT_HOME ${yesNo (!login.requreHome)}
      SYS_UID_MAX  ${toString idRanges.suid.max}
      UID_MIN      ${toString idRanges.uid.min}
      UID_MAX      ${toString idRanges.uid.max}

      SYS_GID_MIN  ${toString idRanges.sgid.min}
      SYS_GID_MAX  ${toString idRanges.sgid.max}
      GID_MIN      ${toString idRanges.gid.min}
      GID_MAX      ${toString idRanges.gid.max}

      # Should not be configurable as nixos will setgid tty writer
      TTYGROUP     tty
      TTYPERM      0620

      # Ensure privacy for newly created home directories.
      UMASK        ${login.homeDirMode}

      CHFN_RESTRICT ${with cfg.configurableValues; concatStrings [
        (optionalString name "f")
        (optionalString room "r")
        (optionalString workPhone "w")
        (optionalString homePhone "h")
      ]}

      ${optionalString (! isNull login.path) ''
       ENV_PATH PATH=${concatMapStringsSep ":" toString login.path}
      ''}
      ${optionalString (! isNull login.supath) ''
       ENV_SUPATH PATH=${concatMapStringsSep ":" toString login.supath}
      ''}
    '';

    rangeOption = prgms: kind: default: mkOption {
      inherit default;
      type = types.attrs;
      description = ''
        Range of IDs used for the creation of ${kind} by ${prgms}
      '';
    };
    userRange = kind: rangeOption "useradd or newusers" "${kind} user";
    groupRange = kind:
      rangeOption "useradd, groupadd, or newusers" "${kind} group";

    generic = {
      falseBool = description:
        mkOption { inherit description; type = bool; default = false; };
    };

    pathOption = userKind: mkOption {
      type = nullOr (listOf path);
      default = null;
      example = [
        /nix/var/nix/profiles/default/bin
        /run/current-system/sw/bin
      ];
      description = ''
        If set, it will be used to define the PATH environment variable when a
        ${userKind} login.
      '';
    };
in
{

  ###### interface

  options.users = {
    idRanges = {
      uid = userRange  "regular" { min = 1000; max = 29999; };
      gid = groupRange "regular" { min = 1000; max = 29999; };
      suid = userRange  "system" { min = 400; max = 499; };
      sgid = groupRange "system" { min = 400; max = 499; };
    };
    login.requreHome = mkOption {
      type = bool;
      default = false;
      description = ''
        Indicate if login is allowed if we can't cd to the home directory. If
        so, the user will login in the root (/) directory if it is not possible
        to cd to her home directory.
      '';
    };
    login.homeDirMode = mkOption {
      type = strMatching "[0-7]{3}";
      default = "077";
      description = ''
        The file mode creation mask is initialized to this value.

        useradd and newusers use this mask to set the mode of the home
        directory they create. It is also used by pam_umask as the default
        umask value.
      '';
    };
    login.path = pathOption "regular user";
    login.supath = pathOption "superuser";
    configurableValues = mkOption {
      type = with generic; submodule {
        options.name = falseBool "Full Name";
        options.room = falseBool "Room number";
        options.workPhone = falseBool "Work phone";
        options.homePhone = falseBool "Home phone";
      };
      default = {};
      example = { room = true; homePhone = true; };
      description = ''
        This parameter specifies which values in the gecos field of the
        /etc/passwd file may be changed by regular users using the chfn
        program.

        If not specified, only the superuser can make any changes. The most
        restrictive setting is better achieved by not installing chfn SUID.
      '';
    };
    defaultUserShell = lib.mkOption {
      description = ''
        This option defines the default shell assigned to user
        accounts. This can be either a full system path or a shell package.

        This must not be a store path, since the path is
        used outside the store (in particular in /etc/passwd).
      '';
      example = literalExample "pkgs.zsh";
      type = types.either types.path types.shellPackage;
    };

  };


  ###### implementation

  config = {

    environment.systemPackages =
      lib.optional config.users.mutableUsers pkgs.shadow ++
      lib.optional (types.shellPackage.check config.users.defaultUserShell)
        config.users.defaultUserShell;

    environment.etc =
      [ { # /etc/login.defs: global configuration for pwdutils.  You
          # cannot login without it!
          source = pkgs.writeText "login.defs" loginDefs;
          target = "login.defs";
        }

        { # /etc/default/useradd: configuration for useradd.
          source = pkgs.writeText "useradd"
            ''
              GROUP=100
              HOME=/home
              SHELL=${utils.toShellPath config.users.defaultUserShell}
            '';
          target = "default/useradd";
        }
      ];

    security.pam.services =
      { chsh = { rootOK = true; };
        chfn = { rootOK = true; };
        su = { rootOK = true; forwardXAuth = true; logFailures = true; };
        passwd = {};
        # Note: useradd, groupadd etc. aren't setuid root, so it
        # doesn't really matter what the PAM config says as long as it
        # lets root in.
        useradd = { rootOK = true; };
        usermod = { rootOK = true; };
        userdel = { rootOK = true; };
        groupadd = { rootOK = true; };
        groupmod = { rootOK = true; };
        groupmems = { rootOK = true; };
        groupdel = { rootOK = true; };
        login = { startSession = true; allowNullPassword = true; showMotd = true; updateWtmp = true; };
        chpasswd = { rootOK = true; };
      };

    security.wrappers = {
      su.source        = "${pkgs.shadow.su}/bin/su";
      sg.source        = "${pkgs.shadow.out}/bin/sg";
      newgrp.source    = "${pkgs.shadow.out}/bin/newgrp";
      newuidmap.source = "${pkgs.shadow.out}/bin/newuidmap";
      newgidmap.source = "${pkgs.shadow.out}/bin/newgidmap";
    } // (if config.users.mutableUsers then {
      passwd.source    = "${pkgs.shadow.out}/bin/passwd";
    } else {});
  };
}
