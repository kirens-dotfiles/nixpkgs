{ stdenv, lib, nodejs, yarn }:

let
  unlessNull = item: alt:
    if item == null then alt else item;

  defaultYarnFlags = [
    "--offline"
    "--frozen-lockfile"
    "--ignore-engines"
    "--ignore-scripts"
  ];

in {
  name ? null,
  src,
  packageJSON ? src + "/package.json",
  yarnLock ? src + "/yarn.lock",
  yarnNix ? mkYarnNix yarnLock,
  yarnFlags ? defaultYarnFlags,
  yarnPreBuild ? "",
  pkgConfig ? {},
  extraBuildInputs ? [],
  publishBinsFor ? null,
  ...
}@attrs:
  let
    package = lib.importJSON packageJSON;
    pname = package.name;
    version = package.version;
    deps = mkYarnModules {
      name = "${pname}-modules-${version}";
      preBuild = yarnPreBuild;
      inherit packageJSON yarnLock yarnNix yarnFlags pkgConfig;
    };
    publishBinsFor_ = unlessNull publishBinsFor [pname];
  in stdenv.mkDerivation (builtins.removeAttrs attrs ["pkgConfig"] // {
    inherit src;

    name = unlessNull name "${pname}-${version}";

    buildInputs = [ yarn nodejs ] ++ extraBuildInputs;

    node_modules = deps + "/node_modules";

    configurePhase = attrs.configurePhase or ''
      runHook preConfigure

      if [ -d npm-packages-offline-cache ]; then
        echo "npm-pacakges-offline-cache dir present. Removing."
        rm -rf npm-packages-offline-cache
      fi

      if [[ -d node_modules || -L node_modules ]]; then
        echo "./node_modules is present. Removing."
        rm -rf node_modules
      fi

      mkdir -p node_modules
      ln -s $node_modules/* node_modules/
      ln -s $node_modules/.bin node_modules/

      if [ -d node_modules/${pname} ]; then
        echo "Error! There is already an ${pname} package in the top level node_modules dir!"
        exit 1
      fi

      runHook postConfigure
    '';

    # Replace this phase on frontend packages where only the generated
    # files are an interesting output.
    installPhase = attrs.installPhase or ''
      runHook preInstall

      mkdir -p $out
      cp -r node_modules $out/node_modules
      cp -r . $out/node_modules/${pname}
      rm -rf $out/node_modules/${pname}/node_modules

      mkdir $out/bin
      node ${./fixup_bin.js} $out ${lib.concatStringsSep " " publishBinsFor_}

      runHook postInstall
    '';

    passthru = {
      inherit package deps;
    } // (attrs.passthru or {});

    # TODO: populate meta automatically
  });
