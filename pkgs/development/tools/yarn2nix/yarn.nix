{ fetchurl, fetchgit, linkFarm, runCommand }: rec {
  offline_cache = linkFarm "offline" packages;
  fetchPackGit = { url, name ? "gittar", rev, sha256 }: runCommand name {} ''
    tar --exclude-vcs -cf "$out" ${fetchgit { inherit url rev sha256; }}
  '';
  packages = [
    {
      name = "@yarnpkg-lockfile-1.0.0.tgz";
      path = fetchurl {
        url = "https://registry.yarnpkg.com/@yarnpkg/lockfile/-/lockfile-1.0.0.tgz";
        sha1 = "33d1dbb659a23b81f87f048762b35a446172add3";
      };
    }
    {
      name = "docopt-0.6.2.tgz";
      path = fetchurl {
        url = "https://registry.yarnpkg.com/docopt/-/docopt-0.6.2.tgz";
        sha1 = "b28e9e2220da5ec49f7ea5bb24a47787405eeb11";
      };
    }
  ];
}

